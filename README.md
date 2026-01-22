# crawl-docs-skill

A minimal Codex skill that crawls a docs site and saves internal pages as Markdown.

## Usage

Direct run (no pre-checks, no scaffolding):

```
bash "<path-to-skill>/scripts/crawl_docs.sh" <URL> --out "$PWD/docs"
```

Optional flags:

```
--out <dir>
--max-pages <int>
```

## If It Fails

Re-run the same command. The script bootstraps uv + venv automatically; if it still fails, fix missing system prerequisites (most commonly `curl`).

## Files

- `scripts/crawl_docs.sh` — one-shot crawler + environment bootstrap
- `SKILL.md` — skill instructions
