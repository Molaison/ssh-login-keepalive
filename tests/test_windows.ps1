# Run on a Windows CI runner: exercise task registration with mocked native calls.
$ErrorActionPreference = 'Stop'
$package = Split-Path -Parent $PSScriptRoot
$files = @('keepalivectl.ps1', 'ssh-worker.ps1')
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $package $file), [ref]$tokens, [ref]$errors
    ) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell syntax error in $file : $($errors[0])"
    }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempDir | Out-Null
$originalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $tempDir
$script:fakeSsh = Join-Path $tempDir 'ssh-stub.cmd'
Set-Content -LiteralPath $script:fakeSsh -Encoding ASCII -Value @('@echo off', 'exit /b 0')
$script:taskInstalled = $false
$script:taskName = ''
$script:taskAction = $null

function Get-Command {
    [CmdletBinding()]
    param([string]$Name, [string]$CommandType)
    if ($Name -ne 'ssh.exe') { throw "Unexpected Get-Command: $Name" }
    [pscustomobject]@{ Source = $script:fakeSsh }
}
function New-ScheduledTaskAction {
    param($Execute, $Argument)
    [pscustomobject]@{ Execute = $Execute; Argument = $Argument }
}
function New-ScheduledTaskTrigger {
    param([switch]$AtLogOn, $User)
    [pscustomobject]@{ AtLogOn = $AtLogOn; User = $User }
}
function New-ScheduledTaskPrincipal {
    param($UserId, $LogonType, $RunLevel)
    [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
}
function New-ScheduledTaskSettingsSet {
    param($ExecutionTimeLimit, $MultipleInstances, [switch]$StartWhenAvailable,
          [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries)
    [pscustomobject]@{ ExecutionTimeLimit = $ExecutionTimeLimit; MultipleInstances = $MultipleInstances }
}
function Get-ScheduledTask {
    [CmdletBinding()]
    param($TaskName)
    if ($script:taskInstalled) { [pscustomobject]@{ State = 'Running' } }
}
function Get-ScheduledTaskInfo {
    param($TaskName)
    [pscustomobject]@{ LastTaskResult = 267009 }
}
function Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $Principal, $Settings, [switch]$Force)
    $script:taskName = $TaskName
    $script:taskAction = $Action
    $script:taskInstalled = $true
    if (-not $Trigger.AtLogOn -or $Principal.LogonType -ne 'Interactive') {
        throw 'Expected interactive user logon task.'
    }
    if ($Settings.ExecutionTimeLimit.TotalSeconds -ne 0) {
        throw 'Expected unlimited scheduled-task lifetime.'
    }
}
function Start-ScheduledTask { param($TaskName) }
function Stop-ScheduledTask { param($TaskName) }
function Unregister-ScheduledTask {
    param($TaskName, [switch]$Confirm)
    $script:taskInstalled = $false
}

try {
    & (Join-Path $package 'keepalivectl.ps1') install lab 'alice@cluster.example.org'
    if (-not $script:taskInstalled -or $script:taskName -notlike '*-lab') {
        throw 'Task was not registered.'
    }
    $profile = Join-Path $tempDir 'ssh-login-keepalive\profiles\lab.json'
    $conf = Get-Content -LiteralPath $profile -Raw | ConvertFrom-Json
    if ($conf.Target -ne 'alice@cluster.example.org') {
        throw 'Incorrect persisted Windows target.'
    }
    if ($script:taskAction.Argument -notmatch 'ssh-worker\.ps1') {
        throw 'Registered action did not invoke the worker.'
    }
    & (Join-Path $package 'keepalivectl.ps1') status lab
    & (Join-Path $package 'keepalivectl.ps1') remove lab
    if ($script:taskInstalled -or (Test-Path -LiteralPath $profile)) {
        throw 'Task/profile removal failed.'
    }
    Write-Host 'Windows PowerShell and mocked Task Scheduler lifecycle: OK'
} finally {
    $env:LOCALAPPDATA = $originalAppData
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
