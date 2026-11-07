; Inno Setup script. Build with:
;   iscc /DAppVersion=1.0.0 /DSourceDir=build\windows\x64\runner\Release packaging\windows\gita.iss
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{B6C7C6B2-4D53-4B0A-9C6E-6A1F0C2D9E11}
AppName=Gita
AppVersion={#AppVersion}
AppPublisher=naseebnaushad
AppPublisherURL=https://github.com/naseebnaushad/gita
DefaultDirName={autopf}\Gita
DefaultGroupName=Gita
UninstallDisplayIcon={app}\gita.exe
OutputDir=..\..\dist
OutputBaseFilename=gita-windows-x64-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "addtopath"; Description: "Add the gita command to PATH"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Gita"; Filename: "{app}\gita.exe"
Name: "{autodesktop}\Gita"; Filename: "{app}\gita.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; \
  ValueData: "{olddata};{app}\cli\bin"; Tasks: addtopath; Check: NeedsPath(ExpandConstant('{app}\cli\bin'))

[Run]
Filename: "{app}\gita.exe"; Description: "Start Gita"; Flags: nowait postinstall skipifsilent

[Code]
function NeedsPath(Param: string): Boolean;
var Path: string;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then begin
    Result := True; exit;
  end;
  Result := Pos(';' + Lowercase(Param) + ';', ';' + Lowercase(Path) + ';') = 0;
end;
