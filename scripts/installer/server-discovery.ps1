# Shared, read-only server discovery. Results contain no credentials.
function Read-ServerEnvironment([string]$File) {
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($File)) {
        if ($line.TrimStart([char]0xfeff) -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $value = $Matches[2].Trim()
            if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            } else { $value = ($value -split '#', 2)[0].Trim() }
            $values[$Matches[1]] = $value
        }
    }
    return $values
}

function Test-ServerReady($Configuration) {
    foreach ($endpoint in @('health', 'status')) {
        try {
            $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$($Configuration.Port)/internal/restart/$endpoint")
            $request.Proxy = $null
            $request.AllowAutoRedirect = $false
            $request.Timeout = 1800
            $request.ReadWriteTimeout = 1800
            $request.Headers['Authorization'] = 'Bearer ' + $Configuration.Token
            $response = $request.GetResponse()
            try {
                $reader = New-Object IO.StreamReader($response.GetResponseStream())
                try {
                    $buffer = New-Object char[] 65537
                    $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
                    if ($count -gt 65536) { return $false }
                    $body = (-join $buffer[0..($count - 1)]) | ConvertFrom-Json
                } finally { $reader.Dispose() }
                if ($response.StatusCode -ne 200 -or $body.ready -ne $true -or $body.pid -le 0) { return $false }
                if ($endpoint -eq 'health') { return $body.service -eq 'socketagent' }
                return ($body.preparing -is [bool] -and $body.sessions -is [array])
            } finally { $response.Dispose() }
        } catch {
            # Older releases expose the authenticated restart status, but no health endpoint.
            $errorCause = $_.Exception
            while ($errorCause.InnerException) { $errorCause = $errorCause.InnerException }
            if ($endpoint -eq 'health' -and $errorCause.Response -and [int]$errorCause.Response.StatusCode -eq 404) { $errorCause.Response.Dispose(); continue }
            return $false
        }
    }
    return $false
}

function Get-OwnedServerTasks {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($name in @('SocketAgent', 'SocketClaude')) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if (!$task) { continue }
        try {
            $owner = $task.Principal.UserId
            if ($owner -notlike 'S-1-*') { $owner = (New-Object Security.Principal.NTAccount($owner)).Translate([Security.Principal.SecurityIdentifier]).Value }
            if ($owner -ne $sid) { continue }
            foreach ($action in $task.Actions) {
                $directory = $action.WorkingDirectory
                if (!$directory -and $action.Arguments -match '"([^"\r\n]+[\\/]server)[\\/]run-service(?:-hidden)?\.(?:bat|vbs)"') { $directory = $Matches[1] }
                if ($directory -and (Split-Path $directory -Leaf) -ieq 'server') {
                    [pscustomobject]@{ Name = $name; Directory = [IO.Path]::GetFullPath((Split-Path $directory -Parent)); State = [string]$task.State }
                }
            }
        } catch { continue }
    }
}

function Find-LocalServer {
    param(
        [string]$UserDirectory = $env:USERPROFILE,
        [string]$LocalDirectory = $env:LOCALAPPDATA,
        [object[]]$Tasks = @(Get-OwnedServerTasks),
        [scriptblock]$Probe = { param($configuration) Test-ServerReady $configuration }
    )
    $paths = @()
    $marker = Join-Path $LocalDirectory 'SocketAgent/install-location.txt'
    if (Test-Path -LiteralPath $marker) { $paths += ([IO.File]::ReadAllText($marker)).Trim().TrimStart([char]0xfeff) }
    $paths += @($Tasks | ForEach-Object { $_.Directory })
    $paths += Join-Path $UserDirectory 'socketagent'
    $paths += Join-Path $UserDirectory 'socketclaude'
    $found = @()
    foreach ($path in @($paths | Where-Object { $_ } | Select-Object -Unique)) {
        $result = $null
        try {
            $path = [IO.Path]::GetFullPath($path).TrimEnd('\', '/')
            if (!(Test-Path -LiteralPath (Join-Path $path 'server/package.json'))) { continue }
            $package = [IO.File]::ReadAllText((Join-Path $path 'server/package.json')) | ConvertFrom-Json
            if ($package.name -notin @('socketagent-server', 'socketclaude-server', 'claude-assistant-server')) { continue }
            $task = $Tasks | Where-Object { $_.Directory.TrimEnd('\', '/') -ieq $path } | Select-Object -First 1
            $result = [pscustomobject]@{ Status = 'unavailable'; Directory = $path; Port = 8085; TaskName = [string]$task.Name }
            $envFile = Join-Path $path 'server/.env'
            if (!(Test-Path -LiteralPath $envFile)) { $found += $result; continue }
            $configuration = Read-ServerEnvironment $envFile
            $port = 8085
            if ($configuration.PORT -and (![int]::TryParse($configuration.PORT, [ref]$port) -or $port -lt 1 -or $port -gt 65535)) { $found += $result; continue }
            $result.Port = $port
            $data = $configuration.SOCKET_AGENT_DATA_DIR
            if (!$data) { $data = $configuration.SOCKETAGENT_DATA_DIR }
            if (!$data) { $data = $env:SOCKET_AGENT_DATA_DIR }
            if (!$data) { $data = $env:SOCKETAGENT_DATA_DIR }
            if (!$data) { $data = $configuration.SOCKET_AGENT_HOME }
            if (!$data) { $data = $configuration.SOCKETAGENT_HOME }
            if (!$data) { $data = $env:SOCKET_AGENT_HOME }
            if (!$data) { $data = $env:SOCKETAGENT_HOME }
            $directories = if ($data) { @($data) } else { @((Join-Path $UserDirectory '.socket-agent'), (Join-Path $UserDirectory '.claude-assistant')) }
            $hasKeys = $false
            foreach ($directory in $directories) {
                $keyFile = Join-Path $directory 'relay-keys.json'
                if (Test-Path -LiteralPath $keyFile) {
                    try { $keys = [IO.File]::ReadAllText($keyFile) | ConvertFrom-Json; $hasKeys = [Convert]::FromBase64String($keys.publicKey).Length -eq 32 } catch {}
                }
                if ($hasKeys) { break }
            }
            if (!$configuration.AUTH_TOKEN -or !$hasKeys) { $found += $result; continue }
            if (& $Probe @{ Port = $port; Token = $configuration.AUTH_TOKEN }) { $result.Status = 'running'; return $result }
            $result.Status = 'stopped'
            $found += $result
        } catch {
            if ($result) { $found += $result }
            continue
        }
    }
    if ($found.Count) { return $found[0] }
    return [pscustomobject]@{ Status = 'missing'; Directory = ''; Port = 8085; TaskName = '' }
}
