; Instalador de VirtualCaster para Windows (Inno Setup 6.3 o superior).
; Lo compila el workflow de GitHub Actions: iscc /DAppVersion=x.y.z VirtualCaster.iss
; Espera la app publicada en ..\publish (dotnet publish ... -o publish).

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{65DE0060-57B5-4BE3-83CB-12F8AED1BCF1}
AppName=VirtualCaster
AppVersion={#AppVersion}
AppPublisher=VirtualCaster
DefaultDirName={autopf}\VirtualCaster
DefaultGroupName=VirtualCaster
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=VirtualCaster-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
WizardStyle=modern

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "..\publish\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\VirtualCaster"; Filename: "{app}\VirtualCaster.exe"
Name: "{autodesktop}\VirtualCaster"; Filename: "{app}\VirtualCaster.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\VirtualCaster.exe"; Description: "{cm:LaunchProgram,VirtualCaster}"; Flags: nowait postinstall skipifsilent
