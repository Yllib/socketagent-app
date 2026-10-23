#Requires -Version 5.1
param(
    [ValidateSet('Fetch', 'Detect', 'Link', 'Start', 'Install', 'Quit')][string]$Action = 'Detect',
    [string]$ResultFile,
    [string]$InstallDirectory,
    [string]$DesktopDirectory,
    # For Fetch: a local SocketAgent-windows-x64.zip to install instead of the
    # latest release, and the folder to unpack it into.
    [string]$Package,
    [string]$PackageDirectory
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Result($State) {
    if ($ResultFile) {
        $shared = if ($State.Shared) { 1 } else { 0 }
        $text = "[server]`r`nstatus=$($State.Status)`r`ndirectory=$($State.Directory)`r`nport=$($State.Port)`r`ntask=$($State.TaskName)`r`nshared=$shared`r`n"
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

# Downloads the newest released app build, checks it against the SHA-256 GitHub
# publishes for it, and unpacks it for setup to install. The installer carries
# no app files, so it only needs rebuilding (and signing) when setup changes.
function Get-DesktopPackage {
    $zip = $Package
    $version = ''
    if (!$zip) {
        # Windows PowerShell 5.1 can default to TLS 1.0, which GitHub refuses.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Output 'PHASE:Finding the latest SocketAgent Desktop release'
        $asset = $null
        # GitHub can keep serving a stale or empty list for the same URL, so
        # each try uses a new URL, and tries continue for about 5 seconds.
        foreach ($delay in @(0, 500, 1000, 1500, 2000)) {
            Start-Sleep -Milliseconds $delay
            $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            try {
                $releases = Invoke-RestMethod -UseBasicParsing -Headers @{ Accept = 'application/vnd.github+json'; 'Cache-Control' = 'no-cache' } "https://api.github.com/repos/Yllib/socketagent/releases?per_page=30&t=$cacheBust"
            } catch {
                continue
            }
            # Android-only releases carry no desktop build, so take the newest that does.
            foreach ($release in $releases) {
                if ($release.draft -or $release.prerelease) { continue }
                $asset = @($release.assets | Where-Object { $_.name -eq 'SocketAgent-windows-x64.zip' -and $_.state -eq 'uploaded' -and $_.digest -match '^sha256:[0-9a-fA-F]{64}$' }) | Select-Object -First 1
                if ($asset) { $version = $release.tag_name -replace '^v', ''; break }
            }
            if ($asset) { break }
        }
        if (!$asset) { throw 'No SocketAgent Desktop release is available to download. Check your internet connection and retry.' }
        $zip = Join-Path $env:TEMP "socketagent-desktop-$version.zip"
        Write-Output "PHASE:Downloading SocketAgent Desktop $version"
        Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $zip
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash -ine $asset.digest.Substring(7)) {
            Remove-Item -LiteralPath $zip -Force
            throw 'The download did not match the published release. Retry setup.'
        }
    }
    Write-Output 'PHASE:Unpacking SocketAgent Desktop'
    if (Test-Path -LiteralPath $PackageDirectory) { Remove-Item -LiteralPath $PackageDirectory -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $PackageDirectory)
    if (!$Package) { Remove-Item -LiteralPath $zip -Force }
    $exe = Join-Path $PackageDirectory 'socketagent.exe'
    if (!(Test-Path -LiteralPath $exe)) { throw 'The SocketAgent Desktop package is missing socketagent.exe.' }
    if (!$version) { $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -replace '\+.*$', '' }
    if ($ResultFile) { [IO.File]::WriteAllText($ResultFile, "[package]`r`nversion=$version`r`n", [Text.Encoding]::Unicode) }
}

try {
    if ($Action -eq 'Fetch') {
        if (!$PackageDirectory) { throw 'Fetch needs -PackageDirectory.' }
        Get-DesktopPackage
        exit 0
    }
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
        # Server setup runs from the clone, so server fixes reach new installs
        # without a new signed installer.
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
    if ($state.Shared) {
        # Only the owner's account can read the server's token, so this app
        # asks to be approved with its device key when it first connects.
        Write-Output 'PHASE:This computer''s shared server is running. Approve the app from another device when it opens.'
        exit 0
    }
    # Enables app discovery for custom/legacy task locations without copying credentials.
    $marker = Join-Path $env:LOCALAPPDATA 'SocketAgent/install-location.txt'
    New-Item -ItemType Directory -Force (Split-Path $marker) | Out-Null
    [IO.File]::WriteAllText($marker, $state.Directory, [Text.Encoding]::UTF8)
    Write-Output 'PHASE:Local server ready. The app will connect automatically.'
} catch {
    Write-Output ('ERROR:' + $_.Exception.Message)
    exit 1
}
