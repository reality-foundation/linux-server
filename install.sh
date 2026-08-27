#!/usr/bin/env bash
#
# Reality Network - one command node installer
#
#   curl -fsSL https://raw.githubusercontent.com/reality-foundation/linux-server/main/install.sh -o install.sh
#   sudo bash install.sh
#
# Re-running is safe. An existing keystore is never regenerated.

set -euo pipefail

VERSION="1.0"
# Releases (the JARs) always come from the official repo. The scripts can be
# taken from a fork/branch for testing: REALITY_REPO=you/linux-server REALITY_REF=branch
REPO="reality-foundation/linux-server"
SCRIPT_REPO="${REALITY_REPO:-$REPO}"
REF="${REALITY_REF:-main}"
RAW="https://raw.githubusercontent.com/${SCRIPT_REPO}/${REF}"
API="https://api.github.com/repos/${REPO}"

# Everything lives in one folder.
PREFIX=/opt/reality
DATA=$PREFIX
CONF=$PREFIX
ENVF="$CONF/node.env"
RUN_USER=reality

PUBLIC_PORT=9000
P2P_PORT=9001
CLI_PORT=9002
LIBP2P_PORT=9003
COLLATERAL=0

AUTO_UPDATE=true
DO_FIREWALL=true
NODE_IP=""
NODE_PASSWORD=""
HEAP=""
MODE=install

# ----------------------------------------------------------------- appearance

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
    G=$'\033[32m'; Y=$'\033[33m'; E=$'\033[31m'; C=$'\033[36m'
else
    B=""; D=""; R=""; G=""; Y=""; E=""; C=""
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf8*|*UTF8*)
        TL="╭" TR="╮" BL="╰" BR="╯" HZ="─" VT="│"
        OK="✓" NO="✗" WARN="⚠" DOT="●" MID="·" FULL="█" EMPTY="░" ;;
    *)
        TL="+" TR="+" BL="+" BR="+" HZ="-" VT="|"
        OK="+" NO="x" WARN="!" DOT="*" MID="-" FULL="#" EMPTY="." ;;
esac

W=58

hr()  { local n="$1" c="$2" s=""; while (( n-- > 0 )); do s+="$c"; done; printf '%s' "$s"; }
btop(){ printf '   %s%s%s%s%s\n' "$D" "$TL" "$(hr $W "$HZ")" "$TR" "$R"; }
bbot(){ printf '   %s%s%s%s%s\n' "$D" "$BL" "$(hr $W "$HZ")" "$BR" "$R"; }
brow(){
    local t="$1" pad=$(( W - 1 - ${#1} ))
    (( pad < 0 )) && pad=0
    printf '   %s%s%s %s%*s%s%s%s\n' "$D" "$VT" "$R" "$t" "$pad" "" "$D" "$VT" "$R"
}
sect(){ printf '\n   %s%s%s\n' "$B" "$1" "$R"; }
ok()  { printf '   %s%s%s %s\n' "$G" "$OK" "$R" "$1"; }
note(){ printf '   %s%s%s %s\n' "$D" "$MID" "$R" "$1"; }
warn(){ printf '   %s%s%s %s\n' "$Y" "$WARN" "$R" "$1"; }
die() {
    printf '\n   %s%s %s%s\n' "$E" "$NO" "$1" "$R" >&2
    [[ $# -gt 1 ]] && printf '     %s%s%s\n' "$D" "$2" "$R" >&2
    printf '\n' >&2
    exit 1
}

banner(){
    local sub="node installer  v$VERSION"
    printf '\n'
    if [[ $HZ == "─" ]]; then
        # Block letters, 55 columns wide.
        local L1=' ██████╗ ███████╗ █████╗ ██╗     ██╗████████╗██╗   ██╗'
        local L2=' ██╔══██╗██╔════╝██╔══██╗██║     ██║╚══██╔══╝╚██╗ ██╔╝'
        local L3=' ██████╔╝█████╗  ███████║██║     ██║   ██║    ╚████╔╝ '
        local L4=' ██╔══██╗██╔══╝  ██╔══██║██║     ██║   ██║     ╚██╔╝  '
        local L5=' ██║  ██║███████╗██║  ██║███████╗██║   ██║      ██║   '
        local L6=' ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝   ╚═╝      ╚═╝   '
        printf '   %s%s%s\n' "$C$B" "$L1" "$R"
        printf '   %s%s%s\n' "$C$B" "$L2" "$R"
        printf '   %s%s%s\n' "$C"   "$L3" "$R"
        printf '   %s%s%s\n' "$C"   "$L4" "$R"
        printf '   %s%s%s\n' "$D$C" "$L5" "$R"
        printf '   %s%s%s\n' "$D$C" "$L6" "$R"
        printf '   %s%*s%s\n' "$D" 55 "$sub" "$R"
    else
        printf '   %sR E A L I T Y%s   %s%s%s\n' "$B" "$R" "$D" "$sub" "$R"
    fi
}

bar(){
    local label="$1" got="$2" total="$3" w=20 pct=0 f
    (( total > 0 )) && pct=$(( got * 100 / total ))
    (( pct > 100 )) && pct=100
    f=$(( pct * w / 100 ))
    printf '\r   %s%s%s %-24s %s%s%s%s %4d%%' \
        "$G" "$OK" "$R" "$label" "$C" "$(hr $f "$FULL")" "$(hr $((w-f)) "$EMPTY")" "$R" "$pct"
}

# Download with a live progress bar.
fetch(){
    local url="$1" dest="$2" label="$3" total got pid
    total=$(curl -sIL --max-time 30 "$url" 2>/dev/null \
        | tr -d '\r' | awk 'BEGIN{IGNORECASE=1}/^content-length:/{n=$2}END{print n+0}')
    curl -fsSL --proto '=https' --proto-redir '=https' -o "$dest" "$url" & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        got=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        bar "$label" "$got" "$total"
        sleep 0.2
    done
    if ! wait "$pid"; then printf '\n'; return 1; fi
    got=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    bar "$label" "$got" "$got"
    printf '\n'
}

usage(){
    cat <<USAGE
Reality Network node installer v$VERSION

  sudo bash install.sh [options]

  --ip ADDRESS        public IPv4 to advertise (default: detected)
  --password SECRET   keystore password (default: you are asked)
  --keystore PATH     import this keystore instead of searching for one
  --heap SIZE         JVM heap, e.g. 6g (default: sized from RAM)
  --no-upgrade        skip the system package upgrade
  --no-firewall       do not touch ufw rules
  --no-auto-update    install the watchdog without automatic updates
  --allow-private     accept a private/LAN IP (for local testing only)
  --uninstall         remove the programs, keeping your keystore and data in /opt/reality
  --purge             with --uninstall, also delete chain data and settings
                      (your keystore is copied to /root first, never destroyed)
  -h, --help          this message

USAGE
    exit 0
}

PURGE=false
IMPORT_KEYSTORE=""
ALLOW_PRIVATE=false
DO_UPGRADE=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)             NODE_IP="${2:-}"; shift 2 ;;
        --password)       NODE_PASSWORD="${2:-}"; shift 2 ;;
        --keystore)       IMPORT_KEYSTORE="${2:-}"; shift 2 ;;
        --heap)           HEAP="${2:-}"; shift 2 ;;
        --no-firewall)    DO_FIREWALL=false; shift ;;
        --no-upgrade)     DO_UPGRADE=false; shift ;;
        --no-auto-update) AUTO_UPDATE=false; shift ;;
        --allow-private)  ALLOW_PRIVATE=true; shift ;;
        --uninstall)      MODE=uninstall; shift ;;
        --purge)          PURGE=true; shift ;;
        -h|--help)        usage ;;
        *) die "Unknown option: $1" "Run with --help to see what is available." ;;
    esac
