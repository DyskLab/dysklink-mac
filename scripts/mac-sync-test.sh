#!/bin/bash
# Runs two debug Mac apps on this computer and checks pairing and clipboard sync between them.
# Each uses its own port, folders, and pasteboard, and neither touches the real clipboard.
set -uo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'kill ${A:-} ${B:-} 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/a" "$WORK/b" "$WORK/da" "$WORK/db"
cd "$MAC_DIR"
swift build 2>&1 | grep -E "error:|Build complete" | sed 's/\x1b\[[0-9;]*m//g'
BIN="$(swift build --show-bin-path)/PhoneLinkMac"
RESULT=0
# A small real picture for the clipboard test.
sips -s format png -z 64 96 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns --out "$WORK/pic.png" >/dev/null 2>&1
PIC_SIZE=$(stat -f %z "$WORK/pic.png")

# $1 label, $2 1 if Mac B allows other Macs, $3 text Mac A copies, $4 1 if Mac B lets Macs use their mouse and keyboard
run() {
    env ${B_ENV:-} PHONELINK_DATA_DIR="$WORK/b" PHONELINK_PORT=47991 PHONELINK_DOWNLOAD_DIR="$WORK/db" PHONELINK_TEST_AUTO_ACCEPT=1 \
    PHONELINK_TEST_DRY_RUN=1 PHONELINK_TEST_MAC_SYNC="$2" PHONELINK_TEST_REMOTE_ACCEPT="${4:-0}" "$BIN" > "$WORK/b-$1.log" 2>&1 &
    B=$!
    for _ in $(seq 1 30); do nc -z 127.0.0.1 47991 2>/dev/null && break; /bin/sleep 0.5; done
    env ${A_ENV:-} PHONELINK_DATA_DIR="$WORK/a" PHONELINK_PORT=47992 PHONELINK_DOWNLOAD_DIR="$WORK/da" PHONELINK_TEST_AUTO_ACCEPT=1 \
    PHONELINK_TEST_DRY_RUN=1 PHONELINK_TEST_MAC_SYNC=1 PHONELINK_TEST_PAIR_MAC=1 \
    PHONELINK_TEST_CONNECT_MAC=127.0.0.1:47991 PHONELINK_TEST_SHARE_CLIPBOARD="$3" PHONELINK_TEST_SHARE_IMAGE="$WORK/pic.png" PHONELINK_TEST_REMOTE_DEMO=1 "$BIN" > "$WORK/a-$1.log" 2>&1 &
    A=$!
    /bin/sleep "${WAIT:-6}"
    kill $A $B 2>/dev/null; wait $A $B 2>/dev/null
}

check() { # present|absent, file, text
    if grep -qF "$3" "$2"; then
        [ "$1" = present ] && echo "OK  $1: $3" || { echo "FAILED must be absent: $3"; RESULT=1; }
    else
        [ "$1" = absent ] && echo "OK  $1: $3" || { echo "FAILED missing: $3"; RESULT=1; }
    fi
}

run first 1 "dari-mac-a"
check present "$WORK/a-first.log" "PAIRING_DONE"
check present "$WORK/b-first.log" "PAIRING_DONE"
codes=$(grep -h "PAIRING_CODE" "$WORK/a-first.log" "$WORK/b-first.log" | sort -u | wc -l | tr -d ' ')
[ "$codes" = 1 ] && echo "OK  both Macs show the same code" || { echo "FAILED the codes differ"; RESULT=1; }
check present "$WORK/b-first.log" "CLIPBOARD_SET dari-mac-a"
check present "$WORK/b-first.log" "CLIPBOARD_IMAGE_SET $PIC_SIZE"

run again 1 "kedua-kali" 1
check absent "$WORK/b-again.log" "PAIRING_CODE"
check present "$WORK/b-again.log" "CLIPBOARD_SET kedua-kali"
# Mouse and keyboard: Mac A crosses over, moves, types, and ends.
check present "$WORK/b-again.log" "REMOTE_ENTER left 0.50"
check present "$WORK/b-again.log" "REMOTE move"
check present "$WORK/b-again.log" "REMOTE key 0"
check present "$WORK/b-again.log" "REMOTE_RELEASED"

# Paired, but Mac B doesn't let other Macs use their mouse and keyboard.
check present "$WORK/b-first.log" "REMOTE_REFUSED"
check absent "$WORK/b-first.log" "REMOTE_ENTER"
check absent "$WORK/b-first.log" "REMOTE move"

# A large file to the other Mac must not hold up live messages: Mac A pings every 20 ms while it sends.
head -c $((48 * 1024 * 1024)) /dev/urandom > "$WORK/big.bin"
# Mac B reads at about 12 MB/s, like Wi-Fi, so data waits on the way as it would there.
A_ENV="PHONELINK_TEST_SEND_FILE=$WORK/big.bin PHONELINK_TEST_LATENCY=1" B_ENV="PHONELINK_TEST_READ_MBPS=12" WAIT=14 run big 1 "besar"
grep -h "LATENCY" "$WORK/a-big.log" | sed 's/^/    /'
check present "$WORK/a-big.log" "status=done"
if [ "$(shasum -a 256 < "$WORK/big.bin")" = "$(cat "$WORK/db/big.bin" 2>/dev/null | shasum -a 256)" ]; then
    echo "OK  large file arrived whole"
else
    echo "FAILED large file"; RESULT=1
fi
RTT_MAX=$(grep -h "LATENCY" "$WORK/a-big.log" | tail -1 | sed -E 's/.*rtt p50=[0-9]+ p95=([0-9]+).*/\1/')
if [ -n "$RTT_MAX" ] && [ "$RTT_MAX" -lt "${LATENCY_LIMIT_MS:-150}" ]; then
    echo "OK  ping p95 ${RTT_MAX} ms during the transfer"
else
    echo "FAILED ping p95 ${RTT_MAX:-?} ms during the transfer (limit ${LATENCY_LIMIT_MS:-150})"; RESULT=1
fi

run off 0 "tidak-boleh"
check absent "$WORK/b-off.log" "CLIPBOARD_SET tidak-boleh"
check absent "$WORK/b-off.log" "CLIPBOARD_IMAGE_SET"

exit $RESULT
