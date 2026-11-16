# Checks the download helper in desktop-setup.ps1 against a local server that
# stops answering: the helper has to give up within its timeouts, remove the
# partial file, and stop when setup asks it to cancel.
$ErrorActionPreference = 'Stop'
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/desktop-setup.ps1", [ref]$null, [ref]$null)
foreach ($name in 'Test-Cancelled', 'Open-WebResponse', 'Save-WebFile') {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (!$function) { throw "desktop-setup.ps1 has no $name" }
    . ([scriptblock]::Create($function.Extent.Text))
}
$ConnectTimeoutMs = 2000
$ReadTimeoutMs = 2000
$folder = Join-Path $env:TEMP ('sa-setup-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force $folder | Out-Null
$CancelFile = Join-Path $folder 'cancel'
$file = Join-Path $folder 'download.bin'

$probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()
# /silent never answers, /stall sends the headers and 1000 of 200000 bytes,
# /full sends all of them.
$server = Start-Job -ArgumentList $port {
    param($port)
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port)
    $listener.Start()
    $held = @()
    while ($true) {
        # A blocking accept cannot be interrupted, and Stop-Job then waits on it.
        if (!$listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
        $client = $listener.AcceptTcpClient()
        $held += $client
        try {
            $stream = $client.GetStream()
            $request = New-Object byte[] 4096
            $text = [Text.Encoding]::ASCII.GetString($request, 0, $stream.Read($request, 0, $request.Length))
            if ($text -notmatch '^GET /(stall|full)') { continue }
            $full = $Matches[1] -eq 'full'
            $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 200000`r`nConnection: close`r`n`r`n")
            $stream.Write($head, 0, $head.Length)
            $body = New-Object byte[] $(if ($full) { 200000 } else { 1000 })
            $stream.Write($body, 0, $body.Length)
            $stream.Flush()
            if ($full) { $client.Close() }
        } catch {}
    }
}

# Runs $Action, which must fail with $Expected in its message inside ten
# seconds. Without the timeouts it would never return.
function Assert-Fails([string]$Expected, [scriptblock]$Action) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if (!$message) { throw "Expected a failure containing '$Expected', but the call succeeded" }
    if ($message -notmatch [regex]::Escape($Expected)) { throw "Expected '$Expected'; received '$message'" }
    if ($watch.Elapsed.TotalSeconds -gt 10) { throw "Took $([int]$watch.Elapsed.TotalSeconds)s to fail with '$Expected'" }
}

try {
    $base = "http://127.0.0.1:$port"
    $ready = $false
    foreach ($try in 1..50) {
        $client = New-Object Net.Sockets.TcpClient
        try { $client.Connect('127.0.0.1', $port); $ready = $true } catch { Start-Sleep -Milliseconds 200 } finally { $client.Close() }
        if ($ready) { break }
    }
    if (!$ready) { throw 'The test server did not start' }

    Assert-Fails 'timed out' { Open-WebResponse "$base/silent" '' }

    Assert-Fails 'The download stopped' { Save-WebFile "$base/stall" $file 'Downloading' }
    if (Test-Path -LiteralPath $file) { throw 'A stalled download left its partial file' }

    $output = @(Save-WebFile "$base/full" $file 'Downloading')
    if ((Get-Item -LiteralPath $file).Length -ne 200000) { throw 'The finished download is the wrong size' }
    if ($output -notcontains 'PHASE:Downloading, 100%') { throw "No progress reported: $($output -join '; ')" }
    Remove-Item -LiteralPath $file

    [IO.File]::WriteAllText($CancelFile, '')
    Assert-Fails 'Setup was cancelled' { Save-WebFile "$base/full" $file 'Downloading' }
    if (Test-Path -LiteralPath $file) { throw 'A cancelled download left its partial file' }
    'PASS: silent server, stalled download, full download, cancelled download'
} finally {
    Stop-Job $server
    Remove-Job $server -Force
    Remove-Item -LiteralPath $folder -Recurse -Force
}
