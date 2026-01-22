---
name: crawl-docs-skill
description: "Run a Crawl4AI-based doc crawler and save internal pages as Markdown using page titles as filenames. Use when the user provides a docs URL and wants all internal subpages saved as .md files. Environment setup should only use uv."
---

# Crawl Docs Skill

## One-shot (Direct Run)

- Run directly: `uv run "<path-to-skill>/scripts/run_crawl_docs.py" <URL> --out "$PWD/docs"`
- This is the only script; do not create or use any other files.
- Do NOT install dependencies or scaffold files first; assume they already exist and run immediately.
- Do NOT run tests or create plans; just execute the script and let it fail if the environment is missing.
- Default output dir (skill convention): `"$PWD/docs"` (absolute path to `./docs` under the current working directory); always pass it via `--out` unless the user specifies otherwise.
- Optional flags: `--out <dir>`, `--max-pages <int>`

If the direct run fails, follow `references/prepare-env.md` (includes a known-good uv+Python 3.11 path).

## Correct Usage (from real run)

- First run: execute the one-shot command exactly once with no extra steps.
- If it fails: set up the uv venv in the skill scripts folder (Python 3.11 + crawl4ai), then rerun using `uv run --python`.
- Do not probe versions or add max-pages unless the user asks.

## Notes

- Use page title (tab name) as the output filename; auto-deduplicate with numeric suffixes.
- Default behavior has no max pages unless `--max-pages` is provided.
