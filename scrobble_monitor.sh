#!/bin/sh
# =============================================================================
# scrobble_monitor.sh — TrimUI Music Player Last.fm Scrobble Monitor
# =============================================================================
# Watches the TrimUI musicserver's status file and writes track plays to a
# standard .scrobbler.log file (Rockbox/Audioscrobbler format).
#
# Usage:
#   scrobble_monitor.sh          run the monitor (exits if one is already running)
#   scrobble_monitor.sh stop     stop a running monitor
#
# The musicserver writes a JSON status file:
#   /tmp/trimui_music/status
#
# Example content:
#   {"status":"playing","duration":0,"position":0,"volume":100,
#    "filename":"/mnt/SDCARD/Music/Artist/song.mp3",
#    "title":"Song Title","artist":"Artist","album":"Album",
#    "year":"2010","track":"4","genre":"Math Rock"}
#
# Duration is read from /tmp/trimui_music/music_info.txt (ffprobe output)
# because the JSON "duration" field is unreliable (often 0).
#
# Format per line (tab-separated):
#   artist  album  title  tracknum  duration  L  unix_timestamp  (empty mbid)
#
# Last.fm scrobble rules honoured:
#   - Track must be >= 30 seconds long
#   - Track must have been played for >= min(track_duration/2, 240 seconds)
#
# A track is logged as soon as it has been *played* (paused time and device
# sleep excluded) long enough, so plays are not lost if the device powers off
# or the monitor is stopped before the track ends.
#
# All paths and timings can be overridden through the environment (used by the
# test suite in tests/).
# =============================================================================

MUSIC_STATUS="${MUSIC_STATUS:-/tmp/trimui_music/status}"
MUSIC_INFO="${MUSIC_INFO:-/tmp/trimui_music/music_info.txt}"
SCROBBLE_LOG="${SCROBBLE_LOG:-${SDCARD_PATH:-/mnt/SDCARD}/.scrobbler.log}"
PID_FILE="${PID_FILE:-/tmp/scrobble_monitor.pid}"
# Where the monitor writes its own diagnostic messages
MONITOR_LOG="${SCROBBLE_MONITOR_LOG:-/dev/null}"

# Seconds between polls of the status file
POLL_INTERVAL="${POLL_INTERVAL:-4}"
# Exit after this many seconds without a running music server (conserve resources)
INACTIVITY_TIMEOUT="${INACTIVITY_TIMEOUT:-600}"
# Timestamps before this (2020-01-01) mean the clock was never set; don't log them
MIN_VALID_TIME="${MIN_VALID_TIME:-1577836800}"

US=$(printf '\037')

# ---------------------------------------------------------------------------
# Is the music server running? A stale status file can outlive the server,
# so the process is the source of truth.
# ---------------------------------------------------------------------------
server_alive() {
    pidof musicserver >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Parse the JSON status file in a single pass. Prints the fields
#   status filename title artist album track duration
# on one line, separated by \037. Handles JSON escapes (\" \\ \/ \uXXXX) and
# replaces tabs/newlines with spaces so values are safe for the TSV log.
# ---------------------------------------------------------------------------
parse_status() {
    LC_ALL=C awk '
    function hexval(h,   i, c, v) {
        if (length(h) != 4) return -1
        h = tolower(h); v = 0
        for (i = 1; i <= 4; i++) {
            c = index("0123456789abcdef", substr(h, i, 1))
            if (c == 0) return -1
            v = v * 16 + c - 1
        }
        return v
    }
    function utf8(cp) {
        if (cp < 32) return " "
        if (cp < 128) return sprintf("%c", cp)
        if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
        if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
        return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
    }
    function field(key,   rest, p, s, c, out, i, n, cp, lo) {
        rest = json
        # Find "key" followed by a colon (a value can never contain an unescaped quote)
        while ((p = index(rest, "\"" key "\"")) > 0) {
            s = substr(rest, p + length(key) + 2)
            if (match(s, /^[ \t\r\n]*:[ \t\r\n]*/)) { s = substr(s, RLENGTH + 1); break }
            rest = s
        }
        if (p == 0) return ""
        if (substr(s, 1, 1) != "\"") {
            if (match(s, /^[0-9]+/)) return substr(s, 1, RLENGTH)
            return ""
        }
        out = ""; n = length(s)
        for (i = 2; i <= n; i++) {
            c = substr(s, i, 1)
            if (c == "\"") break
            if (c == "\\") {
                i++; c = substr(s, i, 1)
                if (c == "u") {
                    cp = hexval(substr(s, i + 1, 4)); i += 4
                    if (cp >= 55296 && cp < 56320 && substr(s, i + 1, 2) == "\\u") {
                        lo = hexval(substr(s, i + 3, 4))
                        if (lo >= 56320 && lo < 57344) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); i += 6 }
                    }
                    c = (cp < 0 || (cp >= 55296 && cp < 57344)) ? "?" : utf8(cp)
                } else if (c == "n" || c == "t" || c == "r" || c == "b" || c == "f") {
                    c = " "
                }
            } else if (c == "\t" || c == "\r" || c == "\n") {
                c = " "
            }
            out = out c
        }
        return out
    }
    { json = json $0 " " }
    END {
        printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n", field("status"), field("filename"), field("title"), field("artist"), field("album"), field("track"), field("duration")
    }' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Get duration in seconds from music_info.txt (ffprobe output) for the given
