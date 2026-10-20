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
- Stale `/tmp` clones from dev tools (PR reviews, issue work) — only when idle,
  with no open handles and no uncommitted/unpushed work

**Per-project (auto-detected):**
- `node_modules`, `.next` — only when the project itself has been idle >7 days
- Python caches (`__pycache__`, `.pytest_cache`, `.ruff_cache`, `.mypy_cache`) >14 days
- Python virtualenvs (`venv`, `.venv`) >7 days
- Rust `target/` directories >7 days
- Java/Kotlin `build/`, `.gradle/`
- Git maintenance (`gc --auto`, `worktree prune`)

**Worktree cleanup (requires [gh CLI](https://cli.github.com)):**
- Removes worktrees for closed GitHub issues (`.loom/worktrees/issue-*`, `.claude/worktrees/issue-*`)
- Removes stale agent-workflow worktrees (everything else under those roots) once
  idle >14 days with no WIP
- Deletes local feature branches for closed issues (`feature/issue-*`)
- Kills stale Loom tmux sessions (`loom-*`)

## Safety nets

1. **Age thresholds** — never deletes trees with recent activity. Recursive for
   git trees: an edit *anywhere* in the tree counts, not just the root dir's mtime. For
   `node_modules`/`.next` the age test is applied to the **project**, not to the
   artifact: a `node_modules` installed months ago and built against hourly is
   in use, and its own mtime cannot tell you that
2. **Open-handle check** (`lsof`) — skips directories with active processes
3. **Active worktree check** — never touches files inside live git worktrees
   (symlink-safe, so `/tmp` vs `/private/tmp` aliasing can't defeat it)
4. **WIP check** — never deletes uncommitted/untracked files or commits that no
   remote ref contains, including on branches with no upstream configured
5. **GitHub issue check** — only cleans issue worktrees/branches for CLOSED issues
6. **Tool-native commands** — uses `cargo clean`, `uv cache prune`, etc. over `rm -rf`;
   registered worktrees are removed via `git worktree remove` (no `--force`, no
   `rm -rf` fallback), so git can veto if state changed since the safety checks
7. **Pattern matching** — only known cache/temp patterns, never source code
8. **Runtime projects** — a project that another program runs in place keeps
   its `node_modules`, `target/`, venvs and `build/` whatever their age. That
   covers MCP servers named in `~/.claude.json` (user and per-project),
   every project's `.mcp.json`, Claude Desktop, Cursor and Codex
   `[mcp_servers.*]`; CLIs symlinked into `~/.local/bin`, `~/bin`,
   Homebrew's `bin` or the global `node_modules` (`npm link`); and workspaces
   that set Loom's `clean.keepBuildArtifacts`. Neither the age test nor `lsof`
   can see this dependency: a running MCP server holds no open handle on
   modules it has already loaded. Add others with `CLEAN_KEEP_PROJECTS`

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
clean --check      # Preview what would be cleaned (dry run); short form -c (-a for --aggressive)
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
| `NODE_MODULES_AGE_DAYS` | `7` | Min idle time (recursive, of the **project**) before cleaning `node_modules`/`.next` |
| `TMP_AGE_HOURS` | `1` | Min idle time (recursive) before cleaning /tmp clones |
| `WORKTREE_AGE_DAYS` | `14` | Min idle time (recursive) before cleaning agent worktrees |
| `PYCACHE_AGE_DAYS` | `14` | Min age before cleaning Python caches |
| `TARGET_AGE_DAYS` | `7` | Min age before cleaning Rust target dirs |

To keep a project's artifacts that detection misses, set
`CLEAN_KEEP_PROJECTS=name1:name2` (top-level names under the project
directory). Each run lists the runtime projects it found and why, under
"Runtime projects".

Tests: `bash tests/test-runtime-projects.sh` (hermetic: throwaway `HOME` and
project dir).

## Worktree workflow

This tool is built for workflows that use git worktrees for issue-based development (e.g., [Loom](https://github.com/rjwalters/loom)). The worktree cleanup section:

- Scans each repo's `.loom/worktrees/` and `.claude/worktrees/` directories
- For `issue-N` worktrees: checks the GitHub issue via `gh issue view` and only
  removes worktrees where the issue is **CLOSED**
- For everything else (agent scratch worktrees): only removes after
  `WORKTREE_AGE_DAYS` of no activity anywhere in the tree
- Always keeps worktrees with uncommitted changes or commits not on any remote
  (even when the branch has no upstream), or with a live process inside
- Directories that aren't git trees at all are reported and never deleted
  (they may be residue of a lost worktree registration)
- Cleans up orphaned `feature/issue-*` branches for closed issues

## Requirements

- **macOS** (uses `stat -f`, `~/Library` paths, macOS `date` flags)
- **gh CLI** (optional, for worktree/branch cleanup)

## License

MIT
