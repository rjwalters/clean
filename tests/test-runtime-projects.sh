#!/bin/bash
# test-runtime-projects.sh — runtime-project detection: MCP configs, linked
# CLIs, keepBuildArtifacts and CLEAN_KEEP_PROJECTS protect a project's
# artifacts; trusted-project lists and unrelated paths do not.
#
#   bash tests/test-runtime-projects.sh
#
# Hermetic: a throwaway HOME and project dir; only the detection functions are
# loaded from cleanup.sh, so nothing on this machine is scanned or removed.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

eval "$(sed -n '/^RUNTIME_PROJECTS=""/,/^# Remove or report removal/p' "$HERE/cleanup.sh")"

HOME="$TMP/home"
PROJECT_DIR="$TMP/GitHub"
mkdir -p "$HOME/.codex" "$HOME/.local/bin" "$PROJECT_DIR"
for p in squad loomish codexsrv desktopsrv linkedcli keeper envkeep plain trusted relsrv; do
    mkdir -p "$PROJECT_DIR/$p/node_modules" "$PROJECT_DIR/$p/dist"
done
R="$(cd "$PROJECT_DIR" && pwd -P)"

# ~/.claude.json: a user server (absolute path) and a per-project server; the
# "projects" keys themselves must NOT count.
cat > "$HOME/.claude.json" <<JSON
{"mcpServers": {"loom": {"command": "node", "args": ["$R/loomish/dist/index.js"]}},
 "projects": {"$R/trusted": {"allowedTools": []},
              "$R/plain": {"mcpServers": {"x": {"command": "node", "args": ["../relsrv/dist/index.js"]}}}}}
JSON
# A project .mcp.json with the runtime in an env var, relative to the project.
mkdir -p "$PROJECT_DIR/loomui"
cat > "$PROJECT_DIR/loomui/.mcp.json" <<'JSON'
{"mcpServers": {"squad": {"command": "node", "args": [".claude/hooks/squad-mcp.mjs"],
                          "env": {"SQUAD_RUNTIME": "../squad/dist/index.js"}}}}
JSON
# Codex: an mcp_servers table plus a trusted-projects table that must not count.
cat > "$HOME/.codex/config.toml" <<TOML
[projects."$R/trusted"]
trust_level = "trusted"

[mcp_servers.codexsrv]
command = "node"
args = ["$R/codexsrv/dist/index.js"]
TOML
mkdir -p "$HOME/Library/Application Support/Claude"
cat > "$HOME/Library/Application Support/Claude/claude_desktop_config.json" <<JSON
{"mcpServers": {"d": {"command": "$R/desktopsrv/dist/server"}}}
JSON
ln -s "$PROJECT_DIR/linkedcli/dist/cli.js" "$HOME/.local/bin/linkedcli"
mkdir -p "$PROJECT_DIR/keeper/.loom-local"
echo '{"clean": {"keepBuildArtifacts": true}}' > "$PROJECT_DIR/keeper/.loom-local/fleet-repo.json"
CLEAN_KEEP_PROJECTS="envkeep"

expect() {
    if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 (got '$2', want '$3')"; FAILS=$((FAILS+1)); fi
}
why() { runtime_project_reason "$PROJECT_DIR/$1" || echo "-"; }

discover_runtime_projects
expect "user MCP server in ~/.claude.json"          "$(why loomish)"    mcp
expect "env var path in a project .mcp.json"        "$(why squad)"      mcp
expect "per-project server resolves vs its project" "$(why relsrv)"     mcp
expect "Codex mcp_servers table"                    "$(why codexsrv)"   mcp
expect "Claude Desktop config"                      "$(why desktopsrv)" mcp
expect "CLI linked into ~/.local/bin"               "$(why linkedcli)"  linked
expect "Loom keepBuildArtifacts"                    "$(why keeper)"     keepBuildArtifacts
expect "CLEAN_KEEP_PROJECTS"                        "$(why envkeep)"    CLEAN_KEEP_PROJECTS
expect "a trusted/opened project is not a runtime"  "$(why trusted)"    -
expect "a project hosting a config is not one"      "$(why plain)"      -
expect "nested artifact maps to its project"        "$(runtime_project_reason "$PROJECT_DIR/codexsrv/sub/target" || echo -)" mcp

# Without python3 the JSON configs fall back to a string scan, except
# ~/.claude.json (it names every project ever opened).
RUNTIME_PROJECTS=""
python3() { return 127; }
discover_runtime_projects
expect "no python3: .mcp.json still scanned"        "$(why squad)"      mcp
expect "no python3: ~/.claude.json skipped"         "$(why loomish)"    -
expect "no python3: Codex still scanned"            "$(why codexsrv)"   mcp
unset -f python3

echo
echo "$FAILS failure(s)"
[ "$FAILS" -eq 0 ]
