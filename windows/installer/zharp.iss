; Zharp installer (Inno Setup 6).
; Build: publish first, then compile this script:
;   dotnet publish src/Zharp.App/Zharp.App.csproj -c Release -r win-x64 --self-contained true -p:BaseOutputPath=bin\pub\
;   ISCC.exe installer\zharp.iss
; Output: installer\Output\ZharpSetup-<version>.exe

#define MyAppName "Zharp"
#define MyAppVersion "0.15.0" /* x-release-please-version */
#define MyAppPublisher "Zharp"
#define MyAppExeName "Zharp.exe"
#define PublishDir "..\src\Zharp.App\bin\pub\Release\net10.0-windows10.0.22621.0\win-x64\publish"

[Setup]
; Never change AppId between versions - it is how upgrades find the install.
AppId={{C7A9D1E4-4B2F-4A63-9C0D-2E8F5B7A1D36}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://zharp.app
AppSupportURL=https://zharp.app
AppUpdatesURL=https://zharp.app
; Listed as plain "Zharp" rather than "Zharp version x.y.z": the version has
; its own column, and package managers match on this name.
UninstallDisplayName={#MyAppName}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
; Per-user install by default (no admin prompt); the dialog allows all-users.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=Output
OutputBaseFilename=ZharpSetup-{#MyAppVersion}
SetupIconFile=..\src\Zharp.App\Assets\zharp.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Detect a running Zharp during upgrades and offer to close it.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

; Settings in %LOCALAPPDATA%\Zharp are deliberately kept on uninstall.

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
; The in-app updater runs this setup silently with /RELAUNCH=1 so Zharp
; comes back up after the upgrade (postinstall entries are skipped when silent).
Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: ShouldRelaunch

[Code]
function ShouldRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;
