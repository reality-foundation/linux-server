#!/usr/bin/env bash
#
# Reality Network watchdog.
#
# Runs every five minutes and answers four questions:
#   1. Is the node running?          -> restart it, escalating if that keeps failing
#   2. Is it actually in the cluster? -> join, rotating bootstrap peers
#   3. Is it still earning?           -> a node can look healthy and be stalled
#   4. Is there a new release?        -> install it, and roll back if it will not start
#
# It never touches the keystore or the node's identity.

set -uo pipefail

CONF="${REALITY_CONF:-/opt/reality/node.env}"
PREFIX="${REALITY_PREFIX:-/opt/reality}"
DATA="${REALITY_DATA:-/opt/reality}"
STATEF="$DATA/watchdog.state"
LOCK="${REALITY_LOCK:-/run/reality-watchdog.lock}"
SERVICE=reality-node.service
REPO="reality-foundation/linux-server"
API="${REALITY_API:-https://api.github.com/repos/$REPO}"
DLBASE="${REALITY_DL:-https://github.com/$REPO/releases/download}"

[[ -r $CONF ]] || { echo "no config at $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$(dirname "$CONF")/node.conf" 2>/dev/null || true
# shellcheck disable=SC1090
. "$CONF"

PUBLIC_PORT="${PUBLIC_PORT:-9000}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
ORDINAL_STALL_SECONDS="${ORDINAL_STALL_SECONDS:-7200}"
SESSION_STUCK_SECONDS="${SESSION_STUCK_SECONDS:-600}"
INFO="http://127.0.0.1:$PUBLIC_PORT/node/info"

log(){ printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Only one watchdog at a time.
exec 9>"$LOCK"
flock -n 9 || { log "another watchdog run is in progress, skipping"; exit 0; }

# ------------------------------------------------------------------ state file

# Values go into arithmetic, so only digits are ever accepted back.
state_get(){ [[ -f $STATEF ]] && awk -F= -v k="$1" '$1==k{print $2; exit}' "$STATEF" | tr -dc '0-9'; }
state_set(){
    local k="$1" v="$2" tmp
    tmp=$(mktemp)
    [[ -f $STATEF ]] && grep -v "^$k=" "$STATEF" > "$tmp" 2>/dev/null
    printf '%s=%s\n' "$k" "$v" >> "$tmp"
    mv "$tmp" "$STATEF"
    chmod 0644 "$STATEF"
}

now(){ date +%s; }

# ---------------------------------------------------------------- node queries

node_json(){ curl -fsS --connect-timeout 5 --max-time 10 "$INFO" 2>/dev/null; }
healthy(){ [[ -n $(node_json) ]]; }

# Read one field from JSON on stdin. Tolerates compact and pretty-printed output.
jget(){
    local json key="$1"
    json=$(cat)
    [[ -n $json ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null && return 0
    fi
    printf '%s' "$json" \
        | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" \
        | head -1 | sed -E 's/.*:[[:space:]]*//; s/^"//; s/"$//'
}

node_state(){ node_json | jget state; }
# The ordinal lives on the balance endpoint, not /node/info.
node_ordinal(){
    [[ -n ${WALLET_ADDRESS:-} ]] || return 0
    curl -fsS --connect-timeout 5 --max-time 10 \
        "http://127.0.0.1:$PUBLIC_PORT/net/$WALLET_ADDRESS/balance" 2>/dev/null | jget ordinal
}

# ------------------------------------------------------------------- lifecycle

stop_node(){
    systemctl stop "$SERVICE" >/dev/null 2>&1
    # Give it a moment, then kill only this unit's own processes.
    # Never pkill java - other software on this machine may be using the JVM.
    for _ in 1 2 3 4 5 6; do
        systemctl is-active --quiet "$SERVICE" || return 0
        sleep 2
    done
    log "node did not stop cleanly, killing the service"
    systemctl kill -s KILL "$SERVICE" >/dev/null 2>&1
    sleep 2
}

start_node(){ systemctl start "$SERVICE" >/dev/null 2>&1; }

wait_healthy(){
    local limit="${1:-120}" waited=0
    while (( waited < limit )); do
        healthy && return 0
        sleep 5; waited=$(( waited + 5 ))
    done
    return 1
}

# Renaming the data directory forces a clean resync. It resolves a forked or
# stalled node, but costs a full catch-up, so it is the last resort.
wipe_state(){
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    if [[ -d $DATA/data ]]; then
        mv "$DATA/data" "$DATA/data-backup-$stamp" 2>/dev/null \
            && log "renamed data/ to data-backup-$stamp for a clean resync"
    fi
    # Keep one backup only. Left unchecked these fill the disk, and a full disk
    # is itself a reason the node keeps failing.
    # Sort by the timestamp in the name, not mtime: mv preserves the directory's
    # original mtime, which is when the node last wrote to it, not when we moved it.
    local old
    old=$(ls -1d "$DATA"/data-backup-* 2>/dev/null | sort -r | tail -n +2)
    if [[ -n $old ]]; then
        echo "$old" | while read -r d; do rm -rf "$d" && log "removed old backup $(basename "$d")"; done
    fi
}

join_cluster(){
    local idx="${1:-0}"
    BOOTSTRAP_START="$idx" "$PREFIX/bin/reality-join.sh" 2>&1 | sed 's/^/  join: /'
    return "${PIPESTATUS[0]}"
}

next_bootstrap(){
    local i; i=$(state_get bootstrap_index); i=${i:-0}
    i=$(( (i + 1) % 3 ))
    state_set bootstrap_index "$i"
    printf '%s' "$i"
}

# ------------------------------------------------------------------- recovery

recover(){
    local level="$1" reason="$2"
    log "recovery level $level: $reason"
    case "$level" in
        1) stop_node; start_node ;;
        2) stop_node; start_node; wait_healthy 120 && join_cluster "$(next_bootstrap)" ;;
        3) stop_node; wipe_state; start_node; wait_healthy 180 && join_cluster "$(next_bootstrap)" ;;
    esac
    if wait_healthy 60; then
        log "node is responding again (state $(node_state))"
        return 0
    fi
    log "node is still not responding after recovery level $level"
    return 1
}

# ------------------------------------------------------------------- 1. health

log "watchdog check starting"

if ! healthy; then
    fails=$(state_get fail_count); fails=$(( ${fails:-0} + 1 ))
    state_set fail_count "$fails"
    if   (( fails <= 2 )); then recover 1 "node not responding (attempt $fails)"
    elif (( fails == 3 )); then recover 2 "node still not responding after restarts"
    else                        recover 3 "node unrecoverable by restart alone"; state_set fail_count 0
    fi
    if ! healthy; then
        log "watchdog check finished - node down, will try again next run"
        exit 0
    fi
else
    [[ $(state_get fail_count) == 0 ]] || state_set fail_count 0
fi

STATE=$(node_state)
log "node is up, state $STATE"

# --------------------------------------------------------------- 2. membership

case "$STATE" in
    ReadyToJoin)
        log "node is not in the cluster, joining"
        idx=$(state_get bootstrap_index); idx=${idx:-0}
        join_cluster "$idx"
        sleep 5
        log "state after join: $(node_state)"
        state_set session_since ""
        ;;
    SessionStarted)
        # Joined, but not progressing. Usually the bootstrap peer we picked is
        # unhealthy, so give it a while and then move to a different one.
        since=$(state_get session_since)
        if [[ -z ${since:-} ]]; then
            state_set session_since "$(now)"
            log "node entered SessionStarted, watching it"
        else
            stuck=$(( $(now) - since ))
            if (( stuck >= SESSION_STUCK_SECONDS )); then
                log "stuck in SessionStarted for $(( stuck / 60 )) minutes"
                recover 2 "rotating to a different bootstrap peer"
                state_set session_since ""
            else
                log "in SessionStarted for $(( stuck / 60 )) minutes, still waiting"
            fi
        fi
        ;;
    *)
        [[ -z $(state_get session_since) ]] || state_set session_since ""
        ;;
