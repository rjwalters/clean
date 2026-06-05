# clean

Aggressive but safe disk cleanup for macOS developer machines. Designed for developers who work with lots of git worktrees.

Cleans system caches, Docker resources, per-project build artifacts, and stale worktrees/branches for closed GitHub issues — with multiple safety nets to prevent data loss.

## What it cleans

**System-level:**
- Homebrew, npm, pnpm, pip, bun, uv caches
- HuggingFace cache (info only — interactive cleanup recommended)
- Docker (containers >24h, dangling images, unused volumes, build cache)
- VS Code extension caches
- System logs >30 days old
- Stale `/tmp` clones from dev tools (PR reviews, issue work)

**Per-project (auto-detected):**
- `node_modules`, `.next`
- Python caches (`__pycache__`, `.pytest_cache`, `.ruff_cache`, `.mypy_cache`) >14 days
- Python virtualenvs (`venv`, `.venv`) >7 days
- Rust `target/` directories >7 days
- Java/Kotlin `build/`, `.gradle/`
- Git maintenance (`gc --auto`, `worktree prune`)

**Worktree cleanup (requires [gh CLI](https://cli.github.com)):**
- Removes worktrees for closed GitHub issues (`.loom/worktrees/issue-*`)
- Deletes local feature branches for closed issues (`feature/issue-*`)
- Kills stale Loom tmux sessions (`loom-*`)

## Safety nets

1. **Age thresholds** — never deletes files modified within N days (configurable)
2. **Open-handle check** (`lsof`) — skips directories with active processes
3. **Active worktree check** — never touches files inside live git worktrees
4. **GitHub issue check** — only cleans worktrees/branches for CLOSED issues
5. **Uncommitted changes** — skips worktrees with uncommitted work
6. **Tool-native commands** — uses `cargo clean`, `uv cache prune`, etc. over `rm -rf`
7. **Pattern matching** — only known cache/temp patterns, never source code

## Install

```bash
git clone https://github.com/rjwalters/clean.git ~/GitHub/clean
cd ~/GitHub/clean
./install.sh
```

The installer symlinks `clean` into `/usr/local/bin` (or `~/.local/bin` if that's not writable). Re-run `./install.sh` anytime to repair or move the install — it's idempotent.

To update, just `git pull` in the repo. The symlink keeps pointing at the live script, so no reinstall is needed.

To uninstall: `./install.sh --uninstall`.

## Usage

```bash
clean              # Run cleanup
clean --check      # Preview what would be cleaned (dry run)
clean --aggressive # Also run 'docker system prune -af --volumes'
clean --system-only # Skip per-project cleanup
clean --help       # Show detailed help
```

## Project directory

The script auto-detects your project directory by checking (in order):

1. `CLEAN_PROJECT_DIR` environment variable
2. `~/GitHub`
3. `~/Projects`
4. `~/repos`
5. `~/src`

Override with:
```bash
CLEAN_PROJECT_DIR=~/code clean
```

## Configuration

Edit the variables at the top of `cleanup.sh`:

| Variable | Default | Description |
|---|---|---|
| `VENV_AGE_DAYS` | `7` | Min age before cleaning virtualenvs |
| `TMP_AGE_HOURS` | `1` | Min age before cleaning /tmp clones |
| `PYCACHE_AGE_DAYS` | `14` | Min age before cleaning Python caches |
| `TARGET_AGE_DAYS` | `7` | Min age before cleaning Rust target dirs |

## Worktree workflow

This tool is built for workflows that use git worktrees for issue-based development (e.g., [Loom](https://github.com/rjwalters/loom)). The worktree cleanup section:

- Scans each repo for `.loom/worktrees/issue-*` directories
- Checks the corresponding GitHub issue status via `gh issue view`
- Only removes worktrees where the issue is **CLOSED**
- Skips worktrees with uncommitted changes
- Cleans up orphaned `feature/issue-*` branches for closed issues

## Requirements

- **macOS** (uses `stat -f`, `~/Library` paths, macOS `date` flags)
- **gh CLI** (optional, for worktree/branch cleanup)

## License

MIT
