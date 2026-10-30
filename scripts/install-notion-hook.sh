#!/bin/bash
# Independently build/install the Notion CLI; app installation is separate.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
prefix="$HOME/.local/bin"
domain="io.github.tori-create-7991.splitvox"
old_executable="/Applications/Splitvox.app/Contents/MacOS/Splitvox"
backup_root="$HOME/Library/Application Support/SplitvoxNotion/InstallBackups"
migrate=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix|--domain|--old-executable|--backup-directory)
            [ "$#" -ge 2 ] || { echo "Missing option value" >&2; exit 2; }
            case "$1" in
                --prefix) prefix="$2" ;;
                --domain) domain="$2" ;;
                --old-executable) old_executable="$2" ;;
                --backup-directory) backup_root="$2" ;;
            esac
            shift 2 ;;
        --migrate) migrate=yes; shift ;;
        --help)
            echo "Usage: bash scripts/install-notion-hook.sh [--prefix /absolute/bin] [--migrate]"
            echo "  [--domain preferences.domain] [--old-executable /absolute/app] [--backup-directory /private/path]"
            echo "Stop the idle app before --migrate. The app and live Notion are never invoked."
            exit 0 ;;
        *) echo "Unknown option" >&2; exit 2 ;;
    esac
done
case "$prefix" in /*) ;; *) echo "Prefix must be absolute" >&2; exit 2 ;; esac
case "$backup_root" in /*) ;; *) echo "Backup directory must be absolute" >&2; exit 2 ;; esac
swift build --package-path "$repo_root/Tools/notion-exporter" -c release
bin_dir="$(swift build --package-path "$repo_root/Tools/notion-exporter" -c release --show-bin-path)"
mkdir -p "$prefix"
destination="$prefix/splitvox-notion"
[ ! -L "$destination" ] || { echo "Refusing to replace a symlink: $destination" >&2; exit 1; }
[ ! -d "$destination" ] || { echo "Destination is a directory" >&2; exit 1; }
staged="$(mktemp "$prefix/.splitvox-notion.XXXXXX")"
trap 'rm -f "$staged"' EXIT
install -m 755 "$bin_dir/splitvox-notion" "$staged"
"$staged" --help >/dev/null
if [ -e "$destination" ]; then
    private_backup="$backup_root/$(uuidgen)"
    (umask 077; mkdir -p "$private_backup")
    cp -p "$destination" "$private_backup/splitvox-notion"
    echo "Previous CLI saved: $private_backup/splitvox-notion"
fi
mv -f "$staged" "$destination"
echo "Installed: $destination"
if [ "$migrate" = yes ]; then
    "$destination" --migrate-local-hooks --domain "$domain" --old-executable "$old_executable" \
        --new-executable "$destination" --backup-directory "$backup_root"
    "$destination" --migrate-local-hooks --domain "$domain" --old-executable "$old_executable" \
        --new-executable "$destination" --backup-directory "$backup_root" --write
fi
