# Bootstrap from GitHub for Windows PowerShell. Does not change system policy.
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This installer is for Windows. Use install.sh on Linux or macOS.'
}

Write-Host ''
Write-Host 'SSH Login Keepalive - Windows'
$sshUser = (Read-Host 'SSH username').Trim()
$sshHost = (Read-Host 'Target SSH hostname or SSH alias').Trim()

if ($sshUser -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_-]*$') {
    throw 'Invalid SSH username.'
}
if ($sshHost -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
    throw 'Invalid SSH hostname or alias.'
}

$profile = ($sshUser + '-' + $sshHost).ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
$target = "$sshUser@$sshHost"

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ssh-login-keepalive-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    Write-Host 'Downloading installer from GitHub...'
    $zip = Join-Path $tmp 'source.zip'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/Molaison/ssh-login-keepalive/archive/refs/heads/main.zip' -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp
    $sourceDir = Join-Path $tmp 'ssh-login-keepalive-main'
    $binDir = Join-Path $env:LOCALAPPDATA 'ssh-login-keepalive\bin'
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null

    foreach ($file in @('keepalivectl.ps1', 'ssh-worker.ps1', 'ssh-auth-setup.ps1')) {
        $sourceFile = Join-Path $sourceDir $file
        if (-not (Test-Path -LiteralPath $sourceFile)) {
            throw "Downloaded archive is missing $file"
        }
        Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $binDir $file) -Force
    }

    $cli = Join-Path $binDir 'keepalivectl.ps1'
    Write-Host "Checking SSH authentication for $target..."
    & (Join-Path $binDir 'ssh-auth-setup.ps1') -Target $target
    Write-Host "Setting up $target on this Windows computer..."
    & $cli install $profile $target

    Write-Host ''
    Write-Host "Installation complete. Profile: $profile"
    Write-Host "Status: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$cli`" status $profile"
    Write-Host "Remove: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$cli`" remove $profile"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
