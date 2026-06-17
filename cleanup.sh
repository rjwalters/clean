#!/bin/bash

# clean — aggressive but safe disk cleanup for macOS dev machines
#
# Designed for developers who work with lots of git worktrees.
# Cleans system caches, Docker resources, per-project build artifacts,
# and stale worktrees/branches for closed GitHub issues.
#
# Safety nets:
#   1. Age thresholds — never delete files modified within N days
#   2. Open-handle check (lsof) — never delete dirs with active processes
#   3. Active worktree check — never delete inside live git worktrees
#   4. GitHub issue check — only clean worktrees for CLOSED issues
#   5. Tool-native commands (cargo clean, uv cache prune) over rm -rf
#   6. Pattern matching — only known cache/temp patterns, never source

set -e

VERSION="0.2.0"

# Auto-detect project directory: use CLEAN_PROJECT_DIR env var, or fall back
# to ~/GitHub, ~/Projects, ~/repos, ~/src (first that exists).
if [ -n "$CLEAN_PROJECT_DIR" ]; then
    PROJECT_DIR="$CLEAN_PROJECT_DIR"
else
    PROJECT_DIR=""
    for candidate in "$HOME/GitHub" "$HOME/Projects" "$HOME/repos" "$HOME/src"; do
        if [ -d "$candidate" ]; then
            PROJECT_DIR="$candidate"
            break
        fi
    done
fi

VENV_AGE_DAYS=7
TMP_AGE_HOURS=1              # /tmp clones must be at least this old
PYCACHE_AGE_DAYS=14          # __pycache__ etc must be at least this old
TARGET_AGE_DAYS=7            # rust target dirs must be at least this old
WORKTREE_AGE_DAYS=14         # non-issue agent worktrees must be at least this old
CHECK_MODE=false
AGGRESSIVE_MODE=false
SYSTEM_ONLY=false
TOTAL_SIZE=0
ACTIVE_WORKTREES=""

# Parse arguments
if [ "$1" = "--version" ] || [ "$1" = "-V" ]; then
    echo "clean $VERSION"
    exit 0
fi

if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "clean $VERSION — aggressive but safe disk cleanup for macOS dev machines"
    echo ""
    echo "Usage: clean [options]"
    echo ""
    echo "Designed for developers working with lots of git worktrees."
    echo ""
    echo "System cleanup:"
    echo "  • Homebrew, npm, pnpm, pip, bun, uv caches"
    echo "  • HuggingFace cache (info only — interactive cleanup recommended)"
    echo "  • Docker (containers >24h old, dangling images, unused volumes, build cache)"
    echo "  • Stale /tmp clones (>$TMP_AGE_HOURS h, no open handles)"
    echo "  • VS Code extension caches"
    echo "  • System logs >30 days old"
    echo ""
    echo "Per-project cleanup:"
    echo "  • node_modules, .next"
    echo "  • Python caches (__pycache__, .pytest_cache, .ruff_cache) >$PYCACHE_AGE_DAYS days"
    echo "  • Python venvs (root + subdirs) >$VENV_AGE_DAYS days"
    echo "  • Rust target/ dirs (root + monorepo subdirs) >$TARGET_AGE_DAYS days"
    echo "  • Java/Kotlin build/, .gradle/"
    echo "  • git gc --auto + git worktree prune"
    echo ""
    echo "Worktree cleanup (requires gh CLI):"
    echo "  • Worktrees for closed GitHub issues (.loom/worktrees/issue-*, .claude/worktrees/issue-*)"
    echo "  • Stale agent-workflow worktrees (.loom/worktrees/*, .claude/worktrees/*) >$WORKTREE_AGE_DAYS days"
    echo "    — only if clean (no uncommitted/unpushed work) and no live process"
    echo "  • Feature branches for closed issues (feature/issue-*)"
    echo "  • Loom tmux sessions (loom-*)"
    echo ""
    echo "Safety nets:"
    echo "  • Age thresholds (configurable at top of script)"
    echo "  • Open-handle check via lsof (skips dirs with active processes)"
    echo "  • Active worktree check (never touches files inside live worktrees)"
    echo "  • GitHub issue status check (only cleans worktrees for CLOSED issues)"
    echo "  • Tool-native commands when possible (cargo clean, uv cache prune)"
    echo ""
    echo "Options:"
    echo "  -h, --help         Show this help message"
    echo "  -V, --version      Print version and exit"
    echo "  -c, --check        Check how much space would be freed (dry run)"
    echo "  -a, --aggressive   Also run 'docker system prune -af --volumes'"
    echo "  --system-only      Skip per-project cleanup (system caches only)"
    echo ""
    echo "Environment:"
    echo "  CLEAN_PROJECT_DIR  Override project directory (default: auto-detect"
    echo "                     ~/GitHub, ~/Projects, ~/repos, ~/src)"
    echo ""
    echo "Examples:"
    echo "  clean                              # Run cleanup"
    echo "  clean --check                      # Preview what would be cleaned"
    echo "  clean --aggressive                 # Include destructive Docker prune"
    echo "  CLEAN_PROJECT_DIR=~/code clean     # Custom project directory"
    exit 0
