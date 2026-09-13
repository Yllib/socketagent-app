$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$flutter = 'C:/Users/billy/Downloads/flutter/flutter/bin/flutter.bat'
if ($env:SOCKETAGENT_FLUTTER) { $flutter = $env:SOCKETAGENT_FLUTTER }
Set-Location $root
# flutter_tts and WebView2 use NuGet during their native Windows builds.
$toolDir = Join-Path $env:LOCALAPPDATA 'SocketAgent/build-tools'
New-Item -ItemType Directory -Force $toolDir | Out-Null
$nuget = Join-Path $toolDir 'nuget.exe'
if (-not (Test-Path $nuget)) {
  Invoke-WebRequest 'https://dist.nuget.org/win-x86-commandline/v6.14.0/nuget.exe' -OutFile $nuget
}
$signature = Get-AuthenticodeSignature $nuget
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
  throw 'NuGet did not have a valid Microsoft signature'
}
$env:PATH = "$toolDir;$env:PATH"
& $flutter pub get
if ($LASTEXITCODE) { throw 'Dependency resolution failed' }
& $flutter analyze --no-fatal-infos --no-fatal-warnings
if ($LASTEXITCODE) { throw 'Flutter analysis failed' }
& $flutter test test/session_actions_sheet_test.dart test/desktop_composer_keys_test.dart test/chat_history_pagination_test.dart test/anchored_action_menu_test.dart test/desktop_window_frame_test.dart test/paywall_screen_test.dart test/config_import_access_test.dart test/desktop_split_view_test.dart test/desktop_navigation_test.dart test/windows_local_server_test.dart test/desktop_qr_import_test.dart test/server_config_test.dart test/notification_session_target_test.dart
if ($LASTEXITCODE) { throw 'Desktop tests failed' }
& $flutter build windows --release --dart-define=SOCKETAGENT_DISTRIBUTION=windows
if ($LASTEXITCODE) { throw 'Windows build failed' }
$release = Join-Path $root 'build/windows/x64/runner/Release'
# Both preferences and encrypted credentials derive their directory from these
# compiled resources. Check the actual executable before packaging an upgrade.
$identity = (Get-Item (Join-Path $release 'socketagent.exe')).VersionInfo
if ($identity.CompanyName -cne 'Rubano Enterprises, LLC' -or $identity.ProductName -cne 'SocketAgent') {
  throw 'Windows profile identity changed; this would disconnect existing computers and settings.'
}
if ($identity.FileDescription -cne 'SocketAgent Desktop') {
  throw 'Windows display name must be SocketAgent Desktop.'
}
foreach ($required in @('socketagent.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin')) {
  if (!(Test-Path (Join-Path $release $required))) { throw "Incomplete Windows bundle: $required is missing" }
}
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$crt = Get-ChildItem "$vs/VC/Redist/MSVC/*/x64/Microsoft.VC143.CRT" -Directory | Sort-Object FullName -Descending | Select-Object -First 1
if (!$crt) { throw 'Visual C++ runtime redistributables were not found' }
Copy-Item "$($crt.FullName)/*.dll" $release -Force
$packageDir = Join-Path $root 'build/windows/packages'
New-Item -ItemType Directory -Force $packageDir | Out-Null
Copy-Item "$PSScriptRoot/install-windows-app.ps1" $release -Force
Copy-Item "$PSScriptRoot/install-windows-app.cmd" $release -Force
Copy-Item "$PSScriptRoot/WINDOWS-README.txt" "$release/README.txt" -Force
Remove-Item "$release/socketagent.exp", "$release/socketagent.lib" -ErrorAction SilentlyContinue
Compress-Archive -Path "$release/*" -DestinationPath "$packageDir/SocketAgent-windows-x64.zip" -Force

& "$PSScriptRoot/build-windows-installer.ps1"