esac

# ---------------------------------------------------------------- 3. progress
# A node can answer every health check, report a healthy state, and still be
# earning nothing. A frozen ordinal is the only reliable sign.

# The node is unprivileged and this value feeds arithmetic run as root: digits only.
ORD=$(node_ordinal | tr -dc '0-9')
if [[ -n ${ORD:-} && $ORD -gt 0 ]]; then
    last_ord=$(state_get ordinal)
    last_at=$(state_get ordinal_at)
    if [[ -n ${last_ord:-} && -n ${last_at:-} ]]; then
        if (( ORD > last_ord )); then
            log "ordinal $ORD (advanced by $(( ORD - last_ord )))"
            state_set ordinal "$ORD"; state_set ordinal_at "$(now)"
        elif (( ORD == last_ord )); then
            stalled=$(( $(now) - last_at ))
            if (( stalled >= ORDINAL_STALL_SECONDS )); then
                log "ordinal frozen at $ORD for $(( stalled / 3600 ))h - the node is not earning"
                recover 3 "clearing state to recover from a stalled chain"
                state_set ordinal ""; state_set ordinal_at ""
            else
                log "ordinal unchanged at $ORD for $(( stalled / 60 )) minutes"
            fi
        else
            log "ordinal went backwards ($last_ord -> $ORD) - leaving this for a human to look at"
            state_set ordinal "$ORD"; state_set ordinal_at "$(now)"
        fi
    else
        state_set ordinal "$ORD"; state_set ordinal_at "$(now)"
        log "tracking ordinal from $ORD"
    fi
