#!/usr/bin/env bash
# version.sh — manage the `clean` version in cleanup.sh + CHANGELOG.md
#
# Usage:
#   ./scripts/version.sh                  # Show current version
#   ./scripts/version.sh check            # Verify cleanup.sh and CHANGELOG agree
#   ./scripts/version.sh bump patch       # 0.1.0 → 0.1.1
#   ./scripts/version.sh bump minor       # 0.1.0 → 0.2.0
#   ./scripts/version.sh bump major       # 0.1.0 → 1.0.0
#   ./scripts/version.sh set 1.2.3        # Set explicit version
#   ./scripts/version.sh set 1.2.3 --tag  # Set version, move Unreleased
#                                         # section to a dated entry, commit,
#                                         # and create annotated tag v1.2.3
#
# Adapted from loom's scripts/version.sh — single-source-of-truth is
# the VERSION="X.Y.Z" line in cleanup.sh.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/cleanup.sh"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

get_version() {
  grep -m1 '^VERSION=' "$SCRIPT" | sed 's/VERSION="\(.*\)"/\1/'
}

# Most recent dated entry in CHANGELOG, e.g. "0.1.0" from "## [0.1.0] - 2026-06-05"
get_changelog_version() {
  grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

check_versions() {
  local expected actual_changelog
  expected=$(get_version)
  actual_changelog=$(get_changelog_version)

  local ok=true
  if [ "$actual_changelog" = "$expected" ]; then
    echo "OK        cleanup.sh: $expected"
    echo "OK        CHANGELOG.md latest entry: $actual_changelog"
  else
    echo "OK        cleanup.sh: $expected"
    echo "MISMATCH  CHANGELOG.md latest entry: $actual_changelog (expected $expected)"
    ok=false
  fi

  if $ok; then
    echo ""
    echo "Versions in sync: $expected"
    return 0
  else
    echo ""
    echo "Version mismatch. Update CHANGELOG.md, or re-run with: $0 set $expected --tag"
    return 1
  fi
}

bump_version() {
  local current="$1"
  local part="$2"
  IFS='.' read -r major minor patch <<< "$current"
  case "$part" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
    *) echo "Unknown bump type: $part (use major, minor, or patch)" >&2; exit 1 ;;
  esac
}

set_version() {
  local new_version="$1"
  if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid version format: $new_version (expected X.Y.Z)" >&2
    exit 1
  fi

  local old_version
  old_version=$(get_version)

  echo "Updating version: $old_version → $new_version"

  # cleanup.sh — replace the first VERSION="..." line
  awk -v ver="$new_version" '!done && /^VERSION="/ { print "VERSION=\"" ver "\""; done=1; next } 1' \
    "$SCRIPT" > "$SCRIPT.tmp" && mv "$SCRIPT.tmp" "$SCRIPT"
  chmod +x "$SCRIPT"
  echo "  Updated cleanup.sh"
}

# Convert the "## [Unreleased]" heading into a dated release section for $1
# (no-op if there's no Unreleased section, or if it's already been dated).
date_unreleased_section() {
  local version="$1"
  local today
  today=$(date +%Y-%m-%d)

  if ! grep -q '^## \[Unreleased\]' "$CHANGELOG"; then
    echo "  No [Unreleased] section found in CHANGELOG.md — skipping rewrite"
    return
  fi

  # Replace "## [Unreleased]" with "## [Unreleased]\n\n## [VERSION] - DATE"
  awk -v ver="$version" -v today="$today" '
    /^## \[Unreleased\]/ && !done {
      print "## [Unreleased]"
      print ""
      print "## [" ver "] - " today
      done = 1
      next
    }
    { print }
  ' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"
  echo "  Promoted [Unreleased] → [$version] - $today in CHANGELOG.md"
}

do_tag() {
  local version="$1"

  date_unreleased_section "$version"

  echo ""
  echo "Committing and tagging..."
  (
    cd "$REPO_ROOT"
    git add cleanup.sh CHANGELOG.md
    git commit -m "chore: release v$version"
    git tag -a "v$version" -m "v$version"
  )
  echo ""
  echo "Created commit and tag v$version"
  echo "Push with: git push origin main --tags"
}

case "${1:-}" in
  ""|show)
    get_version
    ;;
  check)
    check_versions
    ;;
  bump)
    part="${2:-patch}"
    current=$(get_version)
    new_version=$(bump_version "$current" "$part")
    set_version "$new_version"
    if [ "${3:-}" = "--tag" ]; then
      do_tag "$new_version"
    fi
    ;;
  set)
    if [ -z "${2:-}" ]; then
      echo "Usage: $0 set <version> [--tag]" >&2
      exit 1
    fi
    set_version "$2"
    if [ "${3:-}" = "--tag" ]; then
      do_tag "$2"
    fi
    ;;
  -h|--help)
    sed -n '2,17p' "$0"
    ;;
  *)
    echo "Usage: $0 [show|check|bump <major|minor|patch> [--tag]|set <version> [--tag]]" >&2
    exit 1
    ;;
esac
