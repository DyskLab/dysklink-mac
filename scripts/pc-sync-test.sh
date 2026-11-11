#!/bin/bash
# Runs a debug Mac app with Other computers on, and the Windows/Linux computer side (ComputerHub) against it from the
# JVM tests. Checks pairing by code, text and pictures both ways, files, and ringing. Touches no real clipboard.
set -uo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$MAC_DIR/../android"
WORK="$(mktemp -d)"
trap 'kill ${M:-} 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/data" "$WORK/dl"
cd "$MAC_DIR"
swift build 2>&1 | grep -E "error:|Build complete" | sed 's/\x1b\[[0-9;]*m//g'
BIN="$(swift build --show-bin-path)/PhoneLinkMac"
sips -s format png -z 64 96 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns --out "$WORK/pic.png" >/dev/null 2>&1
PORT=47993
RESULT=0

PHONELINK_DATA_DIR="$WORK/data" PHONELINK_PORT=$PORT PHONELINK_DOWNLOAD_DIR="$WORK/dl" PHONELINK_TEST_AUTO_ACCEPT=1 \
PHONELINK_TEST_DRY_RUN=1 PHONELINK_TEST_MAC_SYNC=1 PHONELINK_TEST_SHARE_CLIPBOARD="dari-mac" \
PHONELINK_TEST_SHARE_IMAGE="$WORK/pic.png" "$BIN" > "$WORK/mac.log" 2>&1 &
M=$!
for _ in $(seq 1 30); do nc -z 127.0.0.1 $PORT 2>/dev/null && break; /bin/sleep 0.5; done

cd "$ANDROID_DIR"
DYSKLINK_IT_MAC_PORT=$PORT JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}" \
    ./gradlew -q :core:test --tests '*ComputerHubTest.aPcPairsAndSyncsWithTheMacApp' --rerun-tasks > "$WORK/pc.log" 2>&1
PC_EXIT=$?
kill $M 2>/dev/null; wait $M 2>/dev/null

check() { # present|absent, text
    if grep -qF "$2" "$WORK/mac.log"; then
        [ "$1" = present ] && echo "OK  Mac: $2" || { echo "FAILED must be absent: $2"; RESULT=1; }
    else
        [ "$1" = absent ] && echo "OK  Mac: absent $2" || { echo "FAILED missing on the Mac: $2"; RESULT=1; }
    fi
}

if [ $PC_EXIT = 0 ]; then echo "OK  PC side: paired, got the Mac's text and picture"; else
    echo "FAILED PC side:"; grep -E "AssertionError|Exception|FAILED" "$WORK/pc.log" | head -5
    python3 - "$ANDROID_DIR/core/build/test-results/test" <<'PY'
import glob,sys,xml.etree.ElementTree as E
for p in glob.glob(sys.argv[1]+"/*ComputerHub*.xml"):
    for c in E.parse(p).getroot().iter('testcase'):
        for f in list(c.findall('failure'))+list(c.findall('error')): print("   ",c.get('name'),(f.get('message') or '')[:300])
PY
    RESULT=1
fi
check present "PAIRING_DONE"
check present "CLIPBOARD_IMAGE_SENT"
check present "CLIPBOARD_SET dari-pc"
check present "CLIPBOARD_IMAGE_SET 5000"
check present "RING start"
# The PC lists bin1 like the real desktop app, so pictures and files went in binary frames both ways.
check present "BINARY_IN file.chunk"
check present "BINARY_OUT file.chunk"
if ls "$WORK/dl" | grep -q "^dari-pc.*\.txt$"; then echo "OK  Mac: the PC's file is in Downloads"; else echo "FAILED the PC's file didn't arrive"; RESULT=1; fi
cd "$ANDROID_DIR" && ./gradlew --stop -q >/dev/null 2>&1
exit $RESULT
