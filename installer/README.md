# BeefburgerStreaming - Build & Installer

End-to-end steps to produce a distributable Windows installer.

## 1. Bundle FFmpeg (one-time)

BeefburgerStreaming uses FFmpeg for seek-bar preview thumbnails. To include it in
the installer so end users don't need to install anything:

1. Download the **LGPL "release essentials"** build from
   https://www.gyan.dev/ffmpeg/builds/
2. Extract it, and copy `bin/ffmpeg.exe` into `windows/bin/ffmpeg.exe` of this
   repo.

See `windows/bin/README.md` for details and licensing notes.

If you skip this step the app still builds and runs — users without FFmpeg
on their system just won't see hover thumbnails.

## 2. Build the Flutter Windows app

```powershell
flutter pub get
flutter build windows --release
```

Output lands in `build\windows\x64\runner\Release\`. Verify `ffmpeg.exe` is
next to `BeefburgerStreaming.exe` there (the CMake rule in `windows/CMakeLists.txt`
copies it automatically if present in `windows/bin/`).

## 3. Build the installer

Install Inno Setup 6 from https://jrsoftware.org/isinfo.php, then:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\beefburger_streaming.iss
```

The setup executable is written to `installer\Output\BeefburgerStreamingSetup-<ver>.exe`.

## 4. Distribute

Ship the single `.exe` from `installer\Output\`. End users double-click it,
go through the wizard, and launch BeefburgerStreaming from the Start menu.

## Updating the version

Edit `MyAppVersion` near the top of `beefburger_streaming.iss` before building.
