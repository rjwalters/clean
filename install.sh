#!/bin/bash
#
# install.sh — install `clean` onto your PATH as a symlink to this repo
#
# Re-run anytime to repair or move the install. Update via `git pull` in
# this repo; the symlink keeps pointing at the live script.

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$REPO_DIR/cleanup.sh"

NAME="clean"
PREFIX=""
FORCE=false
UNINSTALL=false

usage() {
    cat <<EOF
install.sh — install \`clean\` as a symlink to $REPO_DIR/cleanup.sh

Usage: ./install.sh [options]

Options:
  --prefix DIR    Install dir (default: /usr/local/bin if writable, else ~/.local/bin)
  --name NAME     Command name (default: clean)
  --uninstall     Remove the symlink (only if it points at this repo)
  --force         Overwrite a non-symlink file at the target
  -h, --help      Show this help

Update:
  cd $REPO_DIR && git pull
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)    PREFIX="$2"; shift 2 ;;
        --name)      NAME="$2"; shift 2 ;;
        --uninstall) UNINSTALL=true; shift ;;
        --force)     FORCE=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ ! -f "$SCRIPT" ]; then
    echo "❌ cleanup.sh not found at $SCRIPT" >&2
    exit 1
fi

# Pick install dir.
if [ -z "$PREFIX" ]; then
    if [ -w /usr/local/bin ] 2>/dev/null; then
        PREFIX="/usr/local/bin"
    else
        PREFIX="$HOME/.local/bin"
    fi
fi
mkdir -p "$PREFIX"
TARGET="$PREFIX/$NAME"

# Uninstall path.
if $UNINSTALL; then
    if [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
        echo "Nothing at $TARGET — already uninstalled."
        exit 0
    fi
    if [ -L "$TARGET" ]; then
        link_dest="$(readlink "$TARGET")"
        if [ "$link_dest" = "$SCRIPT" ]; then
            rm "$TARGET"
            echo "✅ Removed $TARGET"
            exit 0
        fi
        echo "❌ $TARGET is a symlink to $link_dest (not this repo). Refusing to remove." >&2
        exit 1
    fi
    echo "❌ $TARGET is a regular file, not a symlink. Refusing to remove." >&2
    exit 1
fi

chmod +x "$SCRIPT"

# Idempotent install: if the symlink already points where we want, we're done.
if [ -L "$TARGET" ]; then
    link_dest="$(readlink "$TARGET")"
    if [ "$link_dest" = "$SCRIPT" ]; then
        echo "✅ Already installed: $TARGET → $SCRIPT"
    else
        echo "↻ Replacing existing symlink ($link_dest)"
        ln -sf "$SCRIPT" "$TARGET"
        echo "✅ Installed: $TARGET → $SCRIPT"
    fi
elif [ -e "$TARGET" ]; then
    if ! $FORCE; then
        echo "❌ $TARGET exists and is not a symlink. Re-run with --force to overwrite." >&2
        exit 1
    fi
    rm -f "$TARGET"
    ln -s "$SCRIPT" "$TARGET"
    echo "✅ Installed (overwrote existing file): $TARGET → $SCRIPT"
else
    ln -s "$SCRIPT" "$TARGET"
    echo "✅ Installed: $TARGET → $SCRIPT"
fi

# PATH check.
case ":$PATH:" in
    *":$PREFIX:"*) ;;
    *)
        echo ""
        echo "⚠️  $PREFIX is not on your PATH."
        echo "   Add this to your shell rc (~/.zshrc or ~/.bashrc):"
        echo ""
        echo "     export PATH=\"$PREFIX:\$PATH\""
        echo ""
        ;;
esac

echo ""
echo "Run:    $NAME --help"
echo "Update: cd $REPO_DIR && git pull"
