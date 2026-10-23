$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/server-discovery.ps1"
$fixture = Join-Path $env:TEMP ('sa-discovery-' + [guid]::NewGuid())
$userDir = Join-Path $fixture 'user'
$localDir = Join-Path $fixture 'local'
$serverDir = Join-Path $fixture 'Custom server folder'
function Assert-Status($Expected, $Probe = { $false }, $Tasks = @()) {
    $result = Find-LocalServer -UserDirectory $userDir -LocalDirectory $localDir -Tasks $Tasks -Probe $Probe -MachineServer { $null }
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
    # The machine-wide server: only a marker an administrator or SYSTEM owns counts.
    $marker = Join-Path $fixture 'machine-server.json'
    if (Get-MachineServer -Marker $marker -TrustedOwners @('S-1-0-0') -Probe { $true }) { throw 'A missing marker found a server' }
    [IO.File]::WriteAllText($marker, '{"directory":"C:\\Users\\owner\\socketagent","port":8086,"task":"NoSuchSocketAgentTask"}')
    # Elevated, the fixture belongs to Administrators, so trust follows the real owner.
    $me = (Get-Acl -LiteralPath $marker).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if (Get-MachineServer -Marker $marker -TrustedOwners @('S-1-0-0') -Probe { $true }) { throw 'An untrusted marker owner was accepted' }
    $shared = Get-MachineServer -Marker $marker -TrustedOwners @($me) -Probe { param($port) $port -eq 8086 }
    if ($shared.Status -ne 'running' -or !$shared.Shared -or $shared.TaskName -ne '' -or $shared.Directory -ne 'C:\Users\owner\socketagent') { throw "Wrong machine server: $($shared | ConvertTo-Json -Compress)" }
    if ((Get-MachineServer -Marker $marker -TrustedOwners @($me) -Probe { $false }).Status -ne 'stopped') { throw 'A silent machine server was reported running' }
    $result = Find-LocalServer -UserDirectory $userDir -LocalDirectory $localDir -Tasks @() -Probe { $false } -MachineServer { $shared }
    if (!$result.Shared) { throw 'The machine server did not take precedence' }
    'PASS: missing, unrelated, incomplete, stopped, authenticated configuration, custom folder, legacy task, legacy folder, invalid port, no credential output, machine server'
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
