#!/bin/bash
# Tests the Android core against the debug Mac app over real TLS.
# The Mac uses a separate port, folders, and clipboard, and doesn't inject input.
set -uo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# dysklink-android is a separate repository. Clone it next to this one, or set DYSKLINK_ANDROID_DIR.
ANDROID_DIR="${DYSKLINK_ANDROID_DIR:-}"
if [ -z "$ANDROID_DIR" ]; then
    for candidate in "$MAC_DIR/../dysklink-android" "$MAC_DIR/../android"; do
        [ -x "$candidate/gradlew" ] && ANDROID_DIR="$candidate" && break
    done
fi
if [ ! -x "${ANDROID_DIR:-/nonexistent}/gradlew" ]; then
    echo "Can't find dysklink-android. Clone it next to this repository or set DYSKLINK_ANDROID_DIR." >&2
    exit 2
fi
WORK="$(mktemp -d)"
PORT=47999
LOG="$WORK/mac.log"
DOWNLOADS="$WORK/downloads"
mkdir -p "$WORK/data" "$DOWNLOADS"
trap '[ -n "${MAC_PID:-}" ] && kill "$MAC_PID" 2>/dev/null; [ -n "${KEEP_LOG:-}" ] && cp "$LOG" "$KEEP_LOG"; rm -rf "$WORK"' EXIT

cat > "$WORK/data/commands.json" <<'JSON'
[{"id":"uji","name":"Uji","script":"echo halo-dari-mac"}]
JSON
echo "isi dari mac" > "$WORK/dari-mac.txt"

cd "$MAC_DIR"
swift build 2>&1 | grep -E "error:|Build complete" | sed 's/\x1b\[[0-9;]*m//g'
PHONELINK_DATA_DIR="$WORK/data" PHONELINK_PORT=$PORT PHONELINK_DOWNLOAD_DIR="$DOWNLOADS" PHONELINK_PHOTO_DIR="$WORK/photos" \
PHONELINK_TEST_AUTO_ACCEPT=1 PHONELINK_TEST_DRY_RUN=1 PHONELINK_TEST_SEND_FILE="$WORK/dari-mac.txt" \
PHONELINK_TEST_PROBE_PHONE=1 PHONELINK_TEST_TERMINAL=1 PHONELINK_TEST_AUTOLOCK=1 PHONELINK_TEST_MACSCREEN=1 PHONELINK_TEST_AUDIO=1 \
    "$(swift build --show-bin-path)/PhoneLinkMac" > "$LOG" 2>&1 &
MAC_PID=$!

for _ in $(seq 1 30); do
    nc -z 127.0.0.1 $PORT 2>/dev/null && break
    /bin/sleep 0.5
done

cd "$ANDROID_DIR"
JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}" \
DYSKLINK_IT_PORT=$PORT DYSKLINK_IT_DOWNLOADS="$DOWNLOADS" DYSKLINK_IT_PHOTOS="$WORK/photos" \
    ./gradlew :core:test :app:testDebugUnitTest --rerun-tasks --continue --console=plain 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^e: |FAILED|BUILD|AssertionError|tests completed"
RESULT=${PIPESTATUS[0]}

python3 - core/build/test-results/test app/build/test-results/testDebugUnitTest <<'EOF'
import glob, sys, xml.etree.ElementTree as E
for path in sorted(p for folder in sys.argv[1:] for p in glob.glob(folder + "/*.xml")):
    root = E.parse(path).getroot()
    print(f"{root.get('name').split('.')[-1]}: {root.get('tests')} tests, "
          f"{root.get('failures')} failed, {root.get('errors')} errors, {root.get('skipped')} skipped")
EOF

check() {
    if grep -qF "$2" "$LOG"; then
        [ "$1" = present ] && echo "OK  present: $2" || { echo "FAILED must be absent: $2"; RESULT=1; }
    else
        [ "$1" = absent ] && echo "OK  absent: $2" || { echo "FAILED must be present: $2"; RESULT=1; }
    fi
}
check present "CLIPBOARD_SET dari-hp-uji"
check present "NOTCH_ACTION todo.add uji-tugas"
check absent "NOTCH_ACTION todo.add asing-tugas"
check present "RING start"
check present "RING stop"
check present "MAC_ACTION lock"
check present "LOCK"
check present "MEDIA play_pause"
check present "INPUT key right"
check present "INPUT shortcut cmd+shift+4"
check present "TERMINAL_OPENED"
check present "TERMINAL_CLOSED"
check absent "bukan-aksi"
check absent "dari-perangkat-asing"
check present "PHONE_SMS sms.messages halo-dari-hp"
check present "PHONE_SMS sms.new sms-baru"
check present "PHONE_CODE 482915"
/bin/sleep 2
check present "AUTOLOCK"
check present "CAMERA_STARTED 1280x720 front 270"
check present "CAMERA_STARTED 1280x720 front 0"
check present "CAMERA_STOPPED uji-berhenti"
check absent "CAMERA_STARTED 1281x721"
check present "MACSCREEN_STARTED"
check present "MACSCREEN_FRAME key=true"
check present "MACSCREEN_DISPLAYS"
check present "POINTER click"
check present "MACSCREEN_STOPPED"
check present "MACSCREEN_WATCHERS 1"
check present "PHONE_GALLERY 2 end=true"
check present "MAC_AUDIO_LISTEN"
check present "MAC_AUDIO_SENT"
check present "MAC_AUDIO_STOPPED"
check present "PHONE_AUDIO_STARTED tight=false"
check present "PHONE_AUDIO_PLAYING 7680"
check present "GALLERY_FILE PXL_uji.jpg save"
check present "SECOND_DISPLAY 1332x600"
check present "SECOND_DISPLAY 600x1332"
check present "SECOND_DISPLAY 1000x450 large"
check present "PHONE_SMS_RESULT ok=true"
check present "PHONE_CONTACTS 1"
check present "FN:Budi\\, Santoso~N:Budi\\, Santoso;;;;~TEL;TYPE=CELL:+6281200000002~END:VCARD"
check present "PHONE_CALL missed Budi, Santoso"
check present "PHONE_NOTIFICATION AppLama Lama silent=true"
check present "PHONE_NOTIFICATION AppBaru Baru silent=false"
check present "PHONE_NOTIFICATION_REMOVED k-baru"
check present "PHONE_FS  folder"
check present "PHONE_FEATURES calls,contacts,control,files,gallery,notifications,screen,screentime,sms contacts=0"
check present "PHONE_USAGE 95 Obrolan 60 unlocks=12"
check present "SCREEN_STARTED 720x1280"
check present "SCREEN_STOPPED"
check absent "SCREEN_STARTED 1234x1234"
check absent "PHONE_SMS sms.new sebelum-diaktifkan"

cd "$MAC_DIR"
if "$(swift build --show-bin-path)/PhoneLinkMac" --video-selftest; then
    echo "OK  video decoder"
else
    echo "FAILED video decoder"
    RESULT=1
fi

if "$(swift build --show-bin-path)/PhoneLinkMac" --tools-selftest; then
    echo "OK  advanced tools"
else
    echo "FAILED advanced tools"
    RESULT=1
fi

exit "$RESULT"