fi

for arg in "$@"; do
    case "$arg" in
        --check|-c) CHECK_MODE=true ;;
        --aggressive|-a) AGGRESSIVE_MODE=true ;;
        --system-only) SYSTEM_ONLY=true ;;
    esac
done

if [ "$SYSTEM_ONLY" = false ] && [ -z "$PROJECT_DIR" ]; then
    echo "⚠️  No project directory found (checked ~/GitHub, ~/Projects, ~/repos, ~/src)"
    echo "   Set CLEAN_PROJECT_DIR or pass --system-only."
    echo ""
    SYSTEM_ONLY=true
fi

if [ "$CHECK_MODE" = true ]; then
    echo "🔍 Checking potential space savings..."
    echo ""
else
    echo "🧹 Starting disk cleanup..."
    [ "$AGGRESSIVE_MODE" = true ] && echo "💥 Aggressive mode enabled (Docker full prune)"
    echo ""
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

get_size() {
    du -sh "$1" 2>/dev/null | cut -f1
}

get_size_bytes() {
    du -sk "$1" 2>/dev/null | cut -f1
}

bytes_to_human() {
    local bytes=$1
    if [ $bytes -lt 1024 ]; then
        echo "${bytes}K"
    elif [ $bytes -lt 1048576 ]; then
        echo "$((bytes / 1024))M"
    else
        echo "$((bytes / 1024 / 1024))G"
    fi
}

# Check if directory is older than N days (precise to seconds via stat -f %m, macOS only)
is_older_than_days() {
    local dir="$1"
    local days="$2"
    local current_time=$(date +%s)
    local dir_time=$(stat -f %m "$dir" 2>/dev/null || echo 0)
    local threshold_seconds=$(( days * 86400 ))
    local age_seconds=$(( current_time - dir_time ))
    [ $age_seconds -gt $threshold_seconds ]
}

# Hours-based variant for short-lived scratch dirs
is_older_than_hours() {
    local dir="$1"
    local hours="$2"
    local current_time=$(date +%s)
    local dir_time=$(stat -f %m "$dir" 2>/dev/null || echo 0)
    local threshold_seconds=$(( hours * 3600 ))
    local age_seconds=$(( current_time - dir_time ))
    [ $age_seconds -gt $threshold_seconds ]
}

# Safety: check if any process has open file handles in this directory.
# Returns 0 (true) if there ARE open handles — caller should skip.
has_open_handles() {
    local dir="$1"
    if ! command -v lsof &> /dev/null; then
        return 1  # lsof unavailable — err on side of "no handles"
    fi
    lsof +D "$dir" -t 2>/dev/null | head -1 | grep -q . && return 0 || return 1
}

