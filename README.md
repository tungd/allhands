# All Hands Rewrite

Single-user ACP session host with a Tornado backend and a Solid PWA frontend.

## Run

```bash
uv sync
pnpm --dir frontend install
pnpm --dir frontend build
./scripts/generate-vapid-keys
# copy the two export lines into .envrc
PYTHONPATH=src uv run python -m allhands_host.main \
  --vapid_public_key="$VAPID_PUBLIC_KEY" \
  --vapid_private_key="$VAPID_PRIVATE_KEY"
```

## Test

```bash
uv run pytest -q
pnpm --dir frontend test -- --run
pnpm --dir frontend build
```

## V1 Capabilities

- concurrent local ACP sessions
- worktree-per-session by default
- reset, cancel, resume, and archive from the mobile session screen
- SSE while the app is open
- push notifications for `attention_required` and `completed` while backgrounded
