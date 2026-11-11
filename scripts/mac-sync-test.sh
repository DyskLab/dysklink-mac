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

# $1 label, $2 1 if Mac B allows other Macs, $3 text Mac A copies
run() {
    PHONELINK_DATA_DIR="$WORK/b" PHONELINK_PORT=47991 PHONELINK_DOWNLOAD_DIR="$WORK/db" PHONELINK_TEST_AUTO_ACCEPT=1 \
    PHONELINK_TEST_DRY_RUN=1 PHONELINK_TEST_MAC_SYNC="$2" "$BIN" > "$WORK/b-$1.log" 2>&1 &
    B=$!
    for _ in $(seq 1 30); do nc -z 127.0.0.1 47991 2>/dev/null && break; /bin/sleep 0.5; done
    PHONELINK_DATA_DIR="$WORK/a" PHONELINK_PORT=47992 PHONELINK_DOWNLOAD_DIR="$WORK/da" PHONELINK_TEST_AUTO_ACCEPT=1 \
    PHONELINK_TEST_DRY_RUN=1 PHONELINK_TEST_MAC_SYNC=1 PHONELINK_TEST_PAIR_MAC=1 \
    PHONELINK_TEST_CONNECT_MAC=127.0.0.1:47991 PHONELINK_TEST_SHARE_CLIPBOARD="$3" "$BIN" > "$WORK/a-$1.log" 2>&1 &
    A=$!
    /bin/sleep 6
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

run again 1 "kedua-kali"
check absent "$WORK/b-again.log" "PAIRING_CODE"
check present "$WORK/b-again.log" "CLIPBOARD_SET kedua-kali"

run off 0 "tidak-boleh"
check absent "$WORK/b-off.log" "CLIPBOARD_SET tidak-boleh"

exit $RESULT
