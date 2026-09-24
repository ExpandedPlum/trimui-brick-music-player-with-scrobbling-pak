#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"

# Redirect stdout+stderr to log first, THEN enable trace so all output is captured
rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >"$LOGS_PATH/$PAK_NAME.txt" 2>&1
set -x

echo "$0" "$@"
cd "$PAK_DIR" || exit 1
PAK_DIR="$(pwd)"
mkdir -p "$USERDATA_PATH/$PAK_NAME"

cleanup() {
    rm -f /tmp/stay_awake
    # Intentionally do NOT kill musicserver or remove /tmp/stay_alive here —
    # musicserver must keep running so background music continues to the next song.
}

# The scrobble setting lives in the userdata folder so it survives pak updates.
# It is seeded from the default that ships with the pak on first launch.
scrobble_enabled() {
    SCROBBLE_CONFIG="$USERDATA_PATH/$PAK_NAME/scrobble_enabled"
    if [ ! -f "$SCROBBLE_CONFIG" ]; then
        cp "$PAK_DIR/scrobble_enabled" "$SCROBBLE_CONFIG" 2>/dev/null || echo 0 >"$SCROBBLE_CONFIG"
    fi
    SCROBBLE_ON=$(tr -dc '01' <"$SCROBBLE_CONFIG" 2>/dev/null | head -c1)
    [ "${SCROBBLE_ON:-0}" = "1" ]
}

start_scrobble_monitor() {
    # Start the scrobble monitor as a background daemon; it exits on its own if an
    # instance is already running, so the current track's progress is kept.
    # Trap '' HUP makes it immune to SIGHUP when the pak exits (nohup/setsid aren't
    # available on BusyBox).
    [ -x "$PAK_DIR/scrobble_monitor.sh" ] || chmod +x "$PAK_DIR/scrobble_monitor.sh"
    SCROBBLE_MONITOR_LOG="$LOGS_PATH/$PAK_NAME Scrobbler.txt"
    export SCROBBLE_MONITOR_LOG
    (trap '' HUP; exec "$PAK_DIR/scrobble_monitor.sh") </dev/null &
}

main() {
    echo "1" >/tmp/stay_awake
    trap "cleanup" EXIT INT TERM HUP QUIT

    if scrobble_enabled; then
        start_scrobble_monitor
    else
        echo "Scrobbling disabled (set $SCROBBLE_CONFIG to 1 to enable)"
        sh "$PAK_DIR/scrobble_monitor.sh" stop
    fi

    # Ensure /usr/trimui/lib is in LD_LIBRARY_PATH — musicserver needs libSDL-1.2.so.0 from there.
    export LD_LIBRARY_PATH="/usr/trimui/lib:${LD_LIBRARY_PATH:-}"

    # The musicplayer UI requires musicserver (the audio playback daemon) to be running.
    # The system's home screen normally starts musicserver before opening the music player,
    # but in pak context it's not running — so we start it ourselves.
    if ! pidof musicserver >/dev/null 2>&1; then
        /usr/trimui/bin/musicserver </dev/null >/dev/null 2>&1 &
        MUSICSERVER_PID=$!
        echo "Started musicserver (PID $MUSICSERVER_PID)"
        sleep 1
    fi

    # Change into musicplayer's own directory so relative paths inside its script resolve correctly.
    cd /usr/trimui/apps/musicplayer || exit 1

    # Run musicplayer directly instead of its launch.sh — that script removes
    # /tmp/stay_alive on exit which tells musicserver to stop, killing background playback.
    # We keep stay_alive so musicserver continues advancing through the queue.
    echo 1 > /tmp/stay_alive
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$(pwd)"
    export LD_LIBRARY_PATH
    ./musicplayer
}

main "$@"
