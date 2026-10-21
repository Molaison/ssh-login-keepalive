# Windows one-time public-key enrollment. SSH itself prompts for passwords/OTP.
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$KeyPath = (Join-Path $HOME '.ssh\id_ed25519')
)

$ErrorActionPreference = 'Stop'

if ($Target -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9_.-]*$') {
    throw 'Target must be USER@HOST or USER@ssh-alias.'
}

$ssh = (Get-Command ssh.exe -CommandType Application -ErrorAction Stop).Source

function Test-UnattendedSSH {
    & $ssh -n -T -o BatchMode=yes -o ConnectTimeout=10 $Target true
    return ($LASTEXITCODE -eq 0)
}

if (Test-UnattendedSSH) {
    Write-Host "Unattended SSH already works: $Target (no key changes)."
    return
}

$keygen = (Get-Command ssh-keygen.exe -CommandType Application -ErrorAction Stop).Source
$publicKeyPath = "$KeyPath.pub"
$hasPrivate = Test-Path -LiteralPath $KeyPath
$hasPublic = Test-Path -LiteralPath $publicKeyPath
if ($hasPrivate -xor $hasPublic) {
    throw "Existing SSH key files are incomplete at $KeyPath; refusing to overwrite."
}

if (-not $hasPrivate) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $KeyPath) -Force | Out-Null
    Write-Host "Creating an Ed25519 key at $KeyPath without a passphrase for unattended login."
    Write-Host 'Protect the private key and this computer; do not share or upload it.'
    # On Windows PowerShell 5.1, literal double quotes preserve an empty -N argument.
    & $keygen -q -t ed25519 -f $KeyPath -N '""'
    if ($LASTEXITCODE -ne 0) {
        throw 'ssh-keygen failed; key was not installed.'
    }
} else {
    Write-Host "Reusing your existing public key: $publicKeyPath"
}

$publicKey = (Get-Content -LiteralPath $publicKeyPath -Raw -Encoding ASCII).Trim()
if ($publicKey -cnotmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[A-Za-z0-9-]+) [A-Za-z0-9+/=]+(?:\s.*)?$') {
    throw 'Invalid public key; cannot safely transmit it to the remote host.'
}
# Drop the optional comment and pass only base64 key data, avoiding remote quoting.
$publicKey = ($publicKey -split ' ')[0..1] -join ' '

Write-Host "Installing the PUBLIC key on $Target; SSH may ask for the remote password and/or OTP."
Write-Host 'Check the host fingerprint when prompted. No password is saved.'
$remoteCommand = @'
set -eu
umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
authorized_keys="$HOME/.ssh/authorized_keys"
touch "$authorized_keys"
chmod 600 "$authorized_keys"
IFS= read -r public_key || test -n "$public_key"
public_key=$(printf %s "$public_key" | tr -d "\r")
if ! grep -qxF -- "$public_key" "$authorized_keys"; then
    printf "%s\n" "$public_key" >> "$authorized_keys"
fi
'@
# Use the normal OpenSSH connection; the key is supplied over stdin, not as an argument.
$publicKey | & $ssh -T -o ConnectTimeout=15 $Target $remoteCommand
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install public key on $Target; no keepalive service will be installed."
}

if (-not (Test-UnattendedSSH)) {
    throw @'
Public key was uploaded, but unattended SSH still fails. The key may require
a passphrase/agent or the server may require OTP even after public-key login.
Do not bypass enforced MFA. Configure an authorized SSH-OTP client separately
or ask the cluster administrator about supported access.
'@
}

Write-Host "Public-key login verified without interactive credentials: $Target"
