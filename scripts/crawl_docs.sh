#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
VENV_PY="$VENV_DIR/bin/python"

print_help() {
  cat <<'EOF'
Usage:
  crawl_docs.sh <URL> [--out <dir>] [--max-pages <int>]

Notes:
  - Auto-bootstraps uv + a local venv under scripts/.venv (Python 3.11) and installs crawl4ai if missing.
  - If --out is not provided, defaults to "$PWD/docs" (from where you run the script).
EOF
}

python_code() {
  cat <<'__CRAWL_DOCS_PY__'
import argparse
import asyncio
import html as html_module
import os
import re
from collections import deque
from typing import Optional
from urllib.parse import urljoin, urlparse, urldefrag

from crawl4ai import AsyncWebCrawler, CrawlerRunConfig
from crawl4ai.markdown_generation_strategy import DefaultMarkdownGenerator


def _sanitize_filename(name: str) -> str:
    name = name.strip()
    if not name:
        return "untitled"
    name = re.sub(r"[\\/:*?\"<>|]", "-", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:120]


def _extract_title(metadata: Optional[dict], html_content: str, url: str) -> str:
    if metadata and metadata.get("title"):
        return metadata["title"]
    if html_content:
        match = re.search(r"<title[^>]*>(.*?)</title>", html_content, flags=re.IGNORECASE | re.DOTALL)
        if match:
            title = html_module.unescape(match.group(1))
            title = re.sub(r"\s+", " ", title).strip()
            if title:
                return title
    path = urlparse(url).path.rstrip("/")
    return path.split("/")[-1] or url


def _get_markdown(result) -> str:
    if result.markdown is None:
        return ""
    if isinstance(result.markdown, str):
        return result.markdown
    return result.markdown.raw_markdown or ""


async def crawl_site(start_url: str, output_dir: str, max_pages: Optional[int]) -> None:
    parsed_start = urlparse(start_url)
    base_netloc = parsed_start.netloc
    if not base_netloc:
        raise ValueError("Invalid start URL.")

    os.makedirs(output_dir, exist_ok=True)

    seen = set()
    queue = deque([start_url])
    used_names = {}

    config = CrawlerRunConfig(markdown_generator=DefaultMarkdownGenerator())

    async with AsyncWebCrawler() as crawler:
        while queue:
            if max_pages is not None and len(seen) >= max_pages:
                break
            current = queue.popleft()
            current = urldefrag(current).url
            if current in seen:
                continue
            seen.add(current)

            result = await crawler.arun(url=current, config=config)
            if not result.success:
                print(f"Skip (failed): {current} -> {result.error_message}")
                continue

            md = _get_markdown(result)
            title = _extract_title(result.metadata, result.html, result.url)
            base_name = _sanitize_filename(title)
            count = used_names.get(base_name, 0)
            used_names[base_name] = count + 1
            filename = f"{base_name}.md" if count == 0 else f"{base_name}-{count + 1}.md"
            out_path = os.path.join(output_dir, filename)

            with open(out_path, "w", encoding="utf-8") as f:
                f.write(md)

            internal_links = result.links.get("internal", []) if result.links else []
            for link in internal_links:
                href = link.get("href")
                if not href:
                    continue
                abs_url = urljoin(result.url, href)
                abs_url = urldefrag(abs_url).url
                parsed = urlparse(abs_url)
                if parsed.scheme not in ("http", "https"):
                    continue
                if parsed.netloc != base_netloc:
                    continue
                if abs_url not in seen:
                    queue.append(abs_url)


def main() -> None:
    parser = argparse.ArgumentParser(description="Crawl a site and save pages as Markdown.")
    parser.add_argument("url", help="Start URL, e.g., https://www.drissionpage.cn/")
    parser.add_argument("--out", default="docs", help="Output directory")
    parser.add_argument("--max-pages", type=int, default=None, help="Maximum pages to crawl (optional)")
    args = parser.parse_args()

    asyncio.run(crawl_site(args.url, args.out, args.max_pages))


if __name__ == "__main__":
    main()
__CRAWL_DOCS_PY__
}

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "error: uv is not installed and curl is missing; install uv manually, or install curl and re-run."
    exit 1
  fi

  echo "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh

  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

  if ! command -v uv >/dev/null 2>&1; then
    echo "error: uv install finished but 'uv' is not on PATH."
    echo "hint: add ~/.local/bin to PATH (then restart your shell) and re-run."
    exit 1
  fi
}

ensure_venv() {
  if [[ -x "$VENV_PY" ]]; then
    return 0
  fi

  echo "Creating venv: $VENV_DIR (Python 3.11)"
  if uv venv -p 3.11 "$VENV_DIR"; then
    return 0
  fi

  echo "uv venv failed; trying to install Python 3.11 via uv..."
  uv python install 3.11
  uv venv -p 3.11 "$VENV_DIR"
}

ensure_deps() {
  if "$VENV_PY" -c "import crawl4ai" >/dev/null 2>&1; then
    return 0
  fi

  echo "Installing dependencies into venv..."
  uv pip install --python "$VENV_PY" crawl4ai
}

main() {
  if [[ $# -eq 0 ]]; then
    print_help
    exit 2
  fi

  for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
      print_help
      exit 0
    fi
  done

  local caller_dir="$PWD"

  cd "$SCRIPT_DIR"
  ensure_uv
  ensure_venv
  ensure_deps

  local has_out=0
  for arg in "$@"; do
    if [[ "$arg" == "--out" || "$arg" == --out=* ]]; then
      has_out=1
      break
    fi
  done

  local -a args=("$@")
  if [[ "$has_out" -eq 0 ]]; then
    args+=("--out" "$caller_dir/docs")
  fi

  cd "$caller_dir"
  "$VENV_PY" - "${args[@]}" < <(python_code)
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
