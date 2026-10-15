# vzz

A sleep-timer for video. Plays a video file for a fixed duration and then
stops, with optional fade-to-silence, fade-to-black, and power-off when it's
done. Works on macOS and Linux.

## Technology

Use mpv.io as the video player

Use Chicken LISP as the language (https://www.call-cc.org/) targeting MacOs and Linux.

## Build

Requires [mpv](https://mpv.io) and the [CHICKEN Scheme](https://www.call-cc.org/) compiler (`csc`).

```sh
# macOS
brew install mpv chicken

make
```

This builds `src/vzz.scm` into `bin/vzz`. `vzz` controls mpv over its JSON
IPC socket (`--input-ipc-server`) to drive the fades and the final stop,
using a small FFI wrapper around POSIX Unix domain sockets (there's no
Unix-socket egg for this CHICKEN version), so there's nothing else to
install or keep track of.

Run the smoke tests (requires ffmpeg, to generate a short test clip):

```sh
make test
```

## usage

```sh
bin/vzz VIDEO_FILE --duration MINUTES [options]
```

Play a video for 45 minutes, then stop:

```sh
bin/vzz movie.mp4 --duration 45
```

Fade the volume to silence starting at 40 minutes, and dim the picture to
black starting at 42 minutes, both reaching zero exactly at the 45-minute
stop:

```sh
bin/vzz movie.mp4 --duration 45 --fade-audio-at 40 --fade-video-at 42
```

Power the machine off as soon as playback stops naturally (not if you
interrupt it with Ctrl+C):

```sh
bin/vzz movie.mp4 --duration 45 --shutdown
```

`--shutdown` runs `sudo shutdown -h now`, which will prompt for your sudo
password unless you've configured passwordless sudo for `shutdown`.

Other flags:

- `--fullscreen` — play mpv fullscreen instead of windowed.

If the video is shorter than `--duration`, it loops until the requested
duration has elapsed.
