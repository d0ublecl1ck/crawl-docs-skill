# crawl-docs-skill

A minimal Codex skill that crawls a docs site and saves internal pages as Markdown.

## Usage

Direct run (no pre-checks, no scaffolding):

```
uv run "<path-to-skill>/scripts/run_crawl_docs.py" <URL> --out "$PWD/docs"
```

Optional flags:

```
--out <dir>
--max-pages <int>
```

## If It Fails

Follow:

```
"<path-to-skill>/references/prepare-env.md"
```

## Files

- `scripts/run_crawl_docs.py` — the only executable script
- `references/prepare-env.md` — post-failure environment setup guide
- `SKILL.md` — skill instructions
