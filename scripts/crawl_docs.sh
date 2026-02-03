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
from urllib.parse import quote, urljoin, urlparse, urldefrag, urlsplit, urlunsplit
from urllib.request import Request, urlopen

from crawl4ai import AsyncWebCrawler, CrawlerRunConfig
from crawl4ai.markdown_generation_strategy import DefaultMarkdownGenerator


def _sanitize_filename(name: str) -> str:
    name = name.strip()
    if not name:
        return "untitled"
    lower = name.lower()
    if lower.endswith(".markdown"):
        name = name[:-9]
    elif lower.endswith(".md"):
        name = name[:-3]
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

def _is_docsify_html(html_content: str) -> bool:
    if not html_content:
        return False
    return bool(re.search(r"window\.\$docsify\s*=", html_content))

def _normalize_url(url: str) -> str:
    parts = urlsplit(url)
    path = quote(parts.path, safe="/%:@")
    query = quote(parts.query, safe="=&%:@/?")
    return urlunsplit((parts.scheme, parts.netloc, path, query, parts.fragment))

def _strip_query(url: str) -> str:
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "", parts.fragment))


def _fetch_text(url: str, timeout_s: int = 30) -> tuple[int, str, str]:
    url = _normalize_url(url)
    req = Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (compatible; crawl-docs-skill/1.0)",
            "Accept": "text/html, text/plain, text/markdown, */*",
        },
    )
    with urlopen(req, timeout=timeout_s) as resp:
        status = getattr(resp, "status", 200)
        content_type = resp.headers.get("Content-Type", "")
        raw = resp.read()
        encoding = "utf-8"
        match = re.search("charset=([\\w\\-]+)", content_type, flags=re.IGNORECASE)
        if match:
            encoding = match.group(1)
        try:
            text = raw.decode(encoding, errors="replace")
        except LookupError:
            text = raw.decode("utf-8", errors="replace")
    return status, content_type, text


def _looks_like_markdown(content_type: str, text: str) -> bool:
    ct = (content_type or "").lower()
    if "text/markdown" in ct:
        return True
    if "text/plain" in ct and ("#" in text[:200] or "](" in text[:200]):
        return True
    # Many hosts serve .md as text/plain without a helpful content-type.
    if re.search("^\\s*#\\s+.+", text, flags=re.MULTILINE):
        return True
    return False


def _extract_md_title(md: str, url: str) -> str:
    # YAML front matter title:
    fm = re.match("^---\\s*\\n(.*?)\\n---\\s*\\n", md, flags=re.DOTALL)
    if fm:
        m = re.search("^title\\s*:\\s*(.+?)\\s*$", fm.group(1), flags=re.IGNORECASE | re.MULTILINE)
        if m:
            t = m.group(1).strip().strip('"').strip("'")
            if t:
                return t
    # First H1
    m = re.search("^\\s*#\\s+(.+?)\\s*$", md, flags=re.MULTILINE)
    if m:
        return m.group(1).strip()
    path = urlparse(url).path.rstrip("/")
    last = path.split("/")[-1] or url
    if isinstance(last, str) and last.lower().endswith(".md"):
        last = last[:-3]
    return last


def _md_links(md: str) -> list[str]:
    links: list[str] = []
    # Standard Markdown links: [text](target)
    for m in re.finditer(r"\[[^\]]*\]\(([^)]+)\)", md):
        target = m.group(1).strip().strip("<>").strip()
        if not target:
            continue
        links.append(target)
    # Reference-style definitions: [id]: target
    for m in re.finditer(r"^\s*\[[^\]]+\]\s*:\s*(\S+)\s*$", md, flags=re.MULTILINE):
        target = m.group(1).strip()
        links.append(target)
    return links


def _normalize_md_href(href: str) -> str:
    href = href.strip().strip("<>").strip()
    # Unescape common Markdown escapes in link targets, e.g. source\_code -> source_code.
    href = re.sub(r"\\([_./-])", r"\1", href)
    return href


