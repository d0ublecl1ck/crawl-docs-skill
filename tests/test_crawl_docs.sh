#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/crawl_docs.sh"

bash -n "$SCRIPT"

help_out="$("$SCRIPT" --help)"
echo "$help_out" | grep -q "Usage:"
echo "$help_out" | grep -q "crawl_docs.sh"

tmp_base="$(mktemp -t crawl_docs_embedded_XXXXXX)"
tmp_py="${tmp_base}.py"
mv "$tmp_base" "$tmp_py"
trap 'rm -f "$tmp_py"' EXIT

source "$SCRIPT"
python_code > "$tmp_py"
python3 -m py_compile "$tmp_py"
