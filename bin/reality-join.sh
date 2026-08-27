#!/usr/bin/env bash
#
# Join the Reality Network cluster.
#
# Tries each bootstrap peer in turn. A join that returns 200 but leaves the node
# in SessionStarted is treated as a failure: it usually means that peer is
# unhealthy, and the next one is worth trying.
#
# BOOTSTRAP_START=N picks which peer to try first, so repeated attempts rotate
# instead of hammering the same one.

set -uo pipefail

CONF=/opt/reality/node.env
[[ -r $CONF ]] || { echo "no config at $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$(dirname "$CONF")/node.conf" 2>/dev/null || true
# shellcheck disable=SC1090
. "$CONF"

PUBLIC_PORT="${PUBLIC_PORT:-9000}"
CLI_PORT="${CLI_PORT:-9002}"
START="${BOOTSTRAP_START:-0}"

# name|node id|ip|p2p port
PEERS=(
"Genesis|0000003264c7c8503da3d03b6021101a57b5eb933d887bb7e3fbf4b2a57c302dfc5008afb522059b1926e8220de1cfa9388183de60b376a7bd93268990d71157|143.110.227.9|9001"
"Validator 1|1111110d4d295665f6b2083b6bc8463f791cc0903efccafbce0ca5dfe7ff566949a115567c2a14993ef108de4033401ac10142965714c647beb5acaf49a1b24e|68.183.10.93|9001"
"Validator 2|22222208770d62f27e8cd5b927f9c743ae0acda57f77532bf82be73ed36a59c74240c122dbb725216310f77ade4567d54f2a0361941e27e69571f74cfed326ca|128.199.67.191|9001"
)

# An operator or the foundation can override the peer list without a new release.
if [[ -r /opt/reality/bootstrap.list ]]; then
    mapfile -t OVERRIDE < <(grep -vE '^\s*(#|$)' /opt/reality/bootstrap.list)
    (( ${#OVERRIDE[@]} > 0 )) && PEERS=("${OVERRIDE[@]}")
fi

node_state(){
    curl -fsS --max-time 5 "http://127.0.0.1:$PUBLIC_PORT/node/info" 2>/dev/null \
        | grep -o '"state":"[^"]*"' | cut -d'"' -f4
}

try_peer(){
    local name="$1" id="$2" ip="$3" port="$4" code state

    echo "trying $name ($ip:$port)"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -X POST "http://127.0.0.1:$CLI_PORT/cluster/join" \
        -H 'Content-type: application/json' \
        -d "{\"id\":\"$id\",\"ip\":\"$ip\",\"p2pPort\":$port}" 2>/dev/null)

    if [[ $code == 409 ]]; then
        # Already in a session from an earlier attempt. Rotating peers will not
        # help; the node has to finish or time out first.
        echo "  already joining (HTTP 409) - waiting for the current attempt"
        return 2
    fi
    if [[ $code != 200 && $code != 201 ]]; then
        echo "  $name refused the join request (HTTP $code)"
        return 1
    fi

    sleep 10
    state=$(node_state)
    if [[ $state == SessionStarted ]]; then
        echo "  joined $name but the node is not progressing - trying another peer"
        return 1
    fi

    echo "  joined via $name (state $state)"
    return 0
}

n=${#PEERS[@]}
for (( i = 0; i < n; i++ )); do
    idx=$(( (START + i) % n ))
    IFS='|' read -r name id ip port <<< "${PEERS[$idx]}"
    try_peer "$name" "$id" "$ip" "$port"; rc=$?
    [[ $rc -eq 0 ]] && exit 0
    [[ $rc -eq 2 ]] && exit 0
done

echo "could not join through any bootstrap peer"
exit 1
