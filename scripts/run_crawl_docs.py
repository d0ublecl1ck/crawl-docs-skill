#!/usr/bin/env python3
import argparse
import asyncio
import html
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


def _extract_title(metadata: Optional[dict], html: str, url: str) -> str:
    if metadata and metadata.get("title"):
        return metadata["title"]
    if html:
        match = re.search(r"<title[^>]*>(.*?)</title>", html, flags=re.IGNORECASE | re.DOTALL)
        if match:
            title = html.unescape(match.group(1))
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
    parser.add_argument("--out", default="output_md", help="Output directory")
    parser.add_argument("--max-pages", type=int, default=None, help="Maximum pages to crawl (optional)")
    args = parser.parse_args()

    asyncio.run(crawl_site(args.url, args.out, args.max_pages))


if __name__ == "__main__":
    main()