done

# ------------------------------------------------------------------ uninstall

if [[ $MODE == uninstall ]]; then
    [[ $EUID -eq 0 ]] || die "The uninstaller needs root." "Try: sudo bash install.sh --uninstall"
    banner
    sect "REMOVING"
    printf '   %s%s%s stopping the node, this can take up to a minute ...' "$D" "$MID" "$R"
    systemctl stop reality-watchdog.timer reality-node.service >/dev/null 2>&1 || true
    printf '\r%72s\r' ""
    ok "node stopped"
    for u in reality-watchdog.timer reality-watchdog.service reality-node.service; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$u"
    done
    systemctl daemon-reload
    ok "services removed"
    rm -rf "$PREFIX/bin" "$PREFIX/releases" "$PREFIX/current" /usr/local/bin/reality /usr/local/bin/realityctl
    ok "programs removed"
    if [[ $PURGE == true ]]; then
        # A keystore is a wallet: losing it is unrecoverable, so it is always
        # rescued out of the way first, whatever the operator asked for.
        RESCUE=""
        if [[ -f $PREFIX/node.p12 ]]; then
            RESCUE="/root/reality-keystore-$(date +%Y%m%d-%H%M%S)"
            install -d -m 0700 "$RESCUE"
            install -m 0600 "$PREFIX/node.p12" "$RESCUE/node.p12"
            [[ -f $PREFIX/node.env ]] && install -m 0600 "$PREFIX/node.env" "$RESCUE/node.env"
            if [[ -t 0 ]]; then
                printf '\n   %s%s  This will delete %s, including your node identity.%s\n' "$Y" "$WARN" "$PREFIX" "$R"
                printf '      %sIf you continue, a copy of your keystore is saved to%s\n' "$D" "$R"
                printf '      %s%s first, so your wallet survives either way.%s\n\n' "$D" "$RESCUE" "$R"
                read -r -p '   Type DELETE in capitals to continue, anything else to keep your data: ' ans
                if [[ $ans != DELETE ]]; then
                    rm -rf "$RESCUE"
                    printf '\n'
                    ok "your keystore and chain data are still in $PREFIX"
                    note "the node itself is uninstalled - reinstall it with:"
                    note "  sudo bash install.sh --keystore $PREFIX/node.p12"
                    printf '\n'
                    exit 0
                fi
            fi
        fi
        rm -rf "$PREFIX"
        warn "chain data and settings deleted"
        if [[ -n $RESCUE ]]; then
            ok "your keystore was NOT destroyed $MID copied to $RESCUE"
            note "it is your wallet - move it somewhere safe, or delete that folder yourself"
        fi
    else
        ok "keystore, settings and data kept in $PREFIX"
        note "delete them with: sudo rm -rf $PREFIX"
    fi
    printf '\n'
    exit 0
fi

# ------------------------------------------------------------------- preflight

banner

[[ $EUID -eq 0 ]] || die "This installer needs root." "Try: sudo bash install.sh"

sect "SYSTEM"

[[ -r /etc/os-release ]] || die "Cannot identify this operating system."
# shellcheck disable=SC1091
. /etc/os-release
PRETTY="${PRETTY_NAME:-$ID $VERSION_ID}"

if command -v apt-get >/dev/null 2>&1; then
    PKG=apt
elif command -v dnf >/dev/null 2>&1; then
    PKG=dnf
elif command -v pacman >/dev/null 2>&1; then
    PKG=pacman
else
    die "No supported package manager found." "This installer supports apt (Debian/Ubuntu), dnf (Fedora/RHEL) and pacman (Arch)."
fi

# A fresh VPS has stale package lists, and Ubuntu 22.04+ pops an interactive
# "restart services?" dialog during installs unless needrestart is told not to.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
if [[ $PKG == apt ]]; then
    printf '   %s%s%s refreshing package lists ...' "$D" "$MID" "$R"
    apt-get update -qq >/dev/null 2>&1 || true
    printf '\r                                          \r'
fi

pkg_upgrade(){
    case "$PKG" in
        apt)    apt-get upgrade -y -qq -o Dpkg::Options::=--force-confold >/dev/null 2>&1 ;;
        dnf)    dnf upgrade -y -q >/dev/null 2>&1 ;;
        pacman) pacman -Syu --noconfirm >/dev/null 2>&1 ;;
    esac
}