fi

# ------------------------------------------------------------------ 4. updates

if [[ $AUTO_UPDATE == true ]]; then
    CURRENT=$(basename "$(readlink -f "$PREFIX/current" 2>/dev/null)" 2>/dev/null)
    REL=$(mktemp)
    if curl -fsSL --proto '=https' --max-time 30 "$API/releases/latest" -o "$REL" 2>/dev/null; then
        TAG=$(grep -m1 '"tag_name"' "$REL" | cut -d'"' -f4)
        JARV=$(grep -oE 'reality-core-assembly-[^"]+\.jar' "$REL" | head -1 | sed -E 's/^reality-core-assembly-(.*)\.jar$/\1/')

        if [[ $TAG =~ ^[A-Za-z0-9._-]+$ && $JARV =~ ^[A-Za-z0-9._+-]+$ && $TAG != "$CURRENT" ]]; then
            log "new release available: $CURRENT -> $TAG"
            DEST="$PREFIX/releases/$TAG"
            DL="$DLBASE/$TAG"
            rm -rf "$DEST.partial"; mkdir -p "$DEST.partial"

            okdl=true
            for pair in "core:reality-core-assembly" "keytool:reality-keytool-assembly" "wallet:reality-wallet-assembly"; do
                name="${pair%%:*}"; asset="${pair##*:}"
                curl -fsSL --proto '=https' --proto-redir '=https' --max-time 900 -o "$DEST.partial/$asset-$JARV.jar" "$DL/$asset-$JARV.jar" || okdl=false
                [[ -s "$DEST.partial/$asset-$JARV.jar" ]] || okdl=false
                $okdl || break
            done

            # All three must verify; --ignore-missing alone passes if nothing is listed.
            if $okdl && curl -fsSL --proto '=https' --proto-redir '=https' --max-time 20 "$DL/SHA256SUMS" -o "$DEST.partial/SHA256SUMS" 2>/dev/null; then
                verified=$( cd "$DEST.partial" && sha256sum -c --ignore-missing SHA256SUMS 2>/dev/null | grep -c ': OK$' ) || verified=0
                if [[ $verified -ne 3 ]]; then
                    log "checksum verification failed for $TAG - not installing it"
                    okdl=false
                fi
            fi
            if $okdl; then
                for pair in "core:reality-core-assembly" "keytool:reality-keytool-assembly" "wallet:reality-wallet-assembly"; do
                    mv "$DEST.partial/${pair##*:}-$JARV.jar" "$DEST.partial/${pair%%:*}.jar"
                done
            fi

            if $okdl; then
                rm -rf "$DEST"; mv "$DEST.partial" "$DEST"
                PREVIOUS="$PREFIX/releases/$CURRENT"
                stop_node
                ln -sfn "$DEST" "$PREFIX/current"
                start_node
                if wait_healthy 240; then
                    log "updated to $TAG (state $(node_state))"
                    st=$(node_state)
                    [[ $st == ReadyToJoin ]] && join_cluster "$(state_get bootstrap_index || echo 0)"
                    # Keep the running release and the one we came from, so a
                    # rollback is always possible. Delete anything older.
                    keep_new=$(readlink -f "$PREFIX/current")
                    for d in "$PREFIX"/releases/*/; do
                        d=${d%/}
                        [[ $d == "$keep_new" || $d == "$PREVIOUS" ]] && continue
                        rm -rf "$d" && log "removed old release $(basename "$d")"
                    done
                else
                    log "$TAG did not come up - rolling back to $CURRENT"
                    stop_node
                    ln -sfn "$PREVIOUS" "$PREFIX/current"
                    start_node
                    if wait_healthy 240; then
                        log "rolled back to $CURRENT successfully"
                    else
                        log "ERROR rollback to $CURRENT is also not responding - needs a human"
                    fi
                    rm -rf "$DEST"
                fi
            else
                log "download of $TAG failed - staying on $CURRENT"
                rm -rf "$DEST.partial"
            fi
        fi
    fi
    rm -f "$REL"
fi

log "watchdog check finished"