# file. Prints 0 if unknown, or if the info file describes a different file
# (musicserver may not have finished probing the new track yet).
# ---------------------------------------------------------------------------
info_duration() {
    WANT_FILE="$1" LC_ALL=C awk '
    BEGIN { q = "\047" }
    index($0, " from " q) {
        seen_from = 1
        f = substr($0, index($0, " from " q) + 7)
        sub(q ":[ \t\r]*$", "", f)
        if (f == ENVIRON["WANT_FILE"]) matched = 1
    }
    !dur && /Duration:/ {
        d = $0
        sub(/.*Duration:[ \t]*/, "", d)
        sub(/,.*/, "", d)
        n = split(d, t, ":")
        if (n == 3 && t[1] ~ /^[0-9]+$/ && t[2] ~ /^[0-9]+$/) dur = t[1] * 3600 + t[2] * 60 + int(t[3])
    }
    END {
        if (seen_from && !matched) dur = 0
        print dur + 0
    }' "$MUSIC_INFO" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Write one scrobble entry to the log, adding the header if the log is new,
# empty, or was deleted while the monitor was running.
# ---------------------------------------------------------------------------
log_scrobble() {
    if [ ! -s "$SCROBBLE_LOG" ]; then
        mkdir -p "$(dirname "$SCROBBLE_LOG")"
        printf '#AUDIOSCROBBLER/1.1\n#TZ/UTC\n#CLIENT/TrimUI Music Player Scrobbler\n' >"$SCROBBLE_LOG"
    fi
    # artist<TAB>album<TAB>title<TAB>tracknum<TAB>duration<TAB>L<TAB>timestamp<TAB>mbid
    printf '%s\t%s\t%s\t%s\t%s\tL\t%s\t\n' "$1" "$2" "$3" "$4" "$5" "$6" >>"$SCROBBLE_LOG"
}

# ---------------------------------------------------------------------------
# Tracking state
# ---------------------------------------------------------------------------
reset_track() {
    CUR_KEY=""
    CUR_FILE=""
    CUR_TITLE=""
    CUR_ARTIST=""
    CUR_ALBUM=""
    CUR_TRACKNUM=""
    CUR_DURATION=0
    CUR_START=""
    PLAYED=0
    SCROBBLED=0
}

init_state() {
    reset_track
    LAST_TICK=""
    INACTIVE_SINCE=""
    SHOULD_EXIT=0
}

# Resolve the current track's duration, preferring ffprobe's output for this
# exact file. The JSON field's unit is unconfirmed: values above two hours are
# assumed to be milliseconds.
resolve_duration() {
    [ "$CUR_DURATION" -gt 0 ] && return
    CUR_DURATION=$(info_duration "$CUR_FILE")
    CUR_DURATION="${CUR_DURATION:-0}"
    if [ "$CUR_DURATION" -le 0 ] && [ "${S_DUR:-0}" -gt 0 ]; then
        CUR_DURATION=$S_DUR
        [ "$CUR_DURATION" -gt 7200 ] && CUR_DURATION=$((CUR_DURATION / 1000))
    fi
}

# Log the current play if it has been listened to long enough.
maybe_scrobble() {
    [ "$SCROBBLED" = 1 ] && return
    [ -n "$CUR_TITLE" ] && [ -n "$CUR_ARTIST" ] || return

    if [ "$CUR_DURATION" -gt 0 ]; then
        [ "$CUR_DURATION" -ge 30 ] || return
        threshold=$((CUR_DURATION / 2))
        [ "$threshold" -gt 240 ] && threshold=240
        [ "$PLAYED" -ge "$threshold" ] || return
        duration=$CUR_DURATION
    else
        # Duration unknown: 240s of listening satisfies both rules regardless of
        # length. The played time is the best lower bound for the duration field.
        [ "$PLAYED" -ge 240 ] || return
        duration=$PLAYED
    fi

    SCROBBLED=1
    if [ "$CUR_START" -lt "$MIN_VALID_TIME" ]; then
        echo "skipped (system clock not set): $CUR_ARTIST - $CUR_TITLE"
        return
    fi
    log_scrobble "$CUR_ARTIST" "$CUR_ALBUM" "$CUR_TITLE" "$CUR_TRACKNUM" "$duration" "$CUR_START"
    echo "scrobbled: $CUR_ARTIST - $CUR_TITLE"
}

# ---------------------------------------------------------------------------
# One poll of the music server. $1 is the current unix time.
# ---------------------------------------------------------------------------
tick() {
    now=$1

    if ! server_alive || [ ! -f "$MUSIC_STATUS" ]; then
        # Server stopped: anything that qualified has already been logged
        [ -n "$CUR_KEY" ] && reset_track
        LAST_TICK=""
        if [ -z "$INACTIVE_SINCE" ]; then
            INACTIVE_SINCE=$now
        elif [ $((now - INACTIVE_SINCE)) -ge "$INACTIVITY_TIMEOUT" ]; then
            SHOULD_EXIT=1
        fi
        return
    fi
    INACTIVE_SINCE=""

    IFS="$US" read -r S_STATUS S_FILE S_TITLE S_ARTIST S_ALBUM S_TRACK S_DUR <<EOF
$(parse_status "$MUSIC_STATUS")
EOF
    case "$S_DUR" in '' | *[!0-9]*) S_DUR=0 ;; esac

    # Partially written or unreadable status: keep the current state
    if [ -z "$S_STATUS" ] || { [ -z "$S_FILE" ] && [ -z "$S_TITLE" ]; }; then
        LAST_TICK=""
        return
    fi

    # The file path identifies a play; metadata may be filled in after it appears
    if [ -n "$S_FILE" ]; then key="$S_FILE"; else key="$S_TITLE|$S_ARTIST"; fi
    if [ "$key" != "$CUR_KEY" ]; then
        reset_track
        CUR_KEY=$key
        CUR_FILE=$S_FILE
    fi
    if [ "$SCROBBLED" = 0 ]; then
        CUR_TITLE=$S_TITLE
        CUR_ARTIST=$S_ARTIST
        CUR_ALBUM=$S_ALBUM
        CUR_TRACKNUM=$S_TRACK
    fi

    if [ "$S_STATUS" != "playing" ]; then
        # Paused/stopped: don't count this time as listening
        LAST_TICK=""
        return
    fi

    # Count only time spent playing. A gap much longer than the poll interval
    # means the device slept or the clock jumped, so count one interval.
    delta=0
    if [ -n "$LAST_TICK" ]; then
        delta=$((now - LAST_TICK))
        [ "$delta" -lt 0 ] && delta=0
        [ "$delta" -gt $((POLL_INTERVAL * 2)) ] && delta=$POLL_INTERVAL
    fi
    LAST_TICK=$now
    PLAYED=$((PLAYED + delta))
    [ -z "$CUR_START" ] && CUR_START=$now

    resolve_duration

    # Same file played past its end: it's on repeat, so this is a new play
    if [ "$CUR_DURATION" -gt 0 ] && [ "$PLAYED" -ge $((CUR_DURATION + POLL_INTERVAL * 2)) ]; then
        PLAYED=$((PLAYED - CUR_DURATION))
        CUR_START=$((now - PLAYED))
        SCROBBLED=0
        CUR_TITLE=$S_TITLE
        CUR_ARTIST=$S_ARTIST
        CUR_ALBUM=$S_ALBUM
        CUR_TRACKNUM=$S_TRACK
    fi

    maybe_scrobble
}

