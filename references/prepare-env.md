# Prepare Environment (Only After Failure)

This document is for troubleshooting only. Do NOT pre-check or pre-install anything.

## When to use

- Use only after the direct run fails.
- Do not add plans, environment checks, or installation steps before the first run.

## Minimal recovery steps (in order)

Goal: make the environment reusable next time by using a uv environment located in this skill's `scripts/` directory.

### Known-good path (from real usage)

Use Python 3.11 and crawl4ai in a uv venv stored inside the skill folder:

1) Create venv in the skill scripts directory
- `cd "<path-to-skill>/scripts"`
- `uv venv -p 3.11 .venv`

2) Install dependencies
- `uv pip install crawl4ai`

3) Run with uv (reuse this path for all future runs)
- `uv run --python "<path-to-skill>/scripts/.venv/bin/python" "<path-to-skill>/scripts/run_crawl_docs.py" <URL> --out <dir>`

## Notes

- Do not create or modify project files while troubleshooting.
- After installation, re-run the direct command exactly once.
