; Inno Setup Script for Comunifi
; https://jrsoftware.org/isinfo.php

#define MyAppName "Comunifi"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Comunifi"
#define MyAppURL "https://github.com/comunifi/comunifi"
#define MyAppExeName "comunifi.exe"

[Setup]
; NOTE: The value of AppId uniquely identifies this application.
; Do not use the same AppId value in installers for other applications.
AppId={{A8F3B2C1-D4E5-6F78-9A0B-C1D2E3F4A5B6}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
; Output settings
OutputDir=..\..\dist
OutputBaseFilename=comunifi-{#MyAppVersion}-windows-setup
; Compression
Compression=lzma2/ultra64
SolidCompression=yes
; Windows version requirements
MinVersion=10.0
; Privileges - install for current user by default
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; Visual settings
WizardStyle=modern
; Uninstaller
UninstallDisplayIcon={app}\{#MyAppExeName}
; Code signing (uncomment when you have a certificate)
; SignTool=signtool sign /f "path\to\certificate.pfx" /p "password" /t http://timestamp.digicert.com $f

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Main application files from Flutter build
Source: "..\..\build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
Source: "..\..\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Clean up any user data on uninstall (optional - uncomment if desired)
; Type: filesandordirs; Name: "{localappdata}\{#MyAppName}"

