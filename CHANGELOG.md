# Changelog

All notable changes to `clean` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
