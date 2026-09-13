#ifndef ReleaseDir
  #error ReleaseDir is required
#endif
#ifndef SupportDir
  #error SupportDir is required
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
[Setup]
AppId={{C263DA8E-E125-44CA-A90D-1D9BE02EF926}
AppName=SocketAgent Desktop
AppVersion={#AppVersion}
AppPublisher=Rubano Enterprises, LLC
AppPublisherURL=https://github.com/Yllib/socketagent
DefaultDirName={localappdata}\SocketAgentDesktop
DefaultGroupName=SocketAgent Desktop
UsePreviousGroup=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableDirPage=no
DisableProgramGroupPage=yes
DisableWelcomePage=no
WizardStyle=modern
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\socketagent.exe
OutputDir={#ReleaseDir}\..\..\..\packages
OutputBaseFilename=SocketAgent-Desktop-Setup
Compression=lzma2
SolidCompression=yes
CloseApplications=no
RestartApplications=no
UninstallDisplayName=SocketAgent Desktop

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "desktop-setup.ps1"; Flags: dontcopy
Source: "server-discovery.ps1"; Flags: dontcopy
Source: "{#SupportDir}\server-bootstrap.ps1"; Flags: dontcopy
Source: "{#SupportDir}\server-support.zip"; Flags: dontcopy
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Excludes: "install-windows-app.ps1,install-windows-app.cmd,README.txt,*.lib,*.exp"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "desktop-setup.ps1"; DestDir: "{app}\.installer"; Flags: ignoreversion

[Icons]
Name: "{group}\SocketAgent Desktop"; Filename: "{app}\socketagent.exe"
Name: "{autodesktop}\SocketAgent Desktop"; Filename: "{app}\socketagent.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\socketagent.exe"; Description: "Open SocketAgent Desktop"; Flags: nowait postinstall skipifsilent

[Code]
var
  ServerPage: TWizardPage;
  StatusText, FolderLabel, Explanation: TNewStaticText;
  ServerChoice: TNewCheckBox;
  FolderEdit: TNewEdit;
  BrowseButton, RefreshButton: TNewButton;
  Progress: TOutputMarqueeProgressWizardPage;
  ServerStatus, ServerDirectory, ServerTask, LastError, ProgressTitle: String;
  ServerReady, Detecting: Boolean;

function Quote(const Value: String): String;
begin
  Result := '"' + Value + '"';
end;

function PowerShell: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

procedure OnSetupOutput(const S: String; const Error, FirstLine: Boolean);
begin
  if Pos('PHASE:', S) = 1 then
    Progress.SetText(ProgressTitle, Copy(S, 7, Length(S)))
  else if Pos('ERROR:', S) = 1 then
    LastError := Copy(S, 7, Length(S));
end;

function RunHelper(const Action, Directory: String): Boolean;
var
  Code: Integer;
  Params: String;
begin
  LastError := '';
  Params := '-NoProfile -ExecutionPolicy Bypass -File ' + Quote(ExpandConstant('{tmp}\desktop-setup.ps1')) +
    ' -Action ' + Action + ' -ResultFile ' + Quote(ExpandConstant('{tmp}\server-state.ini')) +
    ' -DesktopDirectory ' + Quote(WizardDirValue);
  if Directory <> '' then Params := Params + ' -InstallDirectory ' + Quote(Directory);
  Result := ExecAndLogOutput(PowerShell, Params, '', SW_HIDE, ewWaitUntilTerminated, Code, @OnSetupOutput);
  Result := Result and (Code = 0);
  if not Result and (LastError = '') then LastError := 'Server setup did not finish. You can retry or continue without a local server.';
end;

procedure ChoiceChanged(Sender: TObject);
begin
  FolderEdit.Enabled := ServerChoice.Checked and (ServerStatus = 'missing');
  BrowseButton.Enabled := FolderEdit.Enabled;
end;

procedure DetectServer;
var
  PreviousStatus: String;
  PreviousChoice, OK: Boolean;
begin
  if Detecting then Exit;
  Detecting := True;
  try
  PreviousStatus := ServerStatus;
  PreviousChoice := ServerChoice.Checked;
  ProgressTitle := 'Checking this computer';
  Progress.SetText(ProgressTitle, 'Looking for a SocketAgent server installed for your Windows account...');
  Progress.Show;
  Progress.Animate;
  try
    OK := RunHelper('Detect', '');
  finally
    Progress.Hide;
  end;
  ServerStatus := 'unavailable';
  ServerDirectory := '';
  ServerTask := '';
  if OK then begin
    ServerStatus := GetIniString('server', 'status', 'unavailable', ExpandConstant('{tmp}\server-state.ini'));
    ServerDirectory := GetIniString('server', 'directory', '', ExpandConstant('{tmp}\server-state.ini'));
    ServerTask := GetIniString('server', 'task', '', ExpandConstant('{tmp}\server-state.ini'));
  end;
  ServerChoice.Visible := (ServerStatus = 'missing') or ((ServerStatus = 'stopped') and (ServerTask <> ''));
  ServerChoice.Checked := False;
  if ServerStatus = 'running' then
    StatusText.Caption := 'We found a running SocketAgent server on this computer.' + #13#10#13#10 + ServerDirectory + #13#10#13#10 + 'The app will link to it automatically when you open it.'
  else if ServerStatus = 'stopped' then begin
    StatusText.Caption := 'We found a SocketAgent server, but it is not responding.' + #13#10#13#10 + ServerDirectory;
    ServerChoice.Caption := 'Start the existing server and link to it automatically';
    if ServerTask = '' then StatusText.Caption := StatusText.Caption + #13#10#13#10 + 'Start it manually when you are ready to connect.';
  end else if ServerStatus = 'missing' then begin
    StatusText.Caption := 'You do not have a SocketAgent server installed on this computer. Would you like to install it as well?';
    ServerChoice.Caption := 'Install the free SocketAgent server on this computer';
  end else
    StatusText.Caption := 'We could not verify a working local server.' + #13#10#13#10 + ServerDirectory + #13#10#13#10 + 'You can finish installing the app and check the server later.';
  FolderLabel.Visible := ServerStatus = 'missing';
  FolderEdit.Visible := FolderLabel.Visible;
  BrowseButton.Visible := FolderLabel.Visible;
  if PreviousStatus = ServerStatus then ServerChoice.Checked := PreviousChoice;
  ChoiceChanged(nil);
  finally
    Detecting := False;
  end;
end;

procedure RefreshClicked(Sender: TObject);
begin
  DetectServer;
end;

procedure BrowseClicked(Sender: TObject);
var
  Directory: String;
begin
  Directory := FolderEdit.Text;
  if BrowseForFolder('Choose the server folder', Directory, True) then FolderEdit.Text := Directory;
end;

procedure InitializeWizard;
begin
  ExtractTemporaryFile('desktop-setup.ps1');
  ExtractTemporaryFile('server-discovery.ps1');
  ExtractTemporaryFile('server-bootstrap.ps1');
  ExtractTemporaryFile('server-support.zip');
  ServerPage := CreateCustomPage(wpSelectDir, 'Server on this computer', 'Choose whether to connect to a local server.');
  StatusText := TNewStaticText.Create(ServerPage);
  StatusText.Parent := ServerPage.Surface;
  StatusText.SetBounds(0, 0, ServerPage.SurfaceWidth, ScaleY(112));
  StatusText.AutoSize := False;
  StatusText.WordWrap := True;
  ServerChoice := TNewCheckBox.Create(ServerPage);
  ServerChoice.Parent := ServerPage.Surface;
  ServerChoice.SetBounds(0, ScaleY(120), ServerPage.SurfaceWidth, ScaleY(24));
  ServerChoice.OnClick := @ChoiceChanged;
  FolderLabel := TNewStaticText.Create(ServerPage);
  FolderLabel.Parent := ServerPage.Surface;
  FolderLabel.SetBounds(0, ScaleY(157), ScaleX(200), ScaleY(17));
  FolderLabel.Caption := 'Server installation folder';
  FolderEdit := TNewEdit.Create(ServerPage);
  FolderEdit.Parent := ServerPage.Surface;
  FolderEdit.SetBounds(0, ScaleY(179), ServerPage.SurfaceWidth - ScaleX(86), ScaleY(23));
  FolderEdit.Text := ExpandConstant('{param:SERVERDIR|}');
  if FolderEdit.Text = '' then FolderEdit.Text := GetEnv('USERPROFILE') + '\socketagent';
  BrowseButton := TNewButton.Create(ServerPage);
  BrowseButton.Parent := ServerPage.Surface;
  BrowseButton.SetBounds(ServerPage.SurfaceWidth - ScaleX(80), ScaleY(178), ScaleX(80), ScaleY(25));
  BrowseButton.Caption := 'Browse...';
  BrowseButton.OnClick := @BrowseClicked;
  Explanation := TNewStaticText.Create(ServerPage);
  Explanation.Parent := ServerPage.Surface;
  Explanation.SetBounds(0, ScaleY(222), ServerPage.SurfaceWidth - ScaleX(90), ScaleY(60));
  Explanation.AutoSize := False;
  Explanation.WordWrap := True;
  Explanation.Caption := 'A local server is optional. You can add other computers via their pairing codes without installing a server on this computer.';
  RefreshButton := TNewButton.Create(ServerPage);
  RefreshButton.Parent := ServerPage.Surface;
  RefreshButton.SetBounds(ServerPage.SurfaceWidth - ScaleX(80), ScaleY(223), ScaleX(80), ScaleY(25));
  RefreshButton.Caption := 'Check again';
  RefreshButton.OnClick := @RefreshClicked;
  Progress := CreateOutputMarqueeProgressPage('Local server', 'Setting up your connection');
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = ServerPage.ID then DetectServer;
  if CurPageID = wpFinished then begin
    if ServerReady then
      WizardForm.FinishedLabel.Caption := 'SocketAgent Desktop is installed. Your local server is ready and will be linked automatically when you open the app. You can add other computers at any time.'
    else
      WizardForm.FinishedLabel.Caption := 'SocketAgent Desktop is installed. Open the app to add a computer or import its pairing QR code. You can set up a local server later.';
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  DesktopPath, ServerPath: String;
begin
  Result := True;
  if (CurPageID = ServerPage.ID) and ServerChoice.Checked and (ServerStatus = 'missing') then begin
    DesktopPath := AddBackslash(Lowercase(ExpandFileName(WizardDirValue)));
    ServerPath := AddBackslash(Lowercase(ExpandFileName(FolderEdit.Text)));
    if (Trim(FolderEdit.Text) = '') or (Pos(DesktopPath, ServerPath) = 1) or (Pos(ServerPath, DesktopPath) = 1) then begin
      MsgBox('Choose separate folders for the desktop app and server.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not RunHelper('Quit', '') then Result := LastError;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Action, Requested: String;
  OK: Boolean;
  Response: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  // Silent installation never adds a server unless explicitly requested.
  if WizardSilent then begin
    DetectServer;
    Requested := Lowercase(ExpandConstant('{param:SERVER|none}'));
    ServerChoice.Checked := ((Requested = 'install') and (ServerStatus = 'missing')) or
      ((Requested = 'start') and (ServerStatus = 'stopped'));
  end;
  Action := '';
  if ServerStatus = 'running' then Action := 'Link'
  else if ServerChoice.Checked then begin
    if ServerStatus = 'missing' then Action := 'Install'
    else if ServerStatus = 'stopped' then Action := 'Start';
  end;
  if Action <> '' then begin
    repeat
      ProgressTitle := 'Connecting your local server';
      if Action = 'Install' then ProgressTitle := 'Installing the local server';
      Progress.SetText(ProgressTitle, 'This can take several minutes. Please leave setup open.');
      Progress.Show;
  Progress.Animate;
      try
        OK := RunHelper(Action, FolderEdit.Text);
      finally
        Progress.Hide;
      end;
      ServerReady := OK;
      Response := IDCANCEL;
      if not OK and not WizardSilent then
        Response := TaskDialogMsgBox('The desktop app is installed', LastError + #13#10#13#10 + 'Retry server setup, or continue and connect to a computer later.', mbError, MB_RETRYCANCEL, ['Retry', 'Continue without server'], 0);
    until OK or (Response <> IDRETRY);
  end;

end;

function InitializeUninstall: Boolean;
var
  Code: Integer;
begin
  Result := Exec(PowerShell, '-NoProfile -ExecutionPolicy Bypass -File ' + Quote(ExpandConstant('{app}\.installer\desktop-setup.ps1')) + ' -Action Quit -DesktopDirectory ' + Quote(ExpandConstant('{app}')), '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := Result and (Code = 0);
  if not Result and not UninstallSilent then MsgBox('Quit SocketAgent Desktop from its tray menu, then run uninstall again.', mbError, MB_OK);
end;
