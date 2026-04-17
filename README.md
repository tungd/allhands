# All Hands Rewrite

Single-user ACP session host with a Tornado backend and a Solid PWA frontend.

## Run

```bash
uv sync
pnpm --dir frontend install
pnpm --dir frontend build
uv run python -m allhands_host.main
```

## Test

```bash
uv run pytest -q
pnpm --dir frontend test -- --run
pnpm --dir frontend build
```