if [[ $DO_UPGRADE == true ]]; then
    printf '   %s%s%s upgrading system packages, this can take a few minutes ...' "$D" "$MID" "$R"
    if pkg_upgrade; then
        printf '\r%72s\r' ""
        ok "system packages up to date"
    else
        printf '\r%72s\r' ""
        warn "system upgrade did not finish cleanly - continuing anyway"
    fi
fi

pkg_install(){
    case "$PKG" in
        apt)    apt-get install -y -qq -o Dpkg::Options::=--force-confold "$@" >/dev/null 2>&1 ;;
        dnf)    dnf install -y -q "$@" >/dev/null 2>&1 ;;
        pacman) pacman -S --noconfirm --needed "$@" >/dev/null 2>&1 ;;
    esac
}

ARCH=$(uname -m)
[[ $ARCH == x86_64 || $ARCH == aarch64 ]] || warn "untested architecture: $ARCH"

RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
RAM_GB=$(( RAM_MB / 1024 ))
DISK_GB=$(df -BG --output=avail "$(dirname $DATA)" 2>/dev/null | tail -1 | tr -dc '0-9')
DISK_GB=${DISK_GB:-0}

ok "$PRETTY $MID ${RAM_GB} GB RAM $MID ${DISK_GB} GB free"

(( RAM_MB >= 7500 )) || warn "8 GB RAM is recommended; you have ${RAM_GB} GB"
(( DISK_GB >= 40 ))  || warn "40 GB free disk is recommended; you have ${DISK_GB} GB"

if [[ -z $HEAP ]]; then
    if   (( RAM_MB >= 15000 )); then HEAP=8g
    elif (( RAM_MB >= 7500 ));  then HEAP=6g
    elif (( RAM_MB >= 3500 ));  then HEAP=2g
    else HEAP=1g
    fi
fi

# Java -----------------------------------------------------------------------

java_major(){
    local v
    v=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/') || return 1
    [[ $v =~ ^[0-9]+$ ]] && printf '%s' "$v"
}

if command -v java >/dev/null 2>&1 && [[ $(java_major || echo 0) -ge 17 ]]; then
    ok "Java $(java_major) already installed"
else
    printf '   %s%s%s installing Java ...' "$D" "$MID" "$R"
    case "$PKG" in
        apt)    pkg_install openjdk-21-jre-headless || pkg_install openjdk-17-jre-headless || true ;;
        dnf)    pkg_install java-21-openjdk-headless || pkg_install java-17-openjdk-headless || true ;;
        pacman) pkg_install jre21-openjdk-headless || pkg_install jre17-openjdk-headless || true ;;
    esac
    printf '\r'
    command -v java >/dev/null 2>&1 && [[ $(java_major || echo 0) -ge 17 ]] \
        || die "Could not install Java 17 or newer." "Install a JRE manually, then run this installer again."
    ok "Java $(java_major) installed                    "
fi

for t in curl jq; do
    command -v $t >/dev/null 2>&1 && continue
    pkg_install "$t" || true
done
command -v curl >/dev/null 2>&1 || die "curl is required and could not be installed."

# Keep the system clock in sync. Quiet: nothing to show the operator.
timedatectl set-ntp true >/dev/null 2>&1 || true

# Public address --------------------------------------------------------------

is_private(){
    case "$1" in
        10.*|127.*|169.254.*|192.168.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        *) return 1 ;;
    esac
}

