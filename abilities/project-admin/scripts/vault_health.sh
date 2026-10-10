#!/bin/bash
# Vault health check: comprehensive integrity verification
# Usage: vault_health.sh [--quick]
#   --quick: skip Obsidian CLI checks (when Obsidian is not running)
#
# Checks: unresolved links, orphan knowledge notes, semantic naming rules,
#          frontmatter completeness, Markdown size limit, TODO/confidence metrics, tag distribution.
# Exit code = number of issues found (0 = healthy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
vault_health.sh

Usage:
  vault_health.sh [--project-root PROJECT_ROOT] [--quick]
  vault_health.sh --help

Target and coverage:
  - Run from a project root or its .maxa directory, or pass --project-root.
  - Linked Worktrees automatically use file-only checks; no external service contact.
  - --quick is file-only everywhere and does not require Vault registration.
  - Eligible live checks use verified ProjectAdmin dispatch; failure returns non-zero.

常用场景:
  1. 做一次完整 vault 体检
  2. Obsidian CLI 不可用时，用 --quick 看文件侧问题
  3. 在知识库整理、重命名、批量修改后做回归检查

输出内容:
  - unresolved links
  - orphan knowledge notes (graph isolation is not entry-chain reachability)
  - semantic naming：文件名应为英文/ASCII slug，title 应为中文或中英混合语义标题
  - frontmatter 完整性（项目本地 Vault 的 specs/* 可使用 doc_role/authority/status schema）
  - 完整 UTF-8 文档大小：普通 note ≤ 30000 bytes；weave index ≤ 2048、concept ≤ 3072、topic/log ≤ 6144 bytes
  - TODO / confidence 指标
  - tag 分布

项目本地 Vault 默认排除:
  - .stversions/、.obsidian/、.trash/、.git/
  - inbox/feedback/、attachments/、canvases/、runtime/workspace zones
  - 根目录 plan.md（用户维护的项目规划保留文件）

退出码:
  0 表示未发现问题；非 0 表示问题数量
EOF
  exit 0
fi

source "$SCRIPT_DIR/project_vault_cli.sh"
SELECTED="$PWD"
QUICK=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick) QUICK=true; shift ;;
        --project-root) SELECTED="${2:?Missing project root}"; shift 2 ;;
        *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
    esac
done
resolve_project_vault "$SELECTED"
WARNINGS=0
COVERAGE="file-only (--quick)"
SKIP_REASON="Skipped (--quick mode)"
if ! $QUICK; then
    STATUS=$(project_vault status) || exit 2
    KIND=$(printf '%s' "$STATUS" | uv run --project "$PROJECT_ADMIN_ROOT" python -c 'import json,sys; print(json.load(sys.stdin)["checkout_kind"])')
    case "$KIND" in
        linked)
            QUICK=true
            COVERAGE="file-only (linked Worktree policy)"
            SKIP_REASON="Unavailable by ownership policy; file-side checks only"
            ;;
        unresolved)
            QUICK=true
            COVERAGE="file-only (external checks blocked: unresolved ownership)"
            SKIP_REASON="Blocked: unresolved ownership"
            WARNINGS=$((WARNINGS + 1))
            ;;
        primary|standalone) COVERAGE="file and verified live graph" ;;
        *) echo "ERROR: Invalid ownership status" >&2; exit 2 ;;
    esac
fi

# Project-local Vaults may contain Syncthing history, Obsidian plugin docs,
# and user-maintained planning files outside ordinary knowledge ownership.
IS_PROJECT_LOCAL=false
if [[ "$VAULT" == */.maxa ]]; then
    IS_PROJECT_LOCAL=true
fi

echo "=== Vault Health Report ==="
echo "Date: $(date '+%Y-%m-%d %H:%M')"
echo ""

# Collect knowledge files (excluding evidence/workspaces, structural files and sync/plugin noise).
FIND_EXCLUDES=(
    -not -path '*/.obsidian/*'
    -not -path '*/.stversions/*'
    -not -path '*/.trash/*'
    -not -path '*/.git/*'
    -not -path '*/attachments/*'
    -not -path '*/canvases/*'
    -not -path '*/tasks/*'
    -not -path '*/drafts/*'
    -not -path '*/translate-cache/*'
    -not -path '*/abilities/*'
    -not -path '*/fragments/*'
    -not -path '*/tmp/*'
    -not -path '*/history/*'
    -not -path '*/artifacts/*'
    -not -path '*/handoff/*'
    -not -path '*/e2e/*'
    -not -path '*/inbox/feedback/*'
    -not -name 'index.md'
    -not -name 'log.md'
    -not -name 'README.md'
)
if $IS_PROJECT_LOCAL; then
    FIND_EXCLUDES+=( -not -path "$VAULT/plan.md" )
fi
mapfile -t NOTE_FILES < <(find "$VAULT" -name '*.md' "${FIND_EXCLUDES[@]}" 2>/dev/null | sort)

