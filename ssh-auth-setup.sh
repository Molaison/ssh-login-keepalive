#!/usr/bin/env bash
# Interactive, one-time public-key enrollment. Passwords are handled by ssh itself.
set -euo pipefail

target=${1:?Usage: ssh-auth-setup.sh USER@HOST}
if [[ ! $target =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    echo 'Target must be USER@HOST or USER@ssh-alias.' >&2
    exit 2
fi

for tool in ssh ssh-keygen; do
    command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done

ssh_probe() {
    ssh -n -T -o BatchMode=yes -o ConnectTimeout=10 "$target" true
}

if ssh_probe; then
    echo "Unattended SSH already works: $target (no key changes)."
    exit 0
fi

ssh_dir="$HOME/.ssh"
private_key="$ssh_dir/id_ed25519"
public_key="$private_key.pub"

if [[ -e $private_key && ! -f $public_key || ! -e $private_key && -e $public_key ]]; then
    echo "Existing SSH key files are incomplete at $private_key; refusing to overwrite." >&2
    exit 1
fi
if [[ ! -e $private_key ]]; then
    mkdir -p -- "$ssh_dir"
    chmod 700 "$ssh_dir"
    echo "Creating a dedicated-to-this-user OpenSSH Ed25519 default key at $private_key." >&2
    echo 'For unattended login the generated key has no passphrase; protect this computer and its private key.' >&2
    ssh-keygen -q -t ed25519 -N '' -f "$private_key"
    chmod 600 "$private_key"
    chmod 644 "$public_key"
else
    echo "Reusing your existing public key: $public_key" >&2
fi

echo "Installing the PUBLIC key on $target; SSH may ask for your remote password and/or OTP." >&2
echo 'Confirm the remote host fingerprint if SSH asks. No remote password is saved.' >&2

# Send only the public key via SSH stdin; SSH asks for credentials on the terminal.
# On the target, do not overwrite existing authorized_keys entries.
remote_command='
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
'

ssh -T -o ConnectTimeout=15 "$target" "$remote_command" < "$public_key"

if ! ssh_probe; then
    echo 'Public key was uploaded, but unattended SSH still fails.' >&2
    echo 'Possible causes: the key is passphrase-protected without a persistent agent,' >&2
    echo 'or the SSH server requires OTP / keyboard-interactive authentication even after a key.' >&2
    echo 'Do not bypass required MFA. If permitted, configure your existing SSH-OTP' >&2
    echo 'client separately; otherwise ask the cluster administrator about supported access.' >&2
    exit 1
fi

echo "Public-key login verified without interactive credentials: $target"
