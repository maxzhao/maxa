#!/bin/bash
# Project-local note neighborhood through verified ProjectAdmin dispatch.
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    cat <<'EOF'
graph_neighbors.sh [--project-root PROJECT_ROOT] <note-name>

Run from the project root or its .maxa directory, or select a project explicitly.
Only a verified primary checkout or independent non-Git project may use Obsidian.
Registration must already exist; linked Worktrees use file tools instead.
Failure to verify the target or either graph query returns non-zero; no fallback Vault.
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/project_vault_cli.sh"
SELECTED="$PWD"
if [[ "${1:-}" == --project-root ]]; then
    SELECTED="${2:?Missing project root}"
    shift 2
fi
[[ $# == 1 ]] || { echo "ERROR: Expected exactly one note name" >&2; exit 2; }
resolve_project_vault "$SELECTED"
NOTE="$1"
printf '=== Link Neighborhood: %s ===\n\n--- Outgoing Links ---\n' "$NOTE"
project_vault exec -- links "file=$NOTE"
printf '\n--- Incoming Links (Backlinks) ---\n'
project_vault exec -- backlinks "file=$NOTE"
