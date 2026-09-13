param(
  [string]$Sdk = "$env:LOCALAPPDATA/Android/Sdk",
  [string]$Java = 'C:/Program Files/Android/Android Studio/jbr/bin',
  [string]$Output = "$env:TEMP/socketagent-install-demo"
)
$ErrorActionPreference = 'Stop'
$env:JAVA_HOME = Split-Path $Java
$env:PATH = "$Java;$env:PATH"
$buildTools = Join-Path $Sdk 'build-tools/35.0.0'
$androidJar = Join-Path $Sdk 'platforms/android-36/android.jar'
New-Item -ItemType Directory -Force $Output, "$Output/classes", "$Output/dex" | Out-Null
function Run-Tool([string]$Executable, [string[]]$Arguments) {
  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Executable failed ($LASTEXITCODE)" }
}
Run-Tool "$Java/javac.exe" @('-source','8','-target','8','-classpath',$androidJar,'-d',"$Output/classes","$PSScriptRoot/src/com/rubano/socketagent/installdemo/MainActivity.java")
Run-Tool "$Java/jar.exe" @('cf',"$Output/classes.jar",'-C',"$Output/classes",'.')
Run-Tool "$buildTools/d8.bat" @('--lib',$androidJar,'--min-api','24','--output',"$Output/dex","$Output/classes.jar")
Run-Tool "$buildTools/aapt.exe" @('package','-f','-M',"$PSScriptRoot/AndroidManifest.xml",'-I',$androidJar,'-F',"$Output/unsigned.apk")
Push-Location "$Output/dex"
try { Run-Tool "$buildTools/aapt.exe" @('add',"$Output/unsigned.apk",'classes.dex') } finally { Pop-Location }
Run-Tool "$buildTools/zipalign.exe" @('-f','4',"$Output/unsigned.apk","$Output/aligned.apk")
if (-not (Test-Path "$Output/demo.jks")) {
  Run-Tool "$Java/keytool.exe" @('-genkeypair','-keystore',"$Output/demo.jks",'-storepass','android','-keypass','android','-alias','demo','-keyalg','RSA','-keysize','2048','-validity','3650','-dname','CN=SocketAgent Install Demo')
}
Run-Tool "$buildTools/apksigner.bat" @('sign','--ks',"$Output/demo.jks",'--ks-key-alias','demo','--ks-pass','pass:android','--key-pass','pass:android','--out',"$Output/socketagent-install-demo.apk","$Output/aligned.apk")
Run-Tool "$buildTools/apksigner.bat" @('verify',"$Output/socketagent-install-demo.apk")
Run-Tool "$buildTools/aapt.exe" @('dump','permissions',"$Output/socketagent-install-demo.apk")
Get-FileHash "$Output/socketagent-install-demo.apk" -Algorithm SHA256 | Format-List
