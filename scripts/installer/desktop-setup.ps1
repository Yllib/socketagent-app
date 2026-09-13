#Requires -Version 5.1
param(
    [ValidateSet('Detect', 'Link', 'Start', 'Install', 'Quit')][string]$Action = 'Detect',
    [string]$ResultFile,
    [string]$InstallDirectory,
    [string]$DesktopDirectory
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Result($State) {
    if ($ResultFile) {
        $text = "[server]`r`nstatus=$($State.Status)`r`ndirectory=$($State.Directory)`r`nport=$($State.Port)`r`ntask=$($State.TaskName)`r`n"
        [IO.File]::WriteAllText($ResultFile, $text, [Text.Encoding]::Unicode)
    }
}

function Stop-Desktop([string]$Directory) {
    $exe = Join-Path $Directory 'socketagent.exe'
    $processes = @(Get-Process socketagent -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $exe })
    if (!$processes.Count) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SetupWindow {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c,string t);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr w,out uint p);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessage(string n);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr w,uint m,IntPtr a,IntPtr b);
}
'@
    # PowerShell coerces $null to an empty string for .NET string arguments.
    # Pass a true null so this matches by class regardless of the window title.
    $window = [SetupWindow]::FindWindow('SOCKETAGENT_DESKTOP_WINDOW', [NullString]::Value)
    [uint32]$windowPid = 0
    [SetupWindow]::GetWindowThreadProcessId($window, [ref]$windowPid) | Out-Null
    foreach ($process in $processes) {
        if ($window -eq [IntPtr]::Zero -or $windowPid -ne $process.Id) { throw 'Quit SocketAgent from its tray menu, then retry.' }
        [SetupWindow]::PostMessage($window, [SetupWindow]::RegisterWindowMessage('SocketAgent.Desktop.Quit.v1'), [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        if (!$process.WaitForExit(12000)) { throw 'SocketAgent did not exit. Quit it from its tray menu, then retry.' }
    }
}

try {
    if ($Action -eq 'Quit') {
        Stop-Desktop $DesktopDirectory
        # Retire the preview's old shortcut names only when they target this app.
        $shell = New-Object -ComObject WScript.Shell
        $programs = [Environment]::GetFolderPath('Programs')
        foreach ($link in @(
            (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SocketAgent.lnk'),
            (Join-Path $programs 'SocketAgent.lnk'),
            (Join-Path $programs 'SocketAgent/SocketAgent.lnk')
        )) {
            if ((Test-Path -LiteralPath $link) -and $shell.CreateShortcut($link).TargetPath -ieq (Join-Path $DesktopDirectory 'socketagent.exe')) {
                Remove-Item -LiteralPath $link
            }
        }
        exit 0
    }
    . (Join-Path $PSScriptRoot 'server-discovery.ps1')
    $state = Find-LocalServer
    if ($Action -eq 'Detect') { Write-Result $state; exit 0 }
    if ($Action -eq 'Install') {
        # Recheck after the wizard choice, so concurrent setup cannot cause a second server.
        if ($state.Status -ne 'missing' -and (!$InstallDirectory -or [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\') -ine $state.Directory)) {
            throw 'A server installation was found. Refresh the server step before continuing.'
        }
        $destination = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
        $desktop = [IO.Path]::GetFullPath($DesktopDirectory).TrimEnd('\')
        if ($destination -ieq $desktop -or $destination.StartsWith($desktop + '\', [StringComparison]::OrdinalIgnoreCase) -or $desktop.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Choose separate folders for the desktop app and server.'
        }
        if ((Test-Path -LiteralPath $destination) -and !(Test-Path -LiteralPath (Join-Path $destination '.git'))) {
            if (@(Get-ChildItem -LiteralPath $destination -Force).Count) { throw 'Choose an empty folder for the server.' }
            Remove-Item -LiteralPath $destination -Force
        }
        $env:SOCKETAGENT_UNATTENDED = '1'
        $env:SOCKETAGENT_INSTALL_DIR = $destination
        $support = Join-Path $PSScriptRoot 'server-support'
        Expand-Archive -LiteralPath (Join-Path $PSScriptRoot 'server-support.zip') -DestinationPath $support -Force
        $env:SOCKETAGENT_INSTALLER_SUPPORT = $support
        $logFolder = Join-Path $env:LOCALAPPDATA 'SocketAgent/setup-logs'
        New-Item -ItemType Directory -Force $logFolder | Out-Null
        $logFile = Join-Path $logFolder ('server-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        Write-Output 'PHASE:Preparing the local server'
        # Only known progress/error lines leave this pipeline. Pairing QR contents,
        # generated tokens and other raw setup output never enter wizard/setup logs.
        & (Join-Path $PSScriptRoot 'server-bootstrap.ps1') *>&1 | ForEach-Object {
            $line = [string]$_
            if ($line -match '^--- (Phase [0-9]+: .+) ---$') {
                $message = $Matches[1]
                Add-Content -LiteralPath $logFile -Value $message
                Write-Output ('PHASE:' + $message)
            } elseif ($line -match '^\s*\[(OK|!)\] (.+)$') {
                Add-Content -LiteralPath $logFile -Value $line.Trim()
            }
        }
        $state = Find-LocalServer
    }
    if ($Action -eq 'Start' -and $state.Status -ne 'running') {
        if (!$state.TaskName) { throw 'The server has no startup task for this Windows user. Start it manually, or continue without connecting.' }
        Write-Output 'PHASE:Starting the existing local server'
        Start-ScheduledTask -TaskName $state.TaskName
        $deadline = (Get-Date).AddSeconds(180)
        do { Start-Sleep -Seconds 2; $state = Find-LocalServer } while ($state.Status -ne 'running' -and (Get-Date) -lt $deadline)
    }
    Write-Result $state
    if ($state.Status -ne 'running') { throw 'The server is not ready. You can retry or finish installing the desktop app.' }
    # Enables app discovery for custom/legacy task locations without copying credentials.
    $marker = Join-Path $env:LOCALAPPDATA 'SocketAgent/install-location.txt'
    New-Item -ItemType Directory -Force (Split-Path $marker) | Out-Null
    [IO.File]::WriteAllText($marker, $state.Directory, [Text.Encoding]::UTF8)
    Write-Output 'PHASE:Local server ready. The app will connect automatically.'
} catch {
    Write-Output ('ERROR:' + $_.Exception.Message)
    exit 1
}