def _docsify_candidate_urls(base_url: str, current_url: str, href: str) -> list[str]:
    href = _normalize_md_href(href).strip().strip('"').strip("'")
    if not href:
        return []
    if href.startswith("#"):
        return []
    if href.startswith(("mailto:", "tel:", "javascript:")):
        return []

    bases: list[str] = []
    if href.startswith("/"):
        bases.append(urljoin(base_url, href))
    elif href.startswith(("./", "../")):
        bases.append(urljoin(current_url, href))
    else:
        # Docsify links are typically authored relative to site root.
        bases.append(urljoin(base_url, href))

    abs_urls: set[str] = set()
    for u in bases:
        u = urldefrag(u).url
        u = _strip_query(u)
        u = _normalize_url(u)
        abs_urls.add(u)

    candidates: list[str] = []
    for abs_url in abs_urls:
        parsed = urlparse(abs_url)
        if parsed.scheme not in ("http", "https"):
            continue
        if parsed.netloc != urlparse(base_url).netloc:
            continue

        path = parsed.path
        if path.endswith("/"):
            candidates.extend([abs_url + "README.md", abs_url + "_sidebar.md", abs_url + "_coverpage.md"])
            continue

        # Docsify often links to routes without .md (it appends .md at fetch time).
        if not re.search("\\.[a-zA-Z0-9]{1,5}$", path):
            candidates.extend([abs_url + ".md", abs_url + "/README.md", abs_url])
            continue

        candidates.append(abs_url)

    # De-dup while preserving order
    deduped: list[str] = []
    seen: set[str] = set()
    for u in candidates:
        if u in seen:
            continue
        seen.add(u)
        deduped.append(u)
    return deduped


def _write_markdown(output_dir: str, used_names: dict[str, int], title: str, md: str) -> str:
    base_name = _sanitize_filename(title)
    count = used_names.get(base_name, 0)
    used_names[base_name] = count + 1
    filename = f"{base_name}.md" if count == 0 else f"{base_name}-{count + 1}.md"
    out_path = os.path.join(output_dir, filename)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(md)
    return out_path


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

async def crawl_docsify(start_url: str, output_dir: str, max_pages: Optional[int]) -> None:
    parsed_start = urlparse(start_url)
    if not parsed_start.netloc:
        raise ValueError("Invalid start URL.")

    base_url = f"{parsed_start.scheme}://{parsed_start.netloc}/"
    os.makedirs(output_dir, exist_ok=True)

    seen: set[str] = set()
    queue: deque[str] = deque()
    used_names: dict[str, int] = {}

    # Seed with common docsify entrypoints; most important is _sidebar.md.
    queue.append(urljoin(base_url, "_sidebar.md"))
    queue.append(urljoin(base_url, "_navbar.md"))
    queue.append(urljoin(base_url, "README.md"))
    queue.append(urljoin(base_url, "_coverpage.md"))

    while queue:
        if max_pages is not None and len(seen) >= max_pages:
            break
        current = queue.popleft()
        current = urldefrag(current).url
        if current in seen:
            continue
        seen.add(current)

        try:
            status, content_type, text = _fetch_text(current)
        except Exception as e:
            print(f"Skip (fetch error): {current} -> {e}")
            continue

        if status >= 400:
            continue

        if _looks_like_markdown(content_type, text):
            title = _extract_md_title(text, current)
            _write_markdown(output_dir, used_names, title, text)

            for href in _md_links(text):
                for cand in _docsify_candidate_urls(base_url, current, href):
                    if cand not in seen:
                        queue.append(cand)
            continue

        # If we accidentally hit the SPA HTML shell, try to pivot to docsify markdown via sidebar.
        if _is_docsify_html(text):
            sidebar = urljoin(base_url, "_sidebar.md")
            if sidebar not in seen:
                queue.appendleft(sidebar)
            continue

        # Non-markdown resources are ignored in docsify mode.


def main() -> None:
    parser = argparse.ArgumentParser(description="Crawl a site and save pages as Markdown.")
    parser.add_argument("url", help="Start URL, e.g., https://www.drissionpage.cn/")
    parser.add_argument("--out", default="docs", help="Output directory")
    parser.add_argument("--max-pages", type=int, default=None, help="Maximum pages to crawl (optional)")
    args = parser.parse_args()

    # Auto-detect docsify sites (common in doc portals, often using hash routing).
    try:
        status, content_type, text = _fetch_text(args.url)
        is_docsify = (status < 400) and _is_docsify_html(text)
    except Exception:
        is_docsify = False

    if is_docsify:
        asyncio.run(crawl_docsify(args.url, args.out, args.max_pages))
    else:
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
