param([string]$SupportDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'build/installer-input'))
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& "$PSScriptRoot/installer/test-server-discovery.ps1"
$compiler = Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe'
if (!(Test-Path $compiler)) {
    $download = Join-Path $env:TEMP 'socketagent-inno-6.7.3.exe'
    Invoke-WebRequest -UseBasicParsing 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe' -OutFile $download
    $signature = Get-AuthenticodeSignature $download
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Pyrsys') { throw 'Inno Setup signature verification failed' }
    $process = Start-Process $download -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER' -Wait -PassThru
    if ($process.ExitCode -ne 0 -or !(Test-Path $compiler)) { throw 'Inno Setup compiler installation failed' }
}
$versionLine = Get-Content (Join-Path $root 'pubspec.yaml') | Where-Object { $_ -match '^version:' } | Select-Object -First 1
$version = ($versionLine -replace '^version:\s*', '') -replace '\+.*$', ''
$release = Join-Path $root 'build/windows/x64/runner/Release'
foreach ($file in @('server-bootstrap.ps1', 'server-support.zip')) {
    if (!(Test-Path (Join-Path $SupportDirectory $file))) { throw "Missing installer input: $file. Run build-app.sh --windows from the server checkout." }
}
& $compiler "/DReleaseDir=$release" "/DSupportDir=$SupportDirectory" "/DAppVersion=$version" (Join-Path $PSScriptRoot 'installer/socketagent.iss')
if ($LASTEXITCODE) { throw 'Windows installer compilation failed' }
