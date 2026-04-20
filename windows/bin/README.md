# Bundled binaries

Place `ffmpeg.exe` in this folder to have it automatically bundled into the
built app (copied next to `home_streaming.exe` in the Release folder and
picked up by the Inno Setup installer).

HomeStreaming uses FFmpeg to pre-generate the small scrubbing-preview
thumbnails that appear when hovering the seek bar. Without it, video playback
still works — only the hover previews are missing and a banner is shown on
the home screen.

## How to obtain ffmpeg.exe (Windows, LGPL)

1. Go to https://www.gyan.dev/ffmpeg/builds/
2. Download the **"release essentials"** build (it is an LGPL build, safe to
   redistribute alongside a closed-source app without GPL'ing your code).
3. Extract the archive, open the `bin/` folder inside it.
4. Copy **only** `ffmpeg.exe` into this folder (`windows/bin/ffmpeg.exe`).
   You do not need `ffplay.exe` or `ffprobe.exe`.

## License note

The gyan.dev "essentials" build is LGPL-3.0. When distributing an installer
that includes `ffmpeg.exe`, include a copy of the LGPL license text and a
notice that the FFmpeg binary is provided under LGPL-3.0 and was obtained
unmodified from https://www.gyan.dev/ffmpeg/builds/. Do **not** use the
"full" build — it is GPL-licensed and would require you to release the
full source of HomeStreaming under GPL if redistributed.

## Git

`ffmpeg.exe` is intentionally not committed (it's ~80 MB). Add it locally.