valid_ip(){ [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

if [[ -z $NODE_IP ]]; then
    for src in https://api.ipify.org https://checkip.amazonaws.com https://ifconfig.me/ip https://icanhazip.com; do
        NODE_IP=$(curl -4 -fsS --max-time 6 "$src" 2>/dev/null | tr -d '[:space:]') || NODE_IP=""
        valid_ip "$NODE_IP" && break
        NODE_IP=""
    done
fi
# DNS-based lookup, works where HTTPS lookups are blocked.
if [[ -z $NODE_IP ]] && command -v dig >/dev/null 2>&1; then
    NODE_IP=$(dig -4 +short +time=3 +tries=1 myip.opendns.com @resolver1.opendns.com 2>/dev/null | tail -1 || true)
    valid_ip "$NODE_IP" || NODE_IP=""
fi
# Last resort: the address of the default route. On a VPS this is the public address.
if [[ -z $NODE_IP ]]; then
    NODE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -1 || true)
    valid_ip "$NODE_IP" || NODE_IP=""
    [[ -n $NODE_IP ]] && note "public IP lookup services unreachable, using interface address"
fi

[[ -n $NODE_IP ]] || die "Could not determine your public IPv4 address." \
    "Pass it yourself: sudo bash install.sh --ip YOUR.PUBLIC.IP.ADDRESS"

if is_private "$NODE_IP" && [[ $ALLOW_PRIVATE == false ]]; then
    die "$NODE_IP is a private address, so other nodes cannot reach you." \
        "A Reality node needs a public IPv4 address. Home connections behind NAT will not work without port forwarding."
fi
if is_private "$NODE_IP"; then
    warn "using private address $NODE_IP - other nodes cannot reach you (testing only)"
else
    ok "public address $NODE_IP"
fi

# ------------------------------------------------------------------- accounts

id -u "$RUN_USER" >/dev/null 2>&1 || useradd --system --home-dir "$PREFIX" --shell /usr/sbin/nologin "$RUN_USER" 2>/dev/null \
    || useradd --system --home-dir "$PREFIX" --shell /sbin/nologin "$RUN_USER"
# Root owns the folder and everything the watchdog reads or runs. The node
# owns only data/ and logs/, the two places it writes. If the node owned the
# folder, a compromised node could swap out files that root later executes.
install -d -m 0755 -o root -g root "$PREFIX" "$PREFIX/releases" "$PREFIX/bin"
install -d -m 0755 -o "$RUN_USER" -g "$RUN_USER" "$PREFIX/data" "$PREFIX/logs"
[[ -d $PREFIX/data ]] && chown -R "$RUN_USER:$RUN_USER" "$PREFIX/data" "$PREFIX/logs" 2>/dev/null || true

# --------------------------------------------------------------------- release

sect "INSTALL"

REL=$(mktemp)
curl -fsSL --proto '=https' --max-time 30 "$API/releases/latest" -o "$REL" \
    || die "Could not reach GitHub to find the latest release."

TAG=$(grep -m1 '"tag_name"' "$REL" | cut -d'"' -f4)
JARV=$(grep -oE 'reality-core-assembly-[^"]+\.jar' "$REL" | head -1 | sed -E 's/^reality-core-assembly-(.*)\.jar$/\1/')
[[ $TAG =~ ^[A-Za-z0-9._-]+$ && $JARV =~ ^[A-Za-z0-9._+-]+$ ]] \
    || die "Could not read the latest release from GitHub." "Unexpected release name: ${TAG:-?} / ${JARV:-?}"

DEST="$PREFIX/releases/$TAG"
DL="https://github.com/$REPO/releases/download/$TAG"

if [[ -f "$DEST/core.jar" && -f "$DEST/wallet.jar" && -f "$DEST/keytool.jar" ]]; then
    ok "reality $TAG already downloaded"
else
    rm -rf "$DEST.partial"
    install -d -m 0755 "$DEST.partial"
    for pair in "core:reality-core-assembly" "keytool:reality-keytool-assembly" "wallet:reality-wallet-assembly"; do
        asset="${pair##*:}-$JARV.jar"
        fetch "$DL/$asset" "$DEST.partial/$asset" "reality $TAG ${pair%%:*}" || die "Download failed."
        [[ -s "$DEST.partial/$asset" ]] || { rm -rf "$DEST.partial"; die "Downloaded ${pair%%:*} JAR is empty."; }
    done

    # Verify checksums when the release publishes them. All three must match;
    # --ignore-missing alone would pass silently if none of our files were listed.
    if curl -fsSL --proto '=https' --proto-redir '=https' --max-time 20 "$DL/SHA256SUMS" -o "$DEST.partial/SHA256SUMS" 2>/dev/null; then
        verified=$( cd "$DEST.partial" && sha256sum -c --ignore-missing SHA256SUMS 2>/dev/null | grep -c ': OK$' ) || verified=0
        if [[ $verified -eq 3 ]]; then
            ok "checksums verified"
        else
            rm -rf "$DEST.partial"
            die "Checksum verification failed." "The downloaded files do not match the published checksums. Nothing was installed."
        fi
    else
        warn "release publishes no checksums - integrity not verified"
    fi

    for pair in "core:reality-core-assembly" "keytool:reality-keytool-assembly" "wallet:reality-wallet-assembly"; do
        mv "$DEST.partial/${pair##*:}-$JARV.jar" "$DEST.partial/${pair%%:*}.jar"
    done
    rm -rf "$DEST"
    mv "$DEST.partial" "$DEST"
fi

ln -sfn "$DEST" "$PREFIX/current"
rm -f "$REL"

# ------------------------------------------------------------------- migration
# A node set up by hand keeps its keystore wherever the operator put it.
# Importing it keeps their node identity, wallet and balance.

KEYSTORE="$DATA/node.p12"
KEYALIAS=node

# A keystore that was rescued or backed up alongside its node.env carries its
# own password. Use it rather than making the operator remember one.
password_beside(){
    local envf; envf="$(dirname "$1")/node.env"
    [[ -r $envf ]] || return 1
    local pw; pw=$(awk -F= '/^CL_PASSWORD=/{sub(/^CL_PASSWORD=/,""); print}' "$envf" | tr -d '"')
    [[ -n $pw ]] || return 1
    printf '%s' "$pw"
}

# The old guide put the password in the service file's ExecStart. For anyone who
# set their node up months ago, that file may be the only place it is written
# down - so read it rather than asking them to remember it.
password_from_unit(){
    local unit pw
    for unit in /etc/systemd/system/reality*.service; do
        [[ -f $unit ]] || continue
        grep -q '/opt/reality/current/core.jar' "$unit" && continue   # ours, not theirs
        pw=$(grep -oE -- "--password[= ]+[^ '\"]+" "$unit" 2>/dev/null | head -1 | sed -E "s/^--password[= ]+//")
        [[ -n $pw ]] && { printf '%s' "$pw"; return 0; }
    done
    return 1
}

find_old_keystores(){
    local pid cwd arg unit
    # 1. The running node: the --keystore it was started with is the one in use.
    for pid in $(pgrep -f 'run-validator' 2>/dev/null); do
        arg=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -A1 -x -- '--keystore' | tail -1)
        [[ -n $arg ]] || continue
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)
        [[ $arg == /* ]] || arg="$cwd/$arg"
        printf '%s\n' "$arg"
    done
    # 2. An existing service file.
    for unit in /etc/systemd/system/reality*.service; do
        [[ -f $unit ]] || continue
        grep -oE -- '--keystore[= ]+[^ '"'"']+' "$unit" 2>/dev/null | sed -E 's/^--keystore[= ]+//'
    done
    # 3. A keystore sitting in what is clearly a node directory. The jar or the
    #    data/ folder beside it is what makes it a node rather than a backup:
    #    people keep folders full of spare .p12 files, and importing one of those
    #    would silently adopt the wrong identity.
    local f dir
    while read -r f; do
        dir=$(dirname "$f")
        if compgen -G "$dir/reality-*.jar" >/dev/null 2>&1 || [[ -d $dir/data ]]; then
            printf '%s\n' "$f"
        fi
    done < <(find /root /home /opt /srv /var/lib -maxdepth 4 -type f -name '*.p12' \
        -not -path "$PREFIX/*" 2>/dev/null)
}

# An explicit --keystore is always honoured, even if one is already installed.
# The one being replaced is moved aside, never deleted.
if [[ -n $IMPORT_KEYSTORE ]]; then
    [[ -f $IMPORT_KEYSTORE ]] || die "No keystore at $IMPORT_KEYSTORE"
    if [[ -f $KEYSTORE ]] && cmp -s "$IMPORT_KEYSTORE" "$KEYSTORE"; then
        MIGRATED_FROM="$IMPORT_KEYSTORE"
        ok "keystore already installed $MID $IMPORT_KEYSTORE"
    else
        sect "EXISTING NODE FOUND"
        if [[ -f $KEYSTORE ]]; then
            REPLACED="$PREFIX/node.p12.replaced-$(date +%Y%m%d-%H%M%S)"
            mv "$KEYSTORE" "$REPLACED"
            warn "a different keystore was installed here - kept as $(basename "$REPLACED")"
        fi
        install -m 0600 -o "$RUN_USER" -g "$RUN_USER" "$IMPORT_KEYSTORE" "$KEYSTORE"
        MIGRATED_FROM="$IMPORT_KEYSTORE"
        ok "keystore imported $MID the original is untouched"
    fi
    if [[ -z $NODE_PASSWORD ]] && NODE_PASSWORD=$(password_beside "$IMPORT_KEYSTORE"); then
        ok "password read from the node.env beside it"
    elif [[ -z $NODE_PASSWORD ]] && NODE_PASSWORD=$(password_from_unit); then
        ok "password recovered from your old service file"
    fi
fi

if [[ ! -f $KEYSTORE ]]; then
    mapfile -t FOUND < <(find_old_keystores | while read -r f; do [[ -f $f ]] && readlink -f "$f"; done | awk '!seen[$0]++')
    if (( ${#FOUND[@]} > 0 )); then
        sect "EXISTING NODE FOUND"
        pick=""
        if (( ${#FOUND[@]} == 1 )); then
            note "keystore at ${FOUND[0]}"
            if [[ -t 0 ]]; then
                read -r -p '   Import it so you keep your node identity? [Y/n] ' ans
                if [[ ${ans:-Y} =~ ^[Nn] ]]; then
            printf '\n   %s%s  A new identity is a different wallet.%s\n' "$Y" "$WARN" "$R"
            printf '      %sYour existing node has its own address, and any NET it holds or%s\n' "$D" "$R"
            printf '      %searns stays with that address. A new identity starts from zero and%s\n' "$D" "$R"
            printf '      %searns separately - a balance cannot be moved between them.%s\n' "$D" "$R"
            printf '      %sYour old keystore is left untouched either way, so you can still%s\n' "$D" "$R"
            printf '      %simport it later with:  sudo bash install.sh --keystore PATH%s\n\n' "$D" "$R"
                    read -r -p "   Create a new identity anyway? [y/N] " ans2
                    [[ ${ans2:-N} =~ ^[Yy] ]] || pick="${FOUND[0]}"
                    [[ -n ${pick:-} ]] && ok "keeping your existing identity"
                else
                    pick="${FOUND[0]}"
                fi
            else
                note "not importing without a terminal to ask in"
                note "to import it: sudo bash install.sh --keystore ${FOUND[0]}"
            fi
        else
            note "more than one keystore on this machine:"
            for i in "${!FOUND[@]}"; do printf '     %s%d%s  %s\n' "$B" $((i+1)) "$R" "${FOUND[$i]}"; done
            if [[ -t 0 ]]; then
                read -r -p '   Import which one? [number, or n for a new identity] ' ans
                if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#FOUND[@]} )); then
                    pick="${FOUND[$((ans-1))]}"
                else
                printf '\n   %s%s  A new identity is a different wallet.%s\n' "$Y" "$WARN" "$R"
                printf '      %sYour existing node has its own address, and any NET it holds or%s\n' "$D" "$R"
                printf '      %searns stays with that address. A new identity starts from zero and%s\n' "$D" "$R"
                printf '      %searns separately - a balance cannot be moved between them.%s\n' "$D" "$R"
                printf '      %sYour old keystore is left untouched either way, so you can still%s\n' "$D" "$R"
                printf '      %simport it later with:  sudo bash install.sh --keystore PATH%s\n\n' "$D" "$R"
                    read -r -p "   Create a new identity anyway? [y/N] " ans2
                    if [[ ! ${ans2:-N} =~ ^[Yy] ]]; then
                        read -r -p "   Import which one? [number] " ans3
                        [[ $ans3 =~ ^[0-9]+$ ]] && (( ans3 >= 1 && ans3 <= ${#FOUND[@]} )) && pick="${FOUND[$((ans3-1))]}"
                    fi
                fi
            else
                note "not asking without a terminal - a new identity will be created"
            fi
        fi
        if [[ -n $pick ]]; then
            install -m 0600 -o "$RUN_USER" -g "$RUN_USER" "$pick" "$KEYSTORE"
            MIGRATED_FROM="$pick"
            ok "keystore imported $MID the original is untouched"
            if [[ -z $NODE_PASSWORD ]] && NODE_PASSWORD=$(password_beside "$pick"); then
                ok "password read from the node.env beside it"
            elif [[ -z $NODE_PASSWORD ]] && NODE_PASSWORD=$(password_from_unit); then
                ok "password recovered from your old service file"
            fi
            # Stop whatever was running it so it does not fight over the ports.
        else
            note "a new identity will be created"
        fi
    fi
fi

if [[ -f $KEYSTORE ]]; then
    if [[ -z $NODE_PASSWORD && -f $ENVF ]]; then
        NODE_PASSWORD=$(awk -F= '/^CL_PASSWORD=/{sub(/^CL_PASSWORD=/,""); print}' "$ENVF" | tr -d '"')
    fi
    if [[ -z $NODE_PASSWORD && -t 0 ]]; then
        printf '\n   Enter the password of your existing keystore.\n'
        printf '   %s%s%s\n\n' "$D" "${MIGRATED_FROM:-$KEYSTORE}" "$R"
        read -r -s -p '   Password: ' NODE_PASSWORD; printf '\n\n'
    fi
    [[ -n $NODE_PASSWORD ]] || die "Found an existing keystore but no saved password." \
        "Pass it with --password, or run from a terminal so the installer can ask. Do not delete $KEYSTORE if the node holds a balance."
    [[ -n ${MIGRATED_FROM:-} ]] || ok "existing keystore kept $MID $KEYSTORE"
else
    if [[ -z $NODE_PASSWORD ]]; then
        [[ -t 0 ]] || die "A keystore password is needed." \
            "Run with --password YOUR_PASSWORD, or run the installer from a terminal so it can ask you."
        if [[ -n ${MIGRATED_FROM:-} ]]; then
            printf '\n   Enter the password of your existing keystore.\n\n'
        else
            printf '\n   Choose a password for your node keystore.\n'
            printf '   %sYou will need it to move or restore your node. It cannot be reset.%s\n\n' "$D" "$R"
        fi
        while :; do
            read -r -s -p '   Password: ' NODE_PASSWORD; printf '\n'
            read -r -s -p '   Again:    ' NODE_PASSWORD2; printf '\n'
            if [[ ${#NODE_PASSWORD} -lt 8 ]]; then
                printf '   %s%s%s at least 8 characters, please\n\n' "$Y" "$WARN" "$R"
            elif [[ $NODE_PASSWORD != "$NODE_PASSWORD2" ]]; then
                printf '   %s%s%s those did not match, try again\n\n' "$Y" "$WARN" "$R"
            else
                break
            fi
        done
        unset NODE_PASSWORD2
        printf '\n'
    fi
    CL_PASSWORD="$NODE_PASSWORD" java -jar "$PREFIX/current/keytool.jar" generate \
        --keystore "$KEYSTORE" --keyalias "$KEYALIAS" >/dev/null 2>&1 \
        || die "Could not generate the keystore."
    chown "$RUN_USER:$RUN_USER" "$KEYSTORE"
    chmod 0600 "$KEYSTORE"
    ok "keystore created $MID $KEYSTORE"
fi

# A wrong password just means asking again, not starting the installer over.
PW_TRY=0
while :; do
    printf '   %s%s%s reading keystore ...' "$D" "$MID" "$R"
    ID_ERR=$(mktemp)
    NODE_ID=$(CL_KEYSTORE="$KEYSTORE" CL_KEYALIAS="$KEYALIAS" CL_PASSWORD="$NODE_PASSWORD" \
        java -jar "$PREFIX/current/wallet.jar" show-id 2>"$ID_ERR" | tr -dc '0-9a-f' || true)
    printf '\r%72s\r' ""
    if [[ ${#NODE_ID} -ge 64 ]]; then rm -f "$ID_ERR"; break; fi

    if grep -qiE 'password|mac|integrity|keystore' "$ID_ERR"; then
        rm -f "$ID_ERR"
        PW_TRY=$(( PW_TRY + 1 ))
        if [[ -t 0 ]] && (( PW_TRY < 5 )); then
            printf '   %s%s%s that password does not open the keystore, try again\n' "$Y" "$WARN" "$R"
            printf '   %s%s%s\n\n' "$D" "${MIGRATED_FROM:-$KEYSTORE}" "$R"
            read -r -s -p '   Password: ' NODE_PASSWORD; printf '\n\n'
            continue
        fi
        die "That password does not open the keystore." \
            "It is the password used when the keystore was created, and it cannot be reset."
    fi

    printf '\n' >&2; sed 's/^/     /' "$ID_ERR" | tail -5 >&2
    rm -f "$ID_ERR"
    die "Could not read the node ID from the keystore."
done

ok "node id $MID ${NODE_ID:0:8}${MID}${NODE_ID: -6}"

WALLET_ADDRESS=$(CL_KEYSTORE="$KEYSTORE" CL_KEYALIAS="$KEYALIAS" CL_PASSWORD="$NODE_PASSWORD" \
    java -jar "$PREFIX/current/wallet.jar" show-address 2>/dev/null | tr -dc '0-9A-Za-z' || true)
[[ -n $WALLET_ADDRESS ]] && ok "wallet $MID $WALLET_ADDRESS" || warn "could not read the wallet address"

# ---------------------------------------------------------------------- config

# Non-secret settings, readable by everyone so reality works without sudo.
cat > "$CONF/node.conf" <<CONFEOF
# Reality node settings - written by install.sh
NODE_ID=$NODE_ID
WALLET_ADDRESS=$WALLET_ADDRESS
NODE_IP=$NODE_IP
PUBLIC_PORT=$PUBLIC_PORT
P2P_PORT=$P2P_PORT
CLI_PORT=$CLI_PORT
LIBP2P_PORT=$LIBP2P_PORT

# Automatic updates: true installs new releases as they are published.
AUTO_UPDATE=$AUTO_UPDATE

# Watchdog thresholds (seconds)
ORDINAL_STALL_SECONDS=7200
SESSION_STUCK_SECONDS=600
CONFEOF
chmod 0644 "$CONF/node.conf"

# The keystore password. Root and the node only.
umask 077
cat > "$ENVF" <<ENVEOF
# Reality node secrets - written by install.sh. Keep this readable only by root.
CL_KEYSTORE=$KEYSTORE
CL_KEYALIAS=$KEYALIAS
CL_PASSWORD=$NODE_PASSWORD
ENVEOF
chown root:"$RUN_USER" "$ENVF"
chmod 0640 "$ENVF"
umask 022

# ------------------------------------------------------------------ components

install_component(){
    local name="$1" dest="$2" mode="$3" tmp
    tmp=$(mktemp)
    if [[ -n ${REALITY_LOCAL:-} && -f "$REALITY_LOCAL/$name" ]]; then
        cp "$REALITY_LOCAL/$name" "$tmp"
    else
        # Cache-bust: the raw CDN can serve a copy several minutes old.
        curl -fsSL --proto '=https' --max-time 30 -H 'Cache-Control: no-cache' "$RAW/$name?$(date +%s)" -o "$tmp" \
            || { rm -f "$tmp"; die "Could not download $name."; }
    fi
    # A silently empty script is how this system failed once before. Never install one.
    [[ -s $tmp ]] || { rm -f "$tmp"; die "$name downloaded empty - refusing to install it."; }
    head -1 "$tmp" | grep -q '^#!' || { rm -f "$tmp"; die "$name does not look like a script - refusing to install it."; }
    install -m "$mode" -o root -g root "$tmp" "$dest"
    rm -f "$tmp"
}

install_component bin/reality-watchdog.sh "$PREFIX/bin/reality-watchdog.sh" 0755
install_component bin/reality-join.sh     "$PREFIX/bin/reality-join.sh"     0755
install_component bin/reality          /usr/local/bin/reality         0755
rm -f /usr/local/bin/realityctl   # earlier name
ok "watchdog and reality installed"

# --------------------------------------------------------------------- systemd

# Their old unit may hold the only written copy of their password. Keep it.
if [[ -f /etc/systemd/system/reality-node.service ]] \
   && ! grep -q '/opt/reality/current/core.jar' /etc/systemd/system/reality-node.service; then
    UNIT_BAK="/etc/systemd/system/reality-node.service.replaced-$(date +%Y%m%d-%H%M%S)"
    cp /etc/systemd/system/reality-node.service "$UNIT_BAK"
    note "your old service file was kept as $(basename "$UNIT_BAK")"
fi

cat > /etc/systemd/system/reality-node.service <<UNITEOF
[Unit]
Description=Reality Network Validator Node
Documentation=https://github.com/$REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$DATA
EnvironmentFile=$CONF/node.conf
EnvironmentFile=$ENVF
ExecStart=/usr/bin/java -Xms$HEAP -Xmx$HEAP \\
  -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=16M \\
  -XX:InitiatingHeapOccupancyPercent=45 -XX:+ParallelRefProcEnabled \\
  -XX:+UseStringDeduplication -XX:+AlwaysPreTouch \\
  -Djava.net.preferIPv4Stack=true \\
  -jar $PREFIX/current/core.jar run-validator \\
  --keystore $KEYSTORE --keyalias $KEYALIAS \\
  --ip $NODE_IP --collateral $COLLATERAL \\
  --peer-id $NODE_ID --l0-ip $NODE_IP --startup-port $PUBLIC_PORT
Restart=always
RestartSec=10
TimeoutStopSec=60
LimitNOFILE=65535

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=$DATA/data $DATA/logs

[Install]
WantedBy=multi-user.target
UNITEOF

cat > /etc/systemd/system/reality-watchdog.service <<'UNITEOF'
[Unit]
Description=Reality Network watchdog - keeps the node healthy, joined and current
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/reality/bin/reality-watchdog.sh
TimeoutStartSec=900
UNITEOF

cat > /etc/systemd/system/reality-watchdog.timer <<'UNITEOF'
[Unit]
Description=Reality Network watchdog timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
# Spread load so the whole network does not check in at the same instant.
RandomizedDelaySec=90
Persistent=true

[Install]
WantedBy=timers.target
UNITEOF

systemctl daemon-reload
ok "services configured"

# -------------------------------------------------------------------- firewall

sect "NETWORK"

if [[ $DO_FIREWALL == true ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow "$PUBLIC_PORT/tcp" >/dev/null 2>&1 || true
    ufw allow "$P2P_PORT/tcp"    >/dev/null 2>&1 || true
    ufw allow "$LIBP2P_PORT/tcp" >/dev/null 2>&1 || true
    # The CLI port is administrative and stays on localhost.
    ufw delete allow "$CLI_PORT/tcp" >/dev/null 2>&1 || true
    ok "ports $PUBLIC_PORT $MID $P2P_PORT $MID $LIBP2P_PORT opened in ufw"
    note "port $CLI_PORT is administrative and stays private"
elif [[ $DO_FIREWALL == true ]]; then
    ok "no active firewall $MID ports $PUBLIC_PORT, $P2P_PORT and $LIBP2P_PORT must be reachable"
else
    note "firewall left untouched $MID open $PUBLIC_PORT, $P2P_PORT and $LIBP2P_PORT yourself"
fi

# ----------------------------------------------------------------------- start

# Read the node state. Tolerates compact and pretty-printed JSON.
read_state(){
    curl -fsS --max-time 3 "http://127.0.0.1:$PUBLIC_PORT/node/info" 2>/dev/null \
        | grep -oE '"state"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed -E 's/.*:[[:space:]]*"//; s/"$//'
}

# Only now, with the keystore imported and its password confirmed, is it safe to
# stop whatever was running. Doing it earlier would leave an operator with a
# stopped node if the install did not complete.
if [[ -n ${MIGRATED_FROM:-} ]] || ss -ltn 2>/dev/null | grep -qE ":($PUBLIC_PORT|$P2P_PORT)\s"; then
    # Whatever systemd unit is running the old node - it may not be called
    # reality-node - has to be disabled, not just stopped. Restart=always would
    # otherwise bring it straight back to fight over the ports, and it would
    # start again on every boot.
    for pid in $(pgrep -f 'run-validator' 2>/dev/null); do
        oldunit=$(grep -oE '[A-Za-z0-9_.@-]+\.service' "/proc/$pid/cgroup" 2>/dev/null | head -1)
        [[ -z ${oldunit:-} || $oldunit == reality-node.service ]] && continue
        systemctl disable --now "$oldunit" >/dev/null 2>&1 && note "disabled the old service $oldunit"
    done
    tmux kill-session -t reality >/dev/null 2>&1 && note "stopped the old tmux session" || true
    systemctl stop reality-node.service >/dev/null 2>&1 || true
    pkill -f 'run-validator' >/dev/null 2>&1 || true
    sleep 3

    # Reuse the chain the old node already downloaded rather than syncing from
    # scratch. It is only a local copy of the chain, so if the new release cannot
    # read it we fall back to a clean sync below.
    if [[ -n ${MIGRATED_FROM:-} ]]; then
        OLD_DATA="$(dirname "$MIGRATED_FROM")/data"
        if [[ -d $OLD_DATA ]] && [[ ! -d $DATA/data || -z $(ls -A "$DATA/data" 2>/dev/null) ]]; then
            OLD_DATA_SZ=$(du -sh "$OLD_DATA" 2>/dev/null | cut -f1)
            printf '   %s%s%s reusing your existing chain data (%s) ...' "$D" "$MID" "$R" "${OLD_DATA_SZ:-?}"
            rm -rf "$DATA/data"
            if mv "$OLD_DATA" "$DATA/data" 2>/dev/null || cp -a "$OLD_DATA" "$DATA/data" 2>/dev/null; then
                chown -R "$RUN_USER:$RUN_USER" "$DATA/data" 2>/dev/null || true
                ADOPTED_DATA=1
                printf '\r%72s\r' ""
                ok "reusing your existing chain data ${OLD_DATA_SZ:+($OLD_DATA_SZ)} $MID no full resync"
            else
                printf '\r%72s\r' ""
                warn "could not reuse the old chain data - the node will resync"
            fi
        fi
    fi
    if ss -ltn 2>/dev/null | grep -qE ":($PUBLIC_PORT|$P2P_PORT)\s"; then
        die "Port $PUBLIC_PORT or $P2P_PORT is in use by another program." "Stop it, then run the installer again. Check with: sudo ss -ltnp | grep 900"
    fi
fi

systemctl enable reality-node.service    >/dev/null 2>&1
systemctl enable reality-watchdog.timer  >/dev/null 2>&1
start_and_wait(){
    systemctl restart reality-node.service
    printf '   %s%s%s starting node ...' "$D" "$MID" "$R"
    STATE=""
    local i
    for i in $(seq 1 60); do
        STATE=$(read_state) || STATE=""
        [[ -n $STATE ]] && break
        systemctl is-active --quiet reality-node.service || break
        sleep 2
    done
    printf '\r%72s\r' ""
    [[ -n $STATE ]]
}

if ! start_and_wait; then
    if [[ -n ${ADOPTED_DATA:-} ]]; then
        # The old chain data is the most likely reason, and it is replaceable.
        warn "the node would not start with the old chain data"
        mv "$DATA/data" "$DATA/data-unusable-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || rm -rf "$DATA/data"
        note "set it aside - starting again with a fresh sync"
        ADOPTED_DATA=""
        start_and_wait || {
            printf '\n   %s%s the node stopped while starting up%s\n\n' "$E" "$NO" "$R" >&2
            journalctl -u reality-node.service -n 15 --no-pager | sed 's/^/     /' >&2
            exit 1
        }
    else
        printf '\n   %s%s the node stopped while starting up%s\n\n' "$E" "$NO" "$R" >&2
        journalctl -u reality-node.service -n 15 --no-pager | sed 's/^/     /' >&2
        exit 1
    fi
fi
ok "node running $MID state $STATE                 "

systemctl start reality-watchdog.timer >/dev/null 2>&1
ok "watchdog active $MID checks every 5 minutes"

if [[ $STATE == ReadyToJoin ]]; then
    printf '   %s%s%s joining the network ...' "$D" "$MID" "$R"
    "$PREFIX/bin/reality-join.sh" >/dev/null 2>&1 || true
    STATE=$(read_state) || STATE=""
    printf '\r'
fi

case "$STATE" in
    Observing|Ready|WaitingForObserving|WaitingForReady|DownloadInProgress|RedownloadInProgress|WaitingForDownload)
        ok "joined the network $MID state $STATE            " ;;
    SessionStarted)
        ok "join accepted $MID state $STATE                 "
        note "if it stays here for 10 minutes, peers cannot reach ports $P2P_PORT and $LIBP2P_PORT" ;;
    *)
        warn "not joined yet $MID state ${STATE:-unknown}"
        note "the watchdog will keep trying every 5 minutes" ;;
esac

# --------------------------------------------------------------------- summary

printf '\n'
[[ -n ${MIGRATED_FROM:-} ]] && ok "migrated from $MIGRATED_FROM $MID same node id, same wallet" && printf '\n'
btop
brow " Node ID   ${NODE_ID:0:8}${MID}${NODE_ID: -6}"
brow " Wallet    ${WALLET_ADDRESS:-unknown}"
brow " Public    $NODE_IP:$PUBLIC_PORT"
brow " Version   $TAG"
brow " Status    $DOT ${STATE:-starting}"
bbot
printf '\n'
printf '   %s%s  Back up %s%s\n' "$Y" "$WARN" "$KEYSTORE$R" ""
printf '      %sit is your node identity and cannot be recovered.%s\n' "$D" "$R"
printf '      %sRemember your password - it is also kept in %s%s\n' "$D" "$ENVF" "$R"
printf '\n'
if [[ -n ${MIGRATED_FROM:-} ]]; then
    OLD_DIR=$(dirname "$MIGRATED_FROM")
    if [[ -d $OLD_DIR && $OLD_DIR != "$PREFIX" ]]; then
        OLD_SZ=$(du -sh "$OLD_DIR" 2>/dev/null | cut -f1)
        note "your old node is still in $OLD_DIR (${OLD_SZ:-?}), untouched"
        note "delete it once you are happy: sudo rm -rf $OLD_DIR"
        printf '\n'
    fi
fi
printf '   %sYOUR COMMANDS%s\n' "$B" "$R"
printf '   reality status          how your node is doing\n'
printf '   reality logs            watch the node log live   %s(Ctrl-C to leave, node keeps running)%s\n' "$D" "$R"
printf '   sudo reality stop       stop the node\n'
printf '   sudo reality start      start the node\n'
printf '   sudo reality restart    restart the node\n'
printf '   sudo reality pause      stop the node and keep it stopped %s(watchdog off)%s\n' "$D" "$R"
printf '   sudo reality resume     start the node and the watchdog again\n'
printf '   sudo reality backup     save your keystore somewhere safe\n'
printf '   reality                 everything else\n'
printf '\n'

# ---------------------------------------------------------------------- reboot
# The node and watchdog are enabled, so after a reboot they come back and join
# on their own. Ask now rather than leaving a half-applied kernel update behind.

if [[ -f /var/run/reboot-required ]]; then
    warn "the system upgrade needs a reboot to finish"
    note "your node starts again by itself after the reboot - nothing to run"
    note "log back in a few minutes later and type: reality status"
    if [[ -t 0 ]]; then
        read -r -p '   Reboot now? [Y/n] ' ans
        if [[ ! ${ans:-Y} =~ ^[Nn] ]]; then
            printf '\n   %srebooting - see you on the other side%s\n\n' "$D" "$R"
            sleep 2
            systemctl reboot
        else
            note "reboot when convenient with: sudo reboot"
        fi
    else
        note "reboot when convenient with: sudo reboot"
    fi
    printf '\n'
fi
