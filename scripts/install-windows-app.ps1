$ErrorActionPreference = 'Stop'
$destination = Join-Path $env:LOCALAPPDATA 'SocketAgentDesktop'
if (!(Test-Path "$PSScriptRoot/socketagent.exe")) { throw 'Extract the complete ZIP before running this installer.' }
# Tray builds stay alive after their window closes. Ask that exact installed
# client to quit before replacing files; never terminate SocketAgent servers.
$installedExe = Join-Path $destination 'socketagent.exe'
$running = @(Get-Process socketagent -ErrorAction SilentlyContinue | Where-Object Path -eq $installedExe)
if ($running.Count) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SocketAgentInstallerWindow {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessage(string name);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
}
'@
  $window = [SocketAgentInstallerWindow]::FindWindow('SOCKETAGENT_DESKTOP_WINDOW', $null)
  [uint32]$windowPid = 0
  if ($window -ne [IntPtr]::Zero) {
    [SocketAgentInstallerWindow]::GetWindowThreadProcessId($window, [ref]$windowPid) | Out-Null
  }
  foreach ($process in $running) {
    if ($windowPid -eq $process.Id) {
      [SocketAgentInstallerWindow]::PostMessage($window, [SocketAgentInstallerWindow]::RegisterWindowMessage('SocketAgent.Desktop.Quit.v1'), [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    } else {
      if (!$process.CloseMainWindow()) { throw 'Quit the running SocketAgent desktop app, then retry installation.' }
    }
    if (!$process.WaitForExit(10000)) { throw 'SocketAgent did not exit; application files were not replaced.' }
  }
}
New-Item -ItemType Directory -Force $destination | Out-Null
Copy-Item "$PSScriptRoot/*" $destination -Recurse -Force
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
  $shortcut = $shell.CreateShortcut((Join-Path $folder 'SocketAgent Desktop.lnk'))
  $shortcut.TargetPath = Join-Path $destination 'socketagent.exe'
  $shortcut.WorkingDirectory = $destination
  $shortcut.Save()
}
Start-Process (Join-Path $destination 'socketagent.exe')
