# Launched by Task Scheduler. Reconnects when the remote SSH session ends.
param([Parameter(Mandatory = $true)][string]$ProfilePath)

$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
if ($config.Target -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9_.-]*$') {
    throw 'Invalid target profile.'
}

$name = [System.IO.Path]::GetFileNameWithoutExtension($ProfilePath)
$logPath = Join-Path (Split-Path -Parent (Split-Path -Parent $ProfilePath)) "$name.log"

while ($true) {
    try {
        & ($config.SshPath) -n -T -o BatchMode=yes -o ConnectTimeout=15 `
            -o ServerAliveInterval=30 -o ServerAliveCountMax=3 `
            $config.Target 'exec sleep infinity' 2>> $logPath
        $exitCode = $LASTEXITCODE
    } catch {
        Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format s): $($_.Exception.Message)"
        $exitCode = 'error'
    }
    Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format s): SSH exited ($exitCode); retrying in 10 seconds"
    Start-Sleep -Seconds 10
}
