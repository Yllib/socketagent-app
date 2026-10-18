# Compiles the SocketAgent Desktop installer into $OutputDirectory. It carries
# setup only and downloads the app at install time (see installer/socketagent.iss),
# so it does not need a Flutter build.
param(
    [string]$SupportDirectory,
    [string]$OutputDirectory,
    [Parameter(Mandatory)][string]$Version
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell leaves $PSScriptRoot empty in parameter defaults under -File.
$root = Split-Path $PSScriptRoot -Parent
if (!$SupportDirectory) { $SupportDirectory = Join-Path $root 'build/installer-input' }
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'build/windows/packages' }
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
if (!(Test-Path (Join-Path $SupportDirectory 'server-bootstrap.ps1'))) {
    throw 'Missing installer input: server-bootstrap.ps1. Run build-windows-desktop-installer.sh from the server checkout.'
}
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
& $compiler /Q "/DOutputDir=$OutputDirectory" "/DSupportDir=$SupportDirectory" "/DAppVersion=$Version" (Join-Path $PSScriptRoot 'installer/socketagent.iss')
if ($LASTEXITCODE) { throw 'Windows installer compilation failed' }
