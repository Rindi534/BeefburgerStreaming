; Inno Setup script for BeefburgerStreaming
; Build with: ISCC.exe installer\beefburger_streaming.iss
; (Inno Setup 6+ required: https://jrsoftware.org/isinfo.php)
;
; Prerequisite: run `flutter build windows --release` first so that
; build\windows\x64\runner\Release\ contains the built app (incl. bundled
; ffmpeg.exe if you put one in windows/bin/).

#define MyAppName "BeefburgerStreaming"
#define MyAppVersion "1.5.37"
#define MyAppPublisher "Jakob"
#define MyAppExeName "BeefburgerStreaming.exe"
#define MyBuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{E4B2A3C6-2C5D-4E7B-9F8E-HOMESTREAM0001}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=.\Output
OutputBaseFilename=BeefburgerStreamingSetup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Copy the entire Release folder (includes ffmpeg.exe if bundled via windows/bin/)
Source: "{#MyBuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Bundle the user-facing docs next to the exe so they're reachable via
; the Start-menu "Anleitung" shortcut and by browsing the install dir.
Source: "..\ANLEITUNG.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\ORDNERSTRUKTUR.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
