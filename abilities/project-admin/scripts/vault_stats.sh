#!/bin/bash
# Vault statistics: note count, recent changes, size
set -euo pipefail
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
vault_stats.sh
用法:
  vault_stats.sh [VAULT]
  vault_stats.sh --help
目标 Vault 自动选择:
  - 传入 VAULT 参数时统计该路径
  - 当前目录是 Vault（存在 index.md 且存在 .obsidian/ 或 _meta.yaml）时，统计当前目录
  - 当前项目存在 .maxa/ 时，统计项目本地 Vault
  - 否则失败并要求显式路径或项目 .maxa/
常用场景:
  1. 快速查看 vault 规模和目录分布
  2. 检查最近 7 天修改最频繁的笔记
  3. 在清理/重构前先确认 vault 总体状态
输出包括总笔记数、目录分布、最近修改、vault 体积
EOF
  exit 0
fi
if [[ -n "${1:-}" ]]; then
  VAULT="$1"
elif [[ -f "index.md" && ( -d ".obsidian" || -f "_meta.yaml" ) ]]; then
  VAULT="$(pwd)"
elif [[ -d ".maxa" ]]; then
  VAULT="$(pwd)/.maxa"
else
  echo "ERROR: Unable to infer Vault. Pass VAULT or run from a project with .maxa." >&2
  exit 2
fi
if [[ ! -d "$VAULT" ]]; then
  echo "ERROR: Vault does not exist: $VAULT" >&2
  exit 2
fi
VAULT="$(cd "$VAULT" && pwd)"
echo "=== Vault Statistics ==="
echo "Vault: $VAULT"
echo ""
TOTAL=$(find "$VAULT" -name '*.md' -not -path '*/.obsidian/*' -not -path '*/.trash/*' | wc -l)
echo "Total notes: $TOTAL"
echo ""
echo "--- Notes by Directory ---"
find "$VAULT" -name '*.md' -not -path '*/.obsidian/*' -not -path '*/.trash/*' | sed "s|$VAULT/||" | cut -d/ -f1 | sort | uniq -c | sort -rn
echo ""
echo "--- Recently Modified (last 7 days) ---"
find "$VAULT" -name '*.md' -not -path '*/.obsidian/*' -not -path '*/.trash/*' -mtime -7 -printf '%T@ %p\n' | sort -rn | head -10 | while read -r ts path; do
    date -d "@${ts%.*}" '+%Y-%m-%d %H:%M' | tr '\n' ' '
    echo "${path#$VAULT/}"
done
echo ""
echo "--- Vault Size ---"
du -sh "$VAULT" --exclude='.git' --exclude='.obsidian' 2>/dev/null | cut -f1