# ---------------------------------------------------------------------------
# Single-instance handling
# ---------------------------------------------------------------------------
running_pid() {
    pid=$(cat "$PID_FILE" 2>/dev/null)
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" != "$$" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # Guard against PID reuse by an unrelated process
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q scrobble_monitor || return 1
    echo "$pid"
}

stop_monitor() {
    pid=$(running_pid) || return 0
    kill "$pid" 2>/dev/null
    echo "Stopped scrobble monitor (PID $pid)"
}

cleanup() {
    [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE"
}

main() {
    if [ "$1" = "stop" ]; then
        stop_monitor
        return
    fi

    if pid=$(running_pid); then
        echo "Scrobble monitor already running (PID $pid)"
        return
    fi

    echo $$ >"$PID_FILE"
    trap cleanup EXIT
    # A trapped signal would otherwise resume the loop; exit so EXIT cleanup runs
    trap 'exit 0' INT TERM

    (: >>"$MONITOR_LOG") 2>/dev/null || MONITOR_LOG=/dev/null
    exec >"$MONITOR_LOG" 2>&1
    echo "Scrobble monitor started (PID $$), logging to $SCROBBLE_LOG"

    init_state
    while [ "$SHOULD_EXIT" = 0 ]; do
        tick "$(date +%s)"
        sleep "$POLL_INTERVAL"
    done
    echo "No music server for ${INACTIVITY_TIMEOUT}s, exiting"
}

# Tests source this file with SCROBBLE_MONITOR_LIB=1 to load the functions only
if [ "${SCROBBLE_MONITOR_LIB:-0}" != 1 ]; then
    main "$@"
fi
