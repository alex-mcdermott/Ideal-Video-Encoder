; Ideal Video Encoder - Windows installer (Inno Setup 6)
; SPDX-License-Identifier: GPL-3.0-or-later
; Per-user install (no admin). Installs FFmpeg, ExifTool and mpv.net if missing, via Install-Prerequisites.ps1.
; Build with installer\build-installer.ps1 (passes /DAppVersion=x.y.z).

#define AppName "Ideal Video Encoder"
#define AppExe "Ideal-Video-Encoder.exe"
#define RepoUrl "https://github.com/alex-mcdermott/Ideal-Video-Encoder"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{C960E158-C703-4297-97D6-ED9E646D1F36}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Alex McDermott
AppPublisherURL={#RepoUrl}
AppSupportURL={#RepoUrl}/issues
AppUpdatesURL={#RepoUrl}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename=Ideal-Video-Encoder-Setup-{#AppVersion}
SetupIconFile=..\assets\app.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
CloseApplications=yes

[Tasks]
Name: "prereqs"; Description: "Install FFmpeg, ExifTool and mpv.net if they are missing (required)"; GroupDescription: "Prerequisites (downloaded from their official sources):"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\dist\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "Install-Prerequisites.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\app.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autoprograms}\{#AppName} - Install or repair prerequisites"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -NoExit -File ""{app}\Install-Prerequisites.ps1"""; IconFilename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; Launch through Explorer so the app sees the PATH updated by the prerequisite install
Filename: "{win}\explorer.exe"; Parameters: """{app}\{#AppExe}"""; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\prerequisites.log"

[Code]
procedure InstallPrerequisites;
var
  ResultCode: Integer;
  Params, LogFile: String;
begin
  LogFile := ExpandConstant('{app}\prerequisites.log');
  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\Install-Prerequisites.ps1') + '" -LogPath "' + LogFile + '"';
  WizardForm.StatusLabel.Caption := 'Checking and installing FFmpeg, ExifTool and mpv.net. Downloads can take a few minutes...';
  WizardForm.ProgressGauge.Style := npbstMarquee;
  try
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      SuppressibleMsgBox('Some prerequisites could not be installed automatically.' + #13#10#13#10 +
        'Details are in:' + #13#10 + LogFile + #13#10#13#10 +
        'You can retry later from the Start menu ("' + '{#AppName}' + ' - Install or repair prerequisites"), or install FFmpeg (full build), ExifTool and mpv.net yourself.',
        mbError, MB_OK, IDOK);
  finally
    WizardForm.ProgressGauge.Style := npbstNormal;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('prereqs') then
    InstallPrerequisites;
end;
