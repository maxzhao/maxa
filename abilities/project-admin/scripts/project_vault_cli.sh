#!/bin/bash
# Shared project-target plumbing for Obsidian shell entrypoints; source only.

resolve_project_vault() {
    local selected="${1:-$PWD}"
    if [[ ! -d "$selected" ]]; then
        echo "ERROR: Project directory does not exist: $selected" >&2
        return 2
    fi
    # Reject the Vault symlink before canonicalization can erase its checkout.
    if [[ "$(basename "$selected")" == .maxa ]]; then
        if [[ -L "${selected%/}" ]]; then
            echo "ERROR: A whole-Vault .maxa symlink is not a project-local Vault" >&2
            return 2
        fi
        selected="$(dirname "$selected")"
    fi
    selected="$(cd "$selected" && pwd -P)"
    if [[ ! -d "$selected/.maxa" || -L "$selected/.maxa" ]]; then
        echo "ERROR: Expected the selected project's own .maxa directory" >&2
        return 2
    fi
    PROJECT_ROOT="$selected"
    VAULT="$PROJECT_ROOT/.maxa"
    PROJECT_ADMIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
}

project_vault() {
    uv run --project "$PROJECT_ADMIN_ROOT" python \
        "$PROJECT_ADMIN_ROOT/scripts/project_knowledge_vault.py" \
        --project-root "$PROJECT_ROOT" "$@"
}