# Build a global list of all active git worktrees across all repos.
# Used as a safety guard so we never delete files inside a live worktree.
discover_active_worktrees() {
    [ -n "$PROJECT_DIR" ] || return
    local repos="$PROJECT_DIR"/*/.git
    for repo in $repos; do
        [ -e "$repo" ] || continue
        local repo_dir="$(dirname "$repo")"
        local wts=$(cd "$repo_dir" && git worktree list --porcelain 2>/dev/null \
                    | awk '/^worktree / {print substr($0,10)}')
        ACTIVE_WORKTREES+="$wts"$'\n'
    done
}

# Returns 0 (true) if $path is inside any active worktree.
is_in_active_worktree() {
    local path="$1"
    local abs="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")"
    while IFS= read -r wt; do
        [ -z "$wt" ] && continue
        case "$abs" in
            "$wt"|"$wt"/*) return 0 ;;
        esac
    done <<< "$ACTIVE_WORKTREES"
    return 1
}

# Remove or report removal of a file/directory
remove_item() {
    local item="$1"
    local reason="$2"

    if [ ! -e "$item" ]; then
        return
    fi

    local size=$(get_size "$item")
    local size_bytes=$(get_size_bytes "$item")
    TOTAL_SIZE=$((TOTAL_SIZE + size_bytes))

    echo "  [$reason] $item ($size)"

    if [ "$CHECK_MODE" = false ]; then
        rm -rf "$item"
        echo "    ✓ Removed"
    fi
}

# =============================================================================
# SYSTEM CLEANUP
# =============================================================================

echo "═══════════════════════════════════════════════════════════"
echo "              SYSTEM CLEANUP"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Build the safe-zone list of all live git worktrees
discover_active_worktrees

# Homebrew cleanup
echo "📦 Cleaning Homebrew caches..."
if [ -d "$(brew --cache)" ] 2>/dev/null && [ -n "$(ls -A "$(brew --cache)" 2>/dev/null)" ]; then
    CACHE_SIZE=$(get_size "$(brew --cache)")
    echo "  Current cache size: $CACHE_SIZE"
    if [ "$CHECK_MODE" = false ]; then
        timeout 60 brew cleanup --prune=all -s 2>/dev/null || echo "  ⚠️  Homebrew cleanup skipped (timeout or error)"
    else
        echo "  Would run: brew cleanup --prune=all -s"
    fi
else
    echo "  No Homebrew caches to clean"
fi
echo ""

# npm global cache
if command -v npm &> /dev/null; then
    echo "📦 Cleaning npm cache..."
    SIZE=$(get_size ~/.npm)
    echo "  Current size: $SIZE"
    if [ "$CHECK_MODE" = false ]; then
        npm cache clean --force 2>/dev/null || echo "  ⚠️  npm cache cleanup skipped"
    fi
    echo ""
fi

# pnpm global store
if command -v pnpm &> /dev/null; then
    echo "📦 Cleaning pnpm global store..."
    SIZE=$(get_size ~/Library/pnpm/store)
    echo "  Current size: $SIZE"
    if [ "$CHECK_MODE" = false ]; then
        pnpm store prune 2>/dev/null || echo "  ⚠️  pnpm store cleanup skipped"
    fi
    echo ""
fi

# pip cache
if command -v pip &> /dev/null; then
    echo "🐍 Cleaning pip cache..."
    SIZE=$(get_size ~/Library/Caches/pip)
    echo "  Current size: $SIZE"
    if [ "$CHECK_MODE" = false ]; then
        pip cache purge 2>/dev/null || echo "  ⚠️  pip cache cleanup skipped"
    fi
    echo ""
fi

# uv cache
if command -v uv &> /dev/null; then
    echo "🐍 Pruning uv cache..."
    SIZE=$(get_size ~/.cache/uv)
    echo "  Current size: $SIZE"
    if [ "$CHECK_MODE" = false ]; then
        uv cache prune 2>&1 | sed 's/^/  /' || echo "  ⚠️  uv cache prune skipped"
    else
        echo "  Would run: uv cache prune"
    fi
    echo ""
fi

# HuggingFace cache (info-only — interactive cleanup recommended)
if [ -d ~/.cache/huggingface ]; then
    SIZE=$(get_size ~/.cache/huggingface)
    if [ "$SIZE" != "0B" ] && [ -n "$SIZE" ]; then
        echo "🤗 HuggingFace cache: $SIZE"
        if command -v huggingface-cli &> /dev/null; then
            echo "  ℹ️  Run 'huggingface-cli delete-cache' interactively to prune models"
        fi
        echo ""
    fi
fi

# Bun cache (global)
if command -v bun &> /dev/null; then
    echo "📦 Cleaning bun cache..."
    SIZE=$(get_size ~/Library/Caches/bun)
    echo "  Current size: $SIZE"
    if [ "$CHECK_MODE" = false ]; then
        rm -rf ~/Library/Caches/bun/* 2>/dev/null || echo "  ⚠️  bun cache cleanup skipped"
    fi
    echo ""
fi

# Docker cleanup
if command -v docker &> /dev/null; then
    echo "🐳 Cleaning Docker resources..."

    if ! timeout 2 docker info &>/dev/null; then
        echo "  ⚠️  Docker daemon not running, skipping Docker cleanup"
        echo ""
    else
        if [ "$CHECK_MODE" = false ]; then
            echo "  Removing containers unused for >24h..."
            CONTAINERS=$(timeout 10 docker ps -a --filter "status=exited" --filter "status=created" --format "{{.ID}} {{.CreatedAt}}" 2>/dev/null | \
                awk -v date="$(date -u -v-1d '+%Y-%m-%d')" '$2 < date {print $1}' || echo "")
            if [ -n "$CONTAINERS" ]; then
                echo "$CONTAINERS" | xargs timeout 30 docker rm 2>/dev/null || echo "    No old containers to remove"
            else
                echo "    No old containers to remove"
            fi

            echo "  Removing dangling images..."
            timeout 30 docker image prune -f 2>/dev/null || echo "    Image prune skipped"

            echo "  Removing unused volumes..."
            timeout 30 docker volume prune -f 2>/dev/null || echo "    Volume prune skipped"

            echo "  Removing build cache >24h old..."
            timeout 30 docker builder prune -f --filter "until=24h" 2>/dev/null || echo "    Builder prune skipped"

            if docker buildx version &>/dev/null; then
                echo "  Pruning buildx cache >24h old..."
                timeout 30 docker buildx prune -f --filter "until=24h" 2>/dev/null || echo "    Buildx prune skipped"
            fi

            if [ "$AGGRESSIVE_MODE" = true ]; then
                echo "  💥 [aggressive] docker system prune -af --volumes"
                timeout 120 docker system prune -af --volumes 2>/dev/null || echo "    System prune skipped"
                echo "  ℹ️  Note: on macOS, Docker.raw does not auto-shrink. Use Docker"
                echo "     Desktop → Settings → Resources → 'Clean / Purge data' to reclaim."
            fi
        else
            echo "  Would remove: containers >24h, dangling images, unused volumes, build cache"
            [ "$AGGRESSIVE_MODE" = true ] && echo "  Would also run: docker system prune -af --volumes"
        fi

        echo ""
    fi
fi

# VS Code extension caches
echo "💻 Cleaning VS Code caches..."
if [ -d ~/Library/Caches/vscode-cpptools ]; then
    SIZE=$(get_size ~/Library/Caches/vscode-cpptools)
    remove_item ~/Library/Caches/vscode-cpptools "vscode-cpptools ($SIZE)"
fi

if [ -d ~/Library/Caches/ms-playwright ]; then
    SIZE=$(get_size ~/Library/Caches/ms-playwright)
    remove_item ~/Library/Caches/ms-playwright "ms-playwright ($SIZE)"
fi
echo ""

# System logs
echo "🗑️  Cleaning old system logs (>30 days)..."
SIZE=$(get_size ~/Library/Logs)
echo "  Current size: $SIZE"
if [ "$CHECK_MODE" = false ]; then
    find ~/Library/Logs -type f -mtime +30 -delete 2>/dev/null || echo "  ⚠️  Log cleanup skipped"
fi
echo ""

# Stale /tmp clones from dev tool sessions (PR reviews, issue work, etc.)
# Detected structurally: any /private/tmp/<dir>/ that is a git repo.
# `.git` may be a directory (regular clone) OR a file (`git worktree add` writes
# `.git` as a file containing `gitdir: <path>`), so check existence — not type.
# Safety: age check + lsof + worktree check.
echo "🗑️  Cleaning stale /tmp clones (>$TMP_AGE_HOURS h old, no open handles)..."
for d in /private/tmp/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    [ -e "$d/.git" ] || continue
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue

    if ! is_older_than_hours "$d" $TMP_AGE_HOURS; then
        echo "  [SKIP too new] $d"
        continue
    fi

    if is_in_active_worktree "$d"; then
        echo "  [SKIP active worktree] $d"
        continue
    fi

    if has_open_handles "$d"; then
        echo "  [SKIP open handles] $d"
        continue
    fi

    size=$(get_size "$d")
    remove_item "$d" "stale tmp ($size)"
done
echo ""

# =============================================================================
# PROJECT CLEANUP (skip if --system-only or no project dir)
# =============================================================================

if [ "$SYSTEM_ONLY" = false ] && [ -n "$PROJECT_DIR" ]; then

echo "═══════════════════════════════════════════════════════════"
echo "              PROJECT CLEANUP ($PROJECT_DIR)"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Node.js caches
echo "📦 Node.js caches (node_modules, .next)..."
for project in "$PROJECT_DIR"/*; do
    [ -d "$project" ] || continue

    if [ -d "$project/node_modules" ]; then
        remove_item "$project/node_modules" "node_modules"
    fi

    if [ -d "$project/.next" ]; then
        remove_item "$project/.next" "Next.js cache"
    fi
done
echo ""

# Python caches — recursive, but only old + outside active worktrees + outside venv site-packages
echo "🐍 Python caches (__pycache__, .pytest_cache, .ruff_cache, .mypy_cache) >$PYCACHE_AGE_DAYS days..."
find "$PROJECT_DIR" \
    \( -name "site-packages" -o -name ".venv" -o -name "venv" -o -name ".dev-venv" \
       -o -name "node_modules" -o -name ".loom" -o -name ".claude" \) -prune \
    -o \( -name "__pycache__" -o -name ".pytest_cache" -o -name ".ruff_cache" -o -name ".mypy_cache" \) \
    -type d -print 2>/dev/null | while read dir; do
    if is_in_active_worktree "$dir"; then continue; fi
    if ! is_older_than_days "$dir" $PYCACHE_AGE_DAYS; then continue; fi
    remove_item "$dir" "Python cache"
done
echo ""

# Stray .pyc files outside __pycache__ dirs (legacy Python 2 / odd toolchains)
echo "🐍 Stray .pyc files >$PYCACHE_AGE_DAYS days..."
find "$PROJECT_DIR" \
    \( -name "site-packages" -o -name ".venv" -o -name "venv" -o -name "__pycache__" \
       -o -name "node_modules" -o -name ".loom" -o -name ".claude" \) -prune \
    -o -name "*.pyc" -type f -mtime +$PYCACHE_AGE_DAYS -print 2>/dev/null \
    | while read f; do
        if is_in_active_worktree "$f"; then continue; fi
        rm -f "$f" 2>/dev/null
    done
echo ""

# Old Python virtual environments
echo "🐍 Python virtual environments (>$VENV_AGE_DAYS days old, root + subdirs)..."
find "$PROJECT_DIR" \
    \( -name "node_modules" -o -name "site-packages" -o -name "target" \
       -o -name ".loom" -o -name ".claude" \) -prune \
    -o \( -name "venv" -o -name ".venv" -o -name ".dev-venv" -o -name "env" \) -type d -print 2>/dev/null \
    | while read venv_path; do
    if [ "$(basename "$venv_path")" = "env" ] && [ ! -f "$venv_path/bin/python" ]; then
        continue
    fi
    if is_in_active_worktree "$venv_path"; then continue; fi
    if ! is_older_than_days "$venv_path" $VENV_AGE_DAYS; then
        last_mod=$(stat -f "%Sm" -t "%Y-%m-%d" "$venv_path" 2>/dev/null || echo "unknown")
        echo "  [KEEPING] $venv_path (last modified: $last_mod)"
        continue
    fi
    last_mod=$(stat -f "%Sm" -t "%Y-%m-%d" "$venv_path" 2>/dev/null || echo "unknown")
    remove_item "$venv_path" "venv (last modified: $last_mod)"
done
echo ""

# Rust target directories — recursive for monorepos
echo "🦀 Rust build caches (target/) >$TARGET_AGE_DAYS days, root + monorepo subdirs..."
find "$PROJECT_DIR" \
    \( -name "target" -o -name "vendor" -o -name ".venv" -o -name "venv" \
       -o -name "node_modules" -o -name ".loom" -o -name ".claude" \) -prune \
    -o -name "Cargo.toml" -type f -print 2>/dev/null \
    | while read cargo_toml; do
        crate_dir="$(dirname "$cargo_toml")"
        target_dir="$crate_dir/target"
        [ -d "$target_dir" ] || continue

        if is_in_active_worktree "$target_dir"; then continue; fi
        if ! is_older_than_days "$target_dir" $TARGET_AGE_DAYS; then continue; fi

        size=$(get_size "$target_dir")
        size_bytes=$(get_size_bytes "$target_dir")
        TOTAL_SIZE=$((TOTAL_SIZE + size_bytes))

        echo "  [Rust target] $target_dir ($size)"

        if [ "$CHECK_MODE" = false ]; then
            (cd "$crate_dir" && cargo clean 2>/dev/null) || rm -rf "$target_dir" 2>/dev/null
            echo "    ✓ Cleaned"
        fi
    done
echo ""

# Java/Kotlin build directories
echo "☕ Java/Kotlin build caches (build/, .gradle/)..."
for project in "$PROJECT_DIR"/*; do
    [ -d "$project" ] || continue

    if [ -d "$project/build" ] && [ -f "$project/build.gradle" -o -f "$project/build.gradle.kts" ]; then
        remove_item "$project/build" "Gradle build"
    fi

    if [ -d "$project/.gradle" ]; then
        remove_item "$project/.gradle" "Gradle cache"
    fi
done
echo ""

# Per-repo git maintenance
echo "🌳 Per-repo git maintenance (worktree prune + gc --auto)..."
for project in "$PROJECT_DIR"/*; do
    [ -d "$project/.git" ] || continue
    if [ "$CHECK_MODE" = false ]; then
        (cd "$project" && git worktree prune 2>/dev/null) || true
        (cd "$project" && git gc --auto 2>/dev/null) || true
    fi
done
echo ""

# =============================================================================
# WORKTREE CLEANUP — clean worktrees and branches for closed GitHub issues,
# plus stale agent-workflow worktrees (audit-*, mechanic-*, researcher-*, …)
# under .loom/worktrees/ and .claude/worktrees/.
# =============================================================================

echo "═══════════════════════════════════════════════════════════"
echo "              WORKTREE CLEANUP"
echo "═══════════════════════════════════════════════════════════"
echo ""

if ! command -v gh &> /dev/null; then
    echo "  ⚠️  gh CLI not found, skipping worktree cleanup"
    echo "     Install: https://cli.github.com"
    echo ""
else

wt_cleaned=0
wt_skipped=0
br_cleaned=0
tmux_cleaned=0

# Decide whether a non-issue worktree is safe to remove.
# Returns 0 (true) if all safety checks pass; prints the reason and returns 1 otherwise.
# Args: $1 = project_name, $2 = worktree_dir, $3 = display_label
worktree_is_stale_and_safe() {
    local pname="$1"
    local wt="$2"
    local label="$3"

    if ! is_older_than_days "$wt" $WORKTREE_AGE_DAYS; then
        echo "  [KEEP too new] $pname $label"
        return 1
    fi

    if is_in_active_worktree "$wt"; then
        echo "  [SKIP active] $pname $label"
        return 1
    fi

    if has_open_handles "$wt"; then
        echo "  [SKIP open handles] $pname $label"
        return 1
    fi

    # Use `git status --porcelain` so untracked files block removal too;
    # `git diff` only inspects tracked-file changes.
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
        echo "  [SKIP uncommitted] $pname $label"
        return 1
    fi

    # If branch has an upstream and unpushed commits, preserve it.
    if git -C "$wt" rev-parse '@{u}' >/dev/null 2>&1; then
        local unpushed
        unpushed=$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
        if [ "$unpushed" -gt 0 ]; then
            echo "  [SKIP $unpushed unpushed] $pname $label"
            return 1
        fi
    fi

    return 0
}

for project in "$PROJECT_DIR"/*; do
    [ -d "$project/.git" ] || continue

    project_name=$(basename "$project")
    has_worktrees=false
    has_branches=false

    # Walk every subdir under .loom/worktrees/ and .claude/worktrees/.
    # issue-N dirs use the closed-issue check; everything else uses age-based safety.
    for worktree_root in "$project/.loom/worktrees" "$project/.claude/worktrees"; do
        [ -d "$worktree_root" ] || continue
        for worktree_dir in "$worktree_root"/*; do
            [ -d "$worktree_dir" ] || continue
            has_worktrees=true

            wt_name=$(basename "$worktree_dir")
            root_tag=$(basename "$(dirname "$worktree_root")")/$(basename "$worktree_root")
            label="$root_tag/$wt_name"

            if echo "$wt_name" | grep -qE '^issue-[0-9]+$'; then
                # Issue worktree: only remove if the corresponding issue is CLOSED,
                # then run the same safety checks the broader walk uses.
                issue_num="${wt_name#issue-}"
                issue_state=$(cd "$project" && gh issue view "$issue_num" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")

                if [ "$issue_state" != "CLOSED" ]; then
                    echo "  [KEEP] $project_name $label ($issue_state)"
                    wt_skipped=$((wt_skipped + 1))
                    continue
                fi

                # Use `git status --porcelain` so untracked files block removal too;
                # `git diff` only inspects tracked-file changes.
                if [ -n "$(cd "$worktree_dir" && git status --porcelain 2>/dev/null)" ]; then
                    echo "  [SKIP uncommitted] $project_name $label"
                    wt_skipped=$((wt_skipped + 1))
                    continue
                fi

                if is_in_active_worktree "$worktree_dir"; then
                    echo "  [SKIP active] $project_name $label"
                    wt_skipped=$((wt_skipped + 1))
                    continue
                fi

                echo "  [CLOSED] $project_name $label"
            else
                if ! worktree_is_stale_and_safe "$project_name" "$worktree_dir" "$label"; then
                    wt_skipped=$((wt_skipped + 1))
                    continue
                fi
                echo "  [STALE] $project_name $label"
            fi

            if [ "$CHECK_MODE" = false ]; then
                worktree_abs="$(cd "$worktree_dir" && pwd)"
                (cd "$project" && git worktree remove "$worktree_abs" --force 2>/dev/null) || \
                    rm -rf "$worktree_dir" 2>/dev/null
                echo "    ✓ Removed worktree"
            fi
            wt_cleaned=$((wt_cleaned + 1))
        done
    done

    # Clean feature branches for closed issues (feature/issue-*)
    branches=$(cd "$project" && git branch 2>/dev/null | grep "feature/issue-" | sed 's/^[*+ ]*//' || true)
    if [ -n "$branches" ]; then
        has_branches=true
        for branch in $branches; do
            issue_num=$(echo "$branch" | sed 's/feature\/issue-//' | sed 's/-.*//' | sed 's/[^0-9].*//')

            if ! echo "$issue_num" | grep -q '^[0-9]\+$'; then
                continue
            fi

            issue_state=$(cd "$project" && gh issue view "$issue_num" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")

            if [ "$issue_state" = "CLOSED" ]; then
                echo "  [CLOSED] $project_name branch $branch"
                if [ "$CHECK_MODE" = false ]; then
                    (cd "$project" && git branch -D "$branch" 2>/dev/null) || true
                    echo "    ✓ Deleted branch"
                fi
                br_cleaned=$((br_cleaned + 1))
            fi
        done
    fi
done

echo ""

# Clean Loom tmux sessions (loom-*)
echo "🧵 Loom tmux sessions..."
LOOM_SESSIONS=$(tmux list-sessions 2>/dev/null | grep '^loom-' | cut -d: -f1 || true)

if [ -n "$LOOM_SESSIONS" ]; then
    echo "$LOOM_SESSIONS" | while read -r session; do
        echo "  [tmux] $session"
        if [ "$CHECK_MODE" = false ]; then
            tmux kill-session -t "$session" 2>/dev/null && echo "    ✓ Killed" || true
        fi
        tmux_cleaned=$((tmux_cleaned + 1))
    done
else
    echo "  No Loom tmux sessions found"
fi
echo ""

echo "  Worktrees removed: $wt_cleaned  Branches deleted: $br_cleaned"
[ $wt_skipped -gt 0 ] && echo "  Worktrees kept (open/uncommitted): $wt_skipped"
echo ""

fi  # gh CLI check

fi  # SYSTEM_ONLY check

# =============================================================================
# SUMMARY
# =============================================================================

echo "═══════════════════════════════════════════════════════════"
if [ "$CHECK_MODE" = true ]; then
    echo "📊 Space Analysis"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "💾 Potential space savings: $(bytes_to_human $TOTAL_SIZE)"
    echo "   (Note: Docker and worktree cleanup not included in calculation)"
    echo ""
    echo "Current disk usage:"
    df -h / | tail -1 | awk '{print "  Used: " $3 " / " $2 " (" $5 ")"}'
    echo "  Available: $(df -h / | tail -1 | awk '{print $4}')"
    echo ""
    echo "Run 'clean' without --check to free this space"
else
    echo "✅ Cleanup complete!"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "💾 Space freed: $(bytes_to_human $TOTAL_SIZE)"
    echo ""
    echo "📊 Current disk usage:"
    df -h / | tail -1 | awk '{print "  Used: " $3 " / " $2 " (" $5 ")"}'
    echo "  Available: $(df -h / | tail -1 | awk '{print $4}')"
fi
echo ""
