# Changelog

All notable changes to `clean` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-07-08

Stops every known path by which `clean` could delete active work-in-progress
(observed repeatedly against lean-genius agent worktrees, which drove agents to
park worktrees under `$HOME` where no janitor manages them).

### Fixed

- **Staleness is now recursive activity, not root-dir mtime** — a directory's
  own mtime only changes when a direct child is added/removed/renamed, so a
  worktree being actively edited deep in its tree looked "stale" once the root
  dir passed the age threshold. Both the worktree pass (`WORKTREE_AGE_DAYS`)
  and the `/tmp` clone pass (`TMP_AGE_HOURS`) now use `find -mtime/-mmin
  -print -quit` over the whole tree (including `.git`, so commits/fetches count
  as activity).
- **`/tmp` clone cleanup now runs WIP checks** — previously a 1-hour-old
  scratch clone/worktree was `rm -rf`'d with **no** uncommitted/unpushed check
  at all. It now keeps anything with uncommitted/untracked files or commits not
  on a remote, and removes registered worktrees via `git worktree remove`
  (parent repo metadata stays consistent) instead of `rm -rf`.
- **Unpushed detection no longer requires an upstream** — a branch with
  local-only commits and no upstream configured (the standard agent-worktree
  state) previously skipped the unpushed check entirely and was deleted. With
  no upstream, HEAD must now be reachable from some remote ref, else the
  worktree is preserved.
- **No more `git worktree remove --force … || rm -rf` fallback** — if git
  refuses the removal (e.g. files appeared between our safety checks and the
  removal), the worktree is left in place for a future run instead of being
  force-deleted. Plain `rm -rf` is reserved for dirs that are not registered
  worktrees and have already passed the WIP checks; dirs that are not git
  trees at all (residue of a lost worktree registration) are always preserved
  and reported.
- **Active-worktree guard is symlink-safe** — worktree paths and candidate
  paths are normalized with `pwd -P`, so `/tmp` vs `/private/tmp` aliasing can
  no longer defeat the guard.
- **Unstatable dirs are kept, not deleted** — `is_older_than_days/hours`
  treated a failed `stat` as "infinitely old" (eligible for deletion); they now
  err on the side of keeping.
- **In-repo worktree cleanup was inert** — the `is_in_active_worktree` gate
  matched the main checkout's path prefix for every `.loom/worktrees/*` /
  `.claude/worktrees/*` candidate (they live inside the main checkout), so the
  pass never removed anything. The gate is replaced by the real protections
  (recursive activity + open handles + WIP), and the closed-issue path gains
  the same open-handle and unpushed guards.

## [0.2.0] - 2026-06-16

### Added

- **Broader worktree cleanup** (#1) — `.loom/worktrees/` and `.claude/worktrees/` are now both walked, every subdir (not just `issue-*`). Non-issue agent worktrees (`audit-*`, `mechanic-*`, `researcher-*`, `agent-*`, …) are removed once they're older than `WORKTREE_AGE_DAYS` (default 14) and have no uncommitted changes, no unpushed commits, no live process, and aren't inside an active worktree. Existing `issue-N` CLOSED-issue logic is preserved.
- **Structural `/tmp` clone detection** (#1) — replaces the fixed `pr-*`/`issue-*` name list with "any `/private/tmp/<dir>/` that is a git repo", so `<repo-name>-<number>` / `<repo-name>-<descriptor>` clones from `gh pr checkout`-style tooling are cleaned without enumerating naming schemes. Handles `.git` as either a directory (regular clone) or a file (`git worktree add`).

### Fixed

- **Worktree safety check now catches untracked files** (#4) — both worktree safety gates (`worktree_is_stale_and_safe` and the issue-`N` CLOSED-issue branch) replaced their `git diff --quiet` + `git diff --cached --quiet` pair with a single `git status --porcelain` empty check. The previous gate inspected only tracked-file changes, so an orphan worktree whose only contents were untracked files (e.g. an agent's `notes.md`, a scratch `.py`, an unstaged `.env`) silently passed safety and was removed. The new gate preserves any worktree with any reportable state (untracked, modified, staged, renamed). Default `--porcelain` excludes `.gitignore`-matched paths, so `node_modules`-style caches still flow through normal aging.

## [0.1.0] - 2026-06-05

Initial tagged release.

### Added

- **System cleanup** — Homebrew, npm, pnpm, pip, bun, uv caches; HuggingFace cache info; Docker (containers >24h, dangling images, unused volumes, build cache, optional full prune via `-a`); VS Code extension caches; system logs >30 days; stale `/tmp` clones >1h with `lsof` open-handle check.
- **Per-project cleanup** — recursive sweep of `node_modules`, `.next`, Python caches (`__pycache__`, `.pytest_cache`, `.ruff_cache`, `.mypy_cache`) >14 days, stray `.pyc` files, Python venvs (`venv`, `.venv`, `.dev-venv`, `env`) >7 days, Rust `target/` dirs >7 days (via `cargo clean` where possible), Java/Kotlin `build/` and `.gradle/`, plus per-repo `git worktree prune` + `git gc --auto`.
- **Worktree cleanup** — removes worktrees and `feature/issue-*` branches for GitHub issues in `CLOSED` state, plus Loom tmux sessions (`loom-*`). Requires `gh` CLI.
- **Safety nets** — age thresholds, `lsof` open-handle check, active-worktree guard so files inside live worktrees are never touched, GitHub issue-state check before removing worktrees, tool-native cleanup commands preferred over `rm -rf`.
- **Flags** — `--check`/`-c` (dry run), `--aggressive`/`-a` (Docker full prune), `--system-only` (skip project sweep), `--version`/`-V`, `--help`/`-h`.
- **Project-dir auto-detection** — `CLEAN_PROJECT_DIR` env var, else first existing of `~/GitHub`, `~/Projects`, `~/repos`, `~/src`.
- **Installer** — `install.sh` symlinks `clean` into `/usr/local/bin` (or `~/.local/bin` fallback), idempotent, with `--uninstall` and `--force` modes.
- **Release tooling** — `scripts/version.sh` for `show`/`check`/`bump`/`set` with `--tag` mode that commits and creates an annotated git tag.

### Fixed

- Project `find` walks now prune `.loom/worktrees` and `.claude/worktrees` and use `-name`-based prune patterns (vs. `-path "*/.../*"`, which only fired after descending one level). Previously, running `clean` against `~/GitHub` containing a repo with hundreds of agent/loom worktrees would appear to hang at the Python stage as `find` traversed every worktree copy four times.
