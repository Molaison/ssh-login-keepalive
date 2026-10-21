# Windows: register a per-user Task Scheduler job on THIS computer.
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('install', 'status', 'remove')]
    [string]$Action,

    [Parameter(Position = 1, Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')]
    [string]$Name,

    [Parameter(Position = 2)]
    [string]$Target
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$taskName = "ssh-login-keepalive-$($identity.User.Value)-$Name"
$baseDir = Join-Path $env:LOCALAPPDATA 'ssh-login-keepalive'
$profileDir = Join-Path $baseDir 'profiles'
$profilePath = Join-Path $profileDir "$Name.json"
$workerPath = Join-Path $baseDir 'ssh-worker.ps1'
$logPath = Join-Path $baseDir "$Name.log"

switch ($Action) {
    'install' {
        if ($Target -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9_.-]*$') {
            throw 'Specify USER@HOST or USER@ssh-alias as the third argument.'
        }

        $ssh = (Get-Command ssh.exe -CommandType Application -ErrorAction Stop).Source
        & $ssh -n -T -o BatchMode=yes -o ConnectTimeout=10 $Target true
        if ($LASTEXITCODE -ne 0) {
            throw "SSH preflight failed for $Target. Configure an SSH key and known_hosts first."
        }

        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ssh-worker.ps1') -Destination $workerPath -Force
        [pscustomobject]@{ Target = $Target; SshPath = $ssh } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $profilePath -Encoding UTF8

        $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ProfilePath "{1}"' -f $workerPath, $profilePath
        $taskAction = New-ScheduledTaskAction -Execute $powershellPath -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
        $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
            -MultipleInstances IgnoreNew -StartWhenAvailable `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing -and $existing.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $taskName
        }
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $running = $false
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            $registeredTask = Get-ScheduledTask -TaskName $taskName
            if ($registeredTask.State -eq 'Running') {
                $running = $true
                break
            }
            Start-Sleep -Seconds 1
        }
        if (-not $running) {
            throw "Installed $taskName, but its task process is not running. Check Task Scheduler."
        }
        Write-Host "Installed $taskName -> $Target (on this Windows computer)"
        Write-Host 'Verified Task Scheduler process running; noninteractive SSH preflight passed.'
        Write-Host "Status: .\keepalivectl.ps1 status $Name"
    }
    'status' {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        Write-Host "Task: $taskName; State: $($task.State); LastTaskResult: $($info.LastTaskResult)"
        if (Test-Path -LiteralPath $logPath) {
            Get-Content -LiteralPath $logPath -Tail 8
        }
    }
    'remove' {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $taskName
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        Remove-Item -LiteralPath $profilePath -ErrorAction SilentlyContinue
        Write-Host "Removed $taskName"
    }
}
