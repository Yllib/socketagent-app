$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/server-discovery.ps1"
$fixture = Join-Path $env:TEMP ('sa-discovery-' + [guid]::NewGuid())
$userDir = Join-Path $fixture 'user'
$localDir = Join-Path $fixture 'local'
$serverDir = Join-Path $fixture 'Custom server folder'
function Assert-Status($Expected, $Probe = { $false }, $Tasks = @()) {
    $result = Find-LocalServer -UserDirectory $userDir -LocalDirectory $localDir -Tasks $Tasks -Probe $Probe
    if ($result.Status -ne $Expected) { throw "Expected $Expected; received $($result.Status)" }
    if (($result | ConvertTo-Json) -match 'fixture-secret') { throw 'Discovery leaked credentials' }
    return $result
}
try {
    New-Item -ItemType Directory -Force "$localDir/SocketAgent", "$serverDir/server", "$userDir/.claude-assistant" | Out-Null
    Assert-Status missing | Out-Null
    [IO.File]::WriteAllText("$localDir/SocketAgent/install-location.txt",$serverDir)
    [IO.File]::WriteAllText("$serverDir/server/package.json",'{"name":"unrelated"}')
    Assert-Status missing | Out-Null
    [IO.File]::WriteAllText("$serverDir/server/package.json",'{"name":"socketagent-server"}')
    Assert-Status unavailable | Out-Null
    [IO.File]::WriteAllText("$serverDir/server/.env", "PORT=8185`nAUTH_TOKEN='fixture-secret#quoted'`n")
    Assert-Status unavailable | Out-Null
    [IO.File]::WriteAllText("$userDir/.claude-assistant/relay-keys.json", ('{"publicKey":"' + [Convert]::ToBase64String((New-Object byte[] 32)) + '"}'))
    Assert-Status stopped | Out-Null
    $result = Assert-Status running {param($c) if($c.Port -ne 8185 -or $c.Token -ne 'fixture-secret#quoted'){throw 'Wrong credentials'}; $true}
    if($result.Directory -ne $serverDir) {throw 'Custom location lost'}
    Remove-Item "$localDir/SocketAgent/install-location.txt"
    $result = Assert-Status stopped { $false } @([pscustomobject]@{Name='SocketClaude';Directory=$serverDir})
    if($result.TaskName -ne 'SocketClaude') {throw 'Legacy task lost'}
    Move-Item $serverDir "$userDir/socketclaude"
    Assert-Status running {$true} | Out-Null
    [IO.File]::WriteAllText("$userDir/socketclaude/server/.env", "PORT=999999`nAUTH_TOKEN=fixture-secret`n")
    Assert-Status unavailable {$true} | Out-Null
    'PASS: missing, unrelated, incomplete, stopped, authenticated configuration, custom folder, legacy task, legacy folder, invalid port, no credential output'
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