# ─── 1. Unresolved Links ───────────────────────────────
echo "--- [1] Unresolved Links ---"
if ! $QUICK; then
if UNRESOLVED=$(project_vault exec -- unresolved); then
        # Filter out CLI status messages (e.g., "No unresolved links found.")
        UNRESOLVED=$(echo "$UNRESOLVED" | grep -v '^No unresolved' | grep -v '^\s*$' || true)
        if [ -n "$UNRESOLVED" ]; then
            while IFS= read -r link; do
                echo "  ❌ [[$link]]"
            done <<< "$UNRESOLVED"
            COUNT=$(echo "$UNRESOLVED" | wc -l)
            echo "⚠️  $COUNT unresolved link(s)"
            WARNINGS=$((WARNINGS + COUNT))
        else
            echo "  ✅ None"
        fi
    else
        echo "  ❌ Live graph check failed; no fallback Vault"
        WARNINGS=$((WARNINGS + 1))
        COVERAGE="file-side plus incomplete live checks"
    fi
else
    echo "  ⏭️  $SKIP_REASON"
fi
echo ""

# ─── 2. Orphan Notes ──────────────────────────────────
echo "--- [2] Orphan Knowledge Notes ---"
if ! $QUICK; then
if ALL_ORPHANS=$(project_vault exec -- orphans); then
        # Filter out expected orphans: attachments/, canvases/, templates/, index, log, README
        NOTE_ORPHANS=$(echo "$ALL_ORPHANS" | grep -v '^index\.md$' \
            | grep -v '^log\.md$' | grep -v '^README\.md$' \
            | grep -v '^attachments/' | grep -v '^canvases/' \
            | grep -v '^\.obsidian/' | grep -v '^\.stversions/' || true)
        if $IS_PROJECT_LOCAL; then
            NOTE_ORPHANS=$(echo "$NOTE_ORPHANS" | grep -v '^plan\.md$' || true)
        fi
        if [ -n "$NOTE_ORPHANS" ]; then
            while IFS= read -r orphan; do
                echo "  ❌ $orphan"
            done <<< "$NOTE_ORPHANS"
            COUNT=$(echo "$NOTE_ORPHANS" | wc -l)
            echo "⚠️  $COUNT orphan note(s) — inspect content/index ownership before adding links"
            WARNINGS=$((WARNINGS + COUNT))
        else
            echo "  ✅ None"
        fi
    else
        echo "  ❌ Live graph check failed; no fallback Vault"
        WARNINGS=$((WARNINGS + 1))
        COVERAGE="file-side plus incomplete live checks"
    fi
else
    echo "  ⏭️  $SKIP_REASON"
fi
echo ""

