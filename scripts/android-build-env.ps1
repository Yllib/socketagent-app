# Run before an Android build on Windows; its PATH changes reach the caller.
# The sodium package compiles libsodium for Android with autotools, which
# needs Git for Windows' bash and GNU make on PATH. Make comes from a pinned
# ezwinports build, fetched once.
$ErrorActionPreference = 'Stop'
$toolDir = Join-Path $env:LOCALAPPDATA 'SocketAgent/build-tools'
$makeDir = Join-Path $toolDir 'make-4.4.1'
$make = Join-Path $makeDir 'bin/make.exe'
if (-not (Test-Path $make)) {
  New-Item -ItemType Directory -Force $toolDir | Out-Null
  $zip = Join-Path $toolDir 'make-4.4.1.zip'
  Invoke-WebRequest 'https://sourceforge.net/projects/ezwinports/files/make-4.4.1-without-guile-w32-bin.zip/download' -OutFile $zip -UserAgent 'Wget'
  $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
  if ($hash -ne 'FB66A02B530F7466F6222CE53C0B602C5288E601547A034E4156A512DD895EE7') {
    Remove-Item $zip -Force
    throw "GNU make download did not match its pinned hash: $hash"
  }
  Expand-Archive $zip -DestinationPath $makeDir -Force
  Remove-Item $zip -Force
}
$gitBash = 'C:\Program Files\Git\bin'
if (-not (Test-Path (Join-Path $gitBash 'bash.exe'))) {
  throw "Git for Windows' bash.exe is missing from $gitBash"
}
$env:PATH = "$gitBash;$(Split-Path $make);$env:PATH"
