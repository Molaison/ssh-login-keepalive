# Run on a Windows CI runner: exercise task registration with mocked native calls.
$ErrorActionPreference = 'Stop'
$package = Split-Path -Parent $PSScriptRoot
$files = @('keepalivectl.ps1', 'ssh-worker.ps1', 'install.ps1', 'ssh-auth-setup.ps1')
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
$global:fakeSsh = Join-Path $tempDir 'ssh-stub.cmd'
Set-Content -LiteralPath $global:fakeSsh -Encoding ASCII -Value @('@echo off', 'exit /b 0')
$global:taskInstalled = $false
$global:taskName = ''
$global:taskAction = $null
$global:packageForTest = $package

function Get-Command {
    [CmdletBinding()]
    param([string]$Name, [string]$CommandType)
    if ($Name -eq 'ssh.exe') {
        return [pscustomobject]@{ Source = $global:fakeSsh }
    }
    if ($Name -eq 'ssh-keygen.exe') {
        return [pscustomobject]@{ Source = (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe') }
    }
    throw "Unexpected Get-Command: $Name"
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
    if ($global:taskInstalled) { [pscustomobject]@{ State = 'Running' } }
}
function Get-ScheduledTaskInfo {
    param($TaskName)
    [pscustomobject]@{ LastTaskResult = 267009 }
}
function Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $Principal, $Settings, [switch]$Force)
    $global:taskName = $TaskName
    $global:taskAction = $Action
    $global:taskInstalled = $true
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
    $global:taskInstalled = $false
}
function Read-Host {
    param($Prompt)
    switch ($Prompt) {
        'SSH username' { return 'bob' }
        'Target SSH hostname or SSH alias' { return 'login.example.org' }
        default { throw "Unexpected prompt: $Prompt" }
    }
}
function Invoke-WebRequest {
    param([switch]$UseBasicParsing, $Uri, $OutFile)
    if ($Uri -notlike 'https://github.com/Molaison/ssh-login-keepalive/*main.zip') {
        throw "Unexpected download URL: $Uri"
    }
    Set-Content -LiteralPath $OutFile -Value 'downloaded-by-test'
}
function Expand-Archive {
    param($LiteralPath, $DestinationPath)
    $source = Join-Path $DestinationPath 'ssh-login-keepalive-main'
    New-Item -ItemType Directory -Path $source | Out-Null
    Copy-Item -LiteralPath (Join-Path $global:packageForTest 'keepalivectl.ps1') -Destination $source
    Copy-Item -LiteralPath (Join-Path $global:packageForTest 'ssh-worker.ps1') -Destination $source
    Copy-Item -LiteralPath (Join-Path $global:packageForTest 'ssh-auth-setup.ps1') -Destination $source
}

try {
    & (Join-Path $package 'keepalivectl.ps1') install lab 'alice@cluster.example.org'
    if (-not $global:taskInstalled -or $global:taskName -notlike '*-lab') {
        throw 'Task was not registered.'
    }
    $profile = Join-Path $tempDir 'ssh-login-keepalive\profiles\lab.json'
    $conf = Get-Content -LiteralPath $profile -Raw | ConvertFrom-Json
    if ($conf.Target -ne 'alice@cluster.example.org') {
        throw 'Incorrect persisted Windows target.'
    }
    if ($global:taskAction.Argument -notmatch 'ssh-worker\.ps1') {
        throw 'Registered action did not invoke the worker.'
    }
    & (Join-Path $package 'keepalivectl.ps1') status lab
    & (Join-Path $package 'keepalivectl.ps1') remove lab
    if ($global:taskInstalled -or (Test-Path -LiteralPath $profile)) {
        throw 'Task/profile removal failed.'
    }
    Write-Host 'Windows PowerShell and mocked Task Scheduler lifecycle: OK'

    & (Join-Path $package 'install.ps1')
    $bootstrapProfile = Join-Path $tempDir 'ssh-login-keepalive\profiles\bob-login-example-org.json'
    $installed = Get-Content -LiteralPath $bootstrapProfile -Raw | ConvertFrom-Json
    if ($installed.Target -ne 'bob@login.example.org' -or -not $global:taskInstalled) {
        throw 'Interactive GitHub bootstrap did not install the Windows profile.'
    }
    $savedCLI = Join-Path $tempDir 'ssh-login-keepalive\bin\keepalivectl.ps1'
    if (-not (Test-Path -LiteralPath $savedCLI)) {
        throw 'Windows bootstrap did not retain its management command.'
    }
    & $savedCLI remove bob-login-example-org
    if ($global:taskInstalled -or (Test-Path -LiteralPath $bootstrapProfile)) {
        throw 'Bootstrap profile could not be removed.'
    }
    Write-Host 'Windows interactive GitHub bootstrap: OK'

    $global:fakeSsh = Join-Path $tempDir 'ssh-enroll.cmd'
    $env:TEST_SSH_ENROLLED = Join-Path $tempDir 'enrolled-marker'
    Set-Content -LiteralPath $global:fakeSsh -Encoding ASCII -Value @(
        '@echo off',
        'if "%~1"=="-n" (',
        '  if exist "%TEST_SSH_ENROLLED%" exit /b 0',
        '  exit /b 255',
        ')',
        'if "%~1"=="-T" (',
        '  echo enrolled > "%TEST_SSH_ENROLLED%"',
        '  exit /b 0',
        ')',
        'exit /b 2'
    )
    $keyPath = Join-Path $tempDir 'ssh auth key\id_ed25519'
    & (Join-Path $package 'ssh-auth-setup.ps1') -Target 'alice@login.example.org' -KeyPath $keyPath
    if (-not (Test-Path -LiteralPath $keyPath) -or -not (Test-Path -LiteralPath "$keyPath.pub")) {
        throw 'SSH Ed25519 key was not created on Windows.'
    }
    if (-not (Test-Path -LiteralPath $env:TEST_SSH_ENROLLED)) {
        throw 'Public-key enrollment was not invoked.'
    }
    Write-Host 'Windows SSH key generation and enrollment simulation: OK'
} finally {
    $env:LOCALAPPDATA = $originalAppData
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
