# trimui-brick-music-player.pak

A TrimUI Brick pak wrapping the built-in Music Player app, with **Last.fm scrobble logging** support.

## Installation

1. Mount your TrimUI Brick SD card.
2. Download the latest release from Github. It will be named `Music.Player.pak.zip`.
3. Copy the zip file to `/Tools/tg5040/Music Player.pak.zip`.
4. Extract the zip in place, then delete the zip file.
5. Confirm that there is a `/Tools/tg5040/Music Player.pak/launch.sh` file on your SD card.
6. Unmount your SD Card and insert it into your TrimUI Brick.

## Scrobble Logging (Last.fm)

This fork adds a background scrobble monitor that tracks your music listening history
in the standard **Audioscrobbler `.scrobbler.log`** format — the same format used by
Rockbox and compatible with many Last.fm submission tools.

### Enabling scrobbling

Scrobbling is **disabled by default**. The setting is stored in the pak's userdata folder,
so it is kept when you update the pak. To enable it:

1. Launch the Music Player once so the settings file is created.
2. Mount your SD card and edit:
   ```
   .userdata/tg5040/Music Player/scrobble_enabled
   ```
3. Change the contents from `0` to `1`
4. Save and eject

To disable again, change back to `0`. The background monitor is stopped the next time you open the player.

> **Upgrading from 0.4.x:** earlier versions kept this setting inside the pak folder
> (`Tools/tg5040/Music Player.pak/scrobble_enabled`), which was reset on every update.
> Set it in the `.userdata` location above instead.

### How it works

- When scrobbling is enabled, a lightweight background daemon (`scrobble_monitor.sh`)
  starts automatically and **keeps running even after you exit the player UI** — so plays are
  tracked while music plays in the background during gaming. Only one instance runs at a time;
  reopening the player doesn't interrupt it. It exits on its own after 10 minutes without a
  running music server.
- It reads the TrimUI `musicserver`'s JSON status file (`/tmp/trimui_music/status`) which contains
  the current track's title, artist, album, track number, and filename. Duration is read from
  `/tmp/trimui_music/music_info.txt` (ffprobe output written by musicserver).
- As soon as a track qualifies (track is ≥ 30 seconds long **and** at least `min(duration/2, 4 minutes)`
  has been played — per Last.fm's official scrobbling spec), an entry is appended to the scrobble log.
  Plays are logged immediately rather than when the track ends, so they aren't lost if the device
  powers off mid-song.
- Only time spent actually playing counts: paused time and time the device is asleep are not
  counted towards the threshold.
- Tracks on repeat are scrobbled once per play.
- The monitor's own diagnostic log is written to `.userdata/tg5040/logs/Music Player Scrobbler.txt`.

### Scrobble log location

```
/mnt/SDCARD/.scrobbler.log
```

The file is hidden (`.` prefix) but will be at the **root of your SD card** — easy to find when you mount the card on your computer.

### Log format

The `.scrobbler.log` file follows the Audioscrobbler 1.1 spec:

```
#AUDIOSCROBBLER/1.1
#TZ/UTC
#CLIENT/TrimUI Music Player Scrobbler
artist	album	title	tracknum	duration	L	unix_timestamp	(empty mbid)
```

Example entry:
```
'Haunted' George	Bone Hauler	This Is A Test	1	91	L	1708560000	
```

### Submitting to Last.fm

Copy `.scrobbler.log` from your SD card to your computer and submit using any of these tools:

| Tool | Type | URL |
|------|------|-----|
| Open Scrobbler | Web | https://openscrobbler.com |
| Universal Scrobbler | Web | https://universalscrobbler.com |
| Web Scrobbler | Browser extension | https://web-scrobbler.com |
| beets | CLI | `beets lastimport` |
| lastfmsubmitd | CLI | Reads `.scrobbler.log` natively |

> **Tip:** The log file accumulates entries across sessions. After submitting, you can
> delete or archive the file — a fresh header will be written on the next track play.

### Known limitations

- **Restarting a track:** Going back to the start of the same song (outside repeat mode) isn't
  detected as a new play, since the file and metadata don't change.
- **Duration unknown:** If the track's duration can't be determined, it is scrobbled after
  4 minutes of listening (which satisfies Last.fm's rules for any track length), with the
  listened time recorded as its duration. Shorter plays of such tracks aren't scrobbled.
- **Clock not set:** Plays are not logged while the system clock is unset (before 2020), since
  their timestamps would be meaningless to Last.fm.
- **Tracks without tags:** Tracks with no title or artist metadata are not scrobbled.

### Disabling scrobbling

Edit `.userdata/tg5040/Music Player/scrobble_enabled` on your SD card and change the contents to `0`.
The music player will continue to work normally — the scrobble monitor simply won't start.

## Development

```sh
make lint           # shellcheck
make test           # replay tests with the default sh (TEST_SHELLS="dash bash" for more)
make test-busybox   # replay tests with BusyBox sh and applets, as on the device
```

The tests in `tests/` feed sequences of musicserver status snapshots through the monitor with a
fake clock and check the resulting `.scrobbler.log`.