# ─── 3. Semantic Naming ─────────────────────────────────
echo "--- [3] Semantic Naming (English slug filename + Chinese semantic title) ---"
NAMING_COUNT=0
for file in "${NOTE_FILES[@]}"; do
    [ -z "$file" ] && continue
    REL_PATH="${file#$VAULT/}"
    FILENAME=$(basename "$file" .md)
    # Extract title from YAML frontmatter (handles "quoted" and unquoted)
    TITLE=$(awk '
        /^---$/ { if (++fence == 2) exit }
        fence == 1 && /^title:/ {
            sub(/^title:[ \t]*/, "")
            gsub(/^["'\''"]|["'\''"]$/, "")
            print
        }
    ' "$file")

    FILE_OK=true
    TITLE_OK=true

    # File names should be stable English/ASCII slugs for links and tooling.
    if [[ ! "$FILENAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        FILE_OK=false
    fi

    # Titles should be human-readable semantic Chinese, allowing mixed English technical terms.
    # Flag missing titles, placeholders, pure slugs, or titles without Han characters.
    HAS_HAN=$(TITLE="$TITLE" uv run --project "$SKILL_DIR" python - <<'PY'
import os
value = os.environ.get("TITLE", "")
print("yes" if any("\u3400" <= ch <= "\u9fff" or "\uf900" <= ch <= "\ufaff" for ch in value) else "no")
PY
)
    if [ -z "$TITLE" ] \
        || [[ "$TITLE" =~ ^(Index|Untitled|TODO|TBD)$ ]] \
        || [[ "$TITLE" =~ ^[A-Za-z0-9._-]+$ ]] \
        || [ "$HAS_HAN" != "yes" ]; then
        TITLE_OK=false
    fi

    if ! $FILE_OK || ! $TITLE_OK; then
        echo "  ❌ $REL_PATH"
        if ! $FILE_OK; then
            echo "     filename should be an English/ASCII slug; current: \"$FILENAME\""
        fi
        if ! $TITLE_OK; then
            echo "     title should be a Chinese or mixed Chinese-English semantic title; current: \"${TITLE:-<missing>}\""
        fi
        NAMING_COUNT=$((NAMING_COUNT + 1))
    fi
done
if [ "$NAMING_COUNT" -gt 0 ]; then
    echo "⚠️  $NAMING_COUNT semantic naming issue(s) — fix filename/title split"
    WARNINGS=$((WARNINGS + NAMING_COUNT))
else
    echo "  ✅ All knowledge notes follow semantic naming rules"
fi
echo ""

# ─── 4. Frontmatter Completeness ──────────────────────
echo "--- [4] Frontmatter (content/spec/weave owner fields) ---"
FM_COUNT=0
for file in "${NOTE_FILES[@]}"; do
    [ -z "$file" ] && continue
    FM=$(awk '/^---$/{if(++f==2)exit}f==1{print}' "$file")
    MISSING=""
    if $IS_PROJECT_LOCAL && [[ "${file#$VAULT/}" == specs/* ]]; then
        REQUIRED_FIELDS=(title created updated type doc_role authority status)
    elif [[ "${file#$VAULT/}" == weave/* ]]; then
        REQUIRED_FIELDS=(title type updated status sources)
    else
        REQUIRED_FIELDS=(title type tags sources)
    fi
    for field in "${REQUIRED_FIELDS[@]}"; do
        if ! echo "$FM" | grep -q "^${field}:"; then
            MISSING+="$field "
        fi
    done
    if [ -n "$MISSING" ]; then
        echo "  ❌ ${file#$VAULT/} — missing: ${MISSING% }"
        FM_COUNT=$((FM_COUNT + 1))
    fi
done
if [ "$FM_COUNT" -gt 0 ]; then
    echo "⚠️  $FM_COUNT file(s) with incomplete frontmatter"
    WARNINGS=$((WARNINGS + FM_COUNT))
else
    echo "  ✅ All knowledge notes have required fields"
fi
echo ""

# ─── 5. Markdown Document Size ────────────────────────
echo "--- [5] Markdown Document Size (ordinary <= 30000 bytes; weave role budgets) ---"
if SIZE_OUTPUT=$(uv run --project "$SKILL_DIR" python "$SKILL_DIR/scripts/vault_doc_sizes.py" --vault "$VAULT" 2>/dev/null); then
    echo "$SIZE_OUTPUT"
else
    SIZE_STATUS=$?
    if [ "$SIZE_STATUS" -eq 1 ]; then
        echo "$SIZE_OUTPUT"
        SIZE_COUNT=$(echo "$SIZE_OUTPUT" | grep -c '^  ❌ ' || true)
        WARNINGS=$((WARNINGS + SIZE_COUNT))
    else
        echo "  ⏭️  Size check unavailable"
    fi
fi
printf '\n'

# ─── 6. Content Metrics ───────────────────────────────
echo "--- [6] Content Metrics ---"
TODO_COUNT=$((rg -c '\[TODO:' "$VAULT" --type md --color=never \
    -g '!**/.obsidian/**' -g '!**/.stversions/**' -g '!**/.trash/**' -g '!**/.git/**' \
    2>/dev/null || true) | awk -F: '{s+=$NF} END{print s+0}')
# Count only frontmatter confidence: low (not inline text mentions)
LOW_CONF=0
for file in "${NOTE_FILES[@]}"; do
    [ -z "$file" ] && continue
    if awk '/^---$/{if(++f==2)exit}f==1 && /^confidence:[ \t]*low/{found=1}END{exit !found}' "$file" 2>/dev/null; then
        LOW_CONF=$((LOW_CONF + 1))
    fi
done

echo "  Knowledge notes: ${#NOTE_FILES[@]}"
echo "  Attachments: $(find "$VAULT/attachments" -type f 2>/dev/null | wc -l)"
echo "  Canvases: $(find "$VAULT/canvases" -type f 2>/dev/null | wc -l)"
echo "  Open TODOs:  $TODO_COUNT"
echo "  Low confidence: $LOW_CONF"
echo ""

# ─── 7. Tag Distribution ──────────────────────────────
echo "--- [7] Tags ---"
if ! $QUICK; then
    if ! project_vault exec -- tags; then
        echo "  ❌ Live tag check failed; no fallback Vault"
        WARNINGS=$((WARNINGS + 1))
        COVERAGE="file-side plus incomplete live checks"
    fi
else
    (rg -o '#[a-zA-Z][a-zA-Z0-9_/]*' "$VAULT" --type md --no-filename --color=never \
        -g '!**/.obsidian/**' -g '!**/.stversions/**' -g '!**/.trash/**' -g '!**/.git/**' 2>/dev/null || true) \
        | sort | uniq -c | sort -rn | head -15
fi
echo ""

# ─── Summary ──────────────────────────────────────────
echo "===================="
if [ "$WARNINGS" -eq 0 ]; then
    echo "✅ PASS — $COVERAGE (${#NOTE_FILES[@]} pages, $TODO_COUNT TODOs)"
else
    echo "⚠️  FAIL — $WARNINGS issue(s) found; coverage: $COVERAGE"
fi
exit "$WARNINGS"
