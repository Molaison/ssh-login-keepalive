#!/bin/sh
# Bootstrap from GitHub for Linux and macOS. Read from /dev/tty so curl | sh works.
set -eu

case "$(uname -s)" in
    Linux) platform=Linux ;;
    Darwin) platform=macOS ;;
    *)
        echo 'Unsupported shell platform. On Windows use the PowerShell installer in README.md.' >&2
        exit 1
        ;;
esac

for tool in curl tar bash; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required command: $tool" >&2
        exit 1
    fi
done

if ! (: </dev/tty) 2>/dev/null; then
    echo 'An interactive terminal is required to enter the SSH username and host.' >&2
    exit 1
fi

printf '\nSSH Login Keepalive — %s\n' "$platform" >&2
printf 'SSH username: ' >&2
IFS= read -r ssh_user </dev/tty || exit 1
printf 'Target SSH hostname or SSH alias: ' >&2
IFS= read -r ssh_host </dev/tty || exit 1

case "$ssh_user" in
    ''|*[!A-Za-z0-9_-]*) echo 'Invalid SSH username.' >&2; exit 2 ;;
esac
case "$ssh_user" in
    [A-Za-z0-9_]*) ;;
    *) echo 'SSH username must begin with a letter, digit or underscore.' >&2; exit 2 ;;
esac
case "$ssh_host" in
    ''|*[!A-Za-z0-9_.-]*) echo 'Invalid SSH hostname or alias.' >&2; exit 2 ;;
esac
case "$ssh_host" in
    [A-Za-z0-9]*) ;;
    *) echo 'Hostname or alias must begin with a letter or digit.' >&2; exit 2 ;;
esac

profile=$(printf '%s-%s' "$ssh_user" "$ssh_host" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
target="$ssh_user@$ssh_host"

umask 077
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ssh-login-keepalive.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

printf 'Downloading installer from GitHub...\n' >&2
curl -fsSL --retry 2 \
    'https://github.com/Molaison/ssh-login-keepalive/archive/refs/heads/main.tar.gz' \
    -o "$tmp/source.tar.gz"
tar -xzf "$tmp/source.tar.gz" -C "$tmp"
source_dir="$tmp/ssh-login-keepalive-main"
for file in keepalivectl ssh-login-keepalive@.service; do
    test -f "$source_dir/$file" || { echo "Downloaded archive is missing $file" >&2; exit 1; }
done

install_dir="$HOME/.local/share/ssh-login-keepalive"
mkdir -p "$install_dir"
cp "$source_dir/keepalivectl" "$source_dir/ssh-login-keepalive@.service" "$install_dir/"
chmod 700 "$install_dir/keepalivectl"

printf 'Setting up %s on this %s computer...\n' "$target" "$platform" >&2
bash "$install_dir/keepalivectl" install "$profile" "$target"

printf '\nInstallation complete. Profile: %s\n' "$profile"
printf 'Status: bash "%s/keepalivectl" status %s\n' "$install_dir" "$profile"
printf 'Remove: bash "%s/keepalivectl" remove %s\n' "$install_dir" "$profile"
