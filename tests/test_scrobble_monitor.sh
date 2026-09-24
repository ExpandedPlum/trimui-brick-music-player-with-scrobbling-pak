#!/bin/sh
# Replay tests for scrobble_monitor.sh.
#
# Feeds sequences of musicserver status snapshots through the monitor's tick()
# with a fake clock and checks what ends up in the scrobble log.
#
# Usage: sh tests/test_scrobble_monitor.sh

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Configuration read by the sourced monitor
# shellcheck disable=SC2034
MUSIC_STATUS="$WORK/status"
MUSIC_INFO="$WORK/music_info.txt"
SCROBBLE_LOG="$WORK/.scrobbler.log"
# shellcheck disable=SC2034
PID_FILE="$WORK/monitor.pid"
POLL_INTERVAL=4
# shellcheck disable=SC2034
INACTIVITY_TIMEOUT=600
# shellcheck disable=SC2034
SCROBBLE_MONITOR_LIB=1
# shellcheck source=scrobble_monitor.sh
. "$TESTS_DIR/../scrobble_monitor.sh"

# Fake music server
SERVER_UP=1
server_alive() { [ "$SERVER_UP" = 1 ]; }

T0=1700000000
NOW=$T0
FAILURES=0
TESTS=0

# status <status> <filename> <title> <artist> [album] [track] [duration]
status() {
    printf '{"status":"%s","duration":%s,"position":0,"volume":100,"filename":"%s","title":"%s","artist":"%s","album":"%s","year":"2010","track":"%s","genre":"Rock"}\n' \
        "$1" "${7:-0}" "$2" "$3" "$4" "${5:-Album}" "${6:-1}" >"$MUSIC_STATUS"
}

# info <filename> <HH:MM:SS.cs>  — ffprobe-style output as written by musicserver
info() {
    cat >"$MUSIC_INFO" <<EOF
Input #0, mp3, from '$1':
  Metadata:
    title           : whatever
  Duration: $2, start: 0.025057, bitrate: 320 kb/s
    Stream #0:0: Audio: mp3, 44100 Hz, stereo, fltp, 320 kb/s
EOF
}

# run <seconds>  — advance the fake clock, polling every POLL_INTERVAL
run() {
    _end=$((NOW + $1))
    while [ "$NOW" -lt "$_end" ]; do
        NOW=$((NOW + POLL_INTERVAL))
        tick "$NOW" >/dev/null
    done
}

setup() {
    rm -f "$MUSIC_STATUS" "$MUSIC_INFO" "$SCROBBLE_LOG"
    SERVER_UP=1
    NOW=$T0
    init_state
}

entries() { grep -v '^#' "$SCROBBLE_LOG" 2>/dev/null; }
entry_count() { entries | grep -c .; }

