# Read-only support check. Run while Desktop and the local server are open,
# then quit Desktop normally. Does not start, stop, or reconfigure either app.
param(
    [int]$ServerPort = 8085,
    [int]$Seconds = 90,
    [string]$OutputFile = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SocketAgent-exit-diagnostics.json')
)
$ErrorActionPreference = 'Stop'
$started = Get-Date
$samples = [Collections.Generic.List[object]]::new()
$events = @()

function Get-ProcessAncestry([int]$ProcessId) {
    $seen = @{}
    $chain = @()
    while ($ProcessId -gt 0 -and !$seen.ContainsKey($ProcessId) -and $chain.Count -lt 8) {
        $seen[$ProcessId] = $true
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if (!$process) { break }
        # Deliberately omit command lines, environment, and authentication data.
        $chain += [pscustomobject]@{id=$process.ProcessId; name=$process.Name; parent=$process.ParentProcessId; started=$process.CreationDate}
        $ProcessId = [int]$process.ParentProcessId
    }
    return $chain
}

function Get-Snapshot {
    $apps = @(Get-Process socketagent -ErrorAction SilentlyContinue)
    $listeners = @(Get-NetTCPConnection -LocalPort $ServerPort -State Listen -ErrorAction SilentlyContinue)
    $serverIds = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
    $reachable = $false
    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect('127.0.0.1', $ServerPort, $null, $null)
        if ($pending.AsyncWaitHandle.WaitOne(1000)) {
            $client.EndConnect($pending)
            $reachable = $true
        }
    } catch {} finally { $client.Dispose() }
    $tasks = @(foreach ($name in @('SocketAgent','SocketClaude')) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
            [pscustomobject]@{name=$name; state=[string]$task.State; lastResult=$info.LastTaskResult; lastRun=$info.LastRunTime}
        }
    })
    return [pscustomobject]@{
        time=(Get-Date).ToUniversalTime().ToString('o')
        desktopIds=@($apps | Select-Object -ExpandProperty Id)
        serverIds=$serverIds
        serverReachable=$reachable
        tasks=$tasks
    }
}

Write-Host 'Quit SocketAgent Desktop normally while this check runs. Leave the server alone.'
$desktopVersions = @(Get-Process socketagent -ErrorAction SilentlyContinue | ForEach-Object { $_.MainModule.FileVersionInfo.ProductVersion })
$first = Get-Snapshot
$ancestry = @(foreach ($processId in @($first.desktopIds) + @($first.serverIds)) { Get-ProcessAncestry $processId })
$deadline = $started.AddSeconds($Seconds)
$desktopExited = $null
while ((Get-Date) -lt $deadline) {
    $sample = Get-Snapshot
    $samples.Add($sample)
    if ($first.desktopIds.Count -gt 0 -and $sample.desktopIds.Count -eq 0 -and !$desktopExited) { $desktopExited = Get-Date }
    # Keep observing for 15 seconds after exit to catch a delayed failure/restart.
    if ($desktopExited -and (Get-Date) -ge $desktopExited.AddSeconds(15)) { break }
    Start-Sleep -Seconds 1
}
$events = @(Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$started; Id=@(1,42,107)} -ErrorAction SilentlyContinue |
    Where-Object ProviderName -in @('Microsoft-Windows-Kernel-Power','Microsoft-Windows-Power-Troubleshooter') |
    Select-Object TimeCreated,ProviderName,Id)
[pscustomobject]@{
    serverPort=$ServerPort
    desktopVersions=$desktopVersions
    processAncestry=$ancestry
    desktopExitObserved=($null -ne $desktopExited)
    samples=$samples.ToArray()
    powerEvents=$events
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputFile -Encoding UTF8
Write-Host "Saved: $OutputFile"