check() {
    TESTS=$((TESTS + 1))
    if [ "$2" = "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1"
        echo "       expected: [$3]"
        echo "       actual:   [$2]"
        FAILURES=$((FAILURES + 1))
    fi
}

TAB=$(printf '\t')

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:03:20.50
status playing /music/a.mp3 "Song A" "Artist A" "Album A" 4
run 60
check "not scrobbled before threshold" "$(entry_count)" 0
run 60
check "scrobbled once threshold (half of 200s) is played" "$(entry_count)" 1
check "log has header" "$(head -1 "$SCROBBLE_LOG")" "#AUDIOSCROBBLER/1.1"
check "entry fields and start timestamp" "$(entries)" \
    "Artist A${TAB}Album A${TAB}Song A${TAB}4${TAB}200${TAB}L${TAB}$((T0 + 4))${TAB}"
run 60
check "not scrobbled twice while still playing" "$(entry_count)" 1

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:03:20.50
status playing /music/a.mp3 "Song A" "Artist A"
run 40
info /music/b.mp3 00:03:00.00
status playing /music/b.mp3 "Song B" "Artist B"
run 20
check "skipped track is not scrobbled" "$(entry_count)" 0

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:03:20.50
status playing /music/a.mp3 "Song A" "Artist A"
run 20
status paused /music/a.mp3 "Song A" "Artist A"
run 900
check "paused time does not count as listening" "$(entry_count)" 0
status playing /music/a.mp3 "Song A" "Artist A"
run 90
check "listening resumes counting after pause" "$(entry_count)" 1

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:03:20.50
status playing /music/a.mp3 "Song A" "Artist A"
run 20
NOW=$((NOW + 3600))   # device slept for an hour mid-track
run 8
check "sleep/clock jump does not count as listening" "$(entry_count)" 0

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:00:40.00
status playing /music/a.mp3 "Loop" "Artist A"
run 200
check "repeat-one plays are each scrobbled" "$(entry_count)" 5
check "repeat plays are timestamped a track length apart" "$(entries | cut -f7 | tr '\n' ' ')" \
    "$((T0 + 4)) $((T0 + 44)) $((T0 + 84)) $((T0 + 124)) $((T0 + 164)) "

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:00:25.00
status playing /music/a.mp3 "Short" "Artist A"
run 60
check "track shorter than 30s is not scrobbled" "$(entry_count)" 0

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:20:00.00
status playing /music/a.mp3 "Long" "Artist A"
run 236
check "long track not scrobbled before 240s" "$(entry_count)" 0
run 8
check "long track scrobbled at 240s" "$(entry_count)" 1

# ---------------------------------------------------------------------------
setup
status playing /music/a.mp3 "Unknown" "Artist A"
run 200
check "unknown duration not scrobbled before 240s" "$(entry_count)" 0
run 48
check "unknown duration scrobbled after 240s" "$(entry_count)" 1
check "unknown duration logs played time" "$(entries | cut -f5)" 240

# ---------------------------------------------------------------------------
setup
info /music/old.mp3 00:10:00.00
status playing /music/a.mp3 "Song A" "Artist A" Album 1 180000
run 100
check "stale music_info is ignored; ms JSON duration used" "$(entries | cut -f5)" 180

# ---------------------------------------------------------------------------
setup
info /music/old.mp3 00:10:00.00
status playing /music/a.mp3 "Song A" "Artist A"
run 20
info /music/a.mp3 00:01:00.00
run 20
check "duration picked up once music_info catches up" "$(entries | cut -f5)" 60

# ---------------------------------------------------------------------------
setup
printf 'Duration: 00:02:00.00, start: 0\n' >"$MUSIC_INFO"
status playing /music/a.mp3 "Song A" "Artist A"
run 64
check "music_info without a file line is still used" "$(entries | cut -f5)" 120

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:03:20.50
status playing /music/a.mp3 "Song A" "Artist A"
run 40
SERVER_UP=0   # server died; status file left behind saying "playing"
run 300
check "stale status file after server exit is not counted" "$(entry_count)" 0
run 304
check "monitor exits after inactivity timeout" "$SHOULD_EXIT" 1

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:02:00.00
status playing /music/a.mp3 "Song A" "Artist A"
run 20
printf '{"status":"playing","filena' >"$MUSIC_STATUS"   # caught mid-write
run 4
status playing /music/a.mp3 "Song A" "Artist A"
run 48
check "partially written status does not reset the track" "$(entry_count)" 1

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:02:00.00
status playing /music/a.mp3 "" ""
run 8
status playing /music/a.mp3 "Late Title" "Late Artist"
run 60
check "metadata filled in after the file appears is used" "$(entries | cut -f1,3)" "Late Artist${TAB}Late Title"

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:02:00.00
status playing /music/a.mp3 "No Artist" ""
run 120
check "track without artist is not scrobbled" "$(entry_count)" 0

# ---------------------------------------------------------------------------
setup
info '/music/it'"'"'s.mp3' 00:02:00.00
printf '%s\n' '{"status":"playing","duration":0,"filename":"/music/it'"'"'s.mp3",' \
    '"title":"Say \"Hi\"\tnow \\ \/ é🎵","artist":"Björk","album":"A\tB","track":"2"}' >"$MUSIC_STATUS"
run 64
check "JSON escapes decoded and tabs removed" "$(entries | cut -f1-4)" \
    "Björk${TAB}A B${TAB}Say \"Hi\" now \\ / é🎵${TAB}2"

# ---------------------------------------------------------------------------
setup
printf '{ "status" : "playing", "title": "artist", "artist" : "title", "filename": "/music/a.mp3" }\n' >"$MUSIC_STATUS"
info /music/a.mp3 00:02:00.00
run 64
check "whitespace and key-like values parsed correctly" "$(entries | cut -f1,3)" "title${TAB}artist"

# ---------------------------------------------------------------------------
setup
info /music/a.mp3 00:02:00.00
status playing /music/a.mp3 "Song A" "Artist A"
run 64
rm -f "$SCROBBLE_LOG"   # user deleted the log while the monitor was running
info /music/b.mp3 00:02:00.00
status playing /music/b.mp3 "Song B" "Artist B"
run 64
check "header rewritten when log is deleted" "$(head -1 "$SCROBBLE_LOG")" "#AUDIOSCROBBLER/1.1"
check "entry appended after new header" "$(entry_count)" 1

# ---------------------------------------------------------------------------
setup
T_SAVED=$T0
T0=86400
NOW=$T0
info /music/a.mp3 00:02:00.00
status playing /music/a.mp3 "Song A" "Artist A"
run 64
check "plays are not logged while the clock is unset" "$(entry_count)" 0
T0=$T_SAVED

# ---------------------------------------------------------------------------
echo
echo "$((TESTS - FAILURES))/$TESTS passed"
[ "$FAILURES" = 0 ]
