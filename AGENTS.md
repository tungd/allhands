# Repository Guidelines

## Project Structure & Module Organization

- `src/allhands_host/`: Tornado backend, ACP session orchestration, persistence, worktrees, notifications, and launcher adapters.
- `tests/`: backend tests. Keep fixtures in `tests/fixtures/` and name files `test_*.py`.
- `frontend/src/`: Solid PWA code. Routes live in `routes/`, reusable UI in `components/`, API/state helpers in `lib/`.
- `frontend/public/`: static PWA assets such as `sw.js`.
- `scripts/`: small repo utilities, currently `generate-vapid-keys`.
- `docs/superpowers/`: design specs and implementation plans for larger changes.

## Build, Test, and Development Commands

- `uv sync`: install Python dependencies into `.venv`, including `bcrypt` for HTTP Basic Auth.
- `pnpm --dir frontend install`: install frontend dependencies.
- `pnpm --dir frontend build`: build the Solid app into `frontend/dist/`.
- `uv run pytest -q`: run backend tests.
- `pnpm --dir frontend test -- --run`: run frontend tests with Vitest.
- `PYTHONPATH=src uv run python -m allhands_host.main --vapid_public_key="$VAPID_PUBLIC_KEY" --vapid_private_key="$VAPID_PRIVATE_KEY"`: start the server locally with the default HTTP Basic Auth user `td`.
- `PYTHONPATH=src uv run python -m allhands_host.main --default-username="$ALLHANDS_USERNAME" --default-password="$ALLHANDS_PASSWORD"`: override the bootstrapped HTTP Basic Auth credentials when needed.

## Coding Style & Naming Conventions

- Python: 4-space indentation, type hints, `snake_case` functions/modules, `PascalCase` classes, dataclasses for durable records.
- TypeScript/Solid: 2-space indentation, `PascalCase` components, `camelCase` helpers/signals, colocated `*.module.css` for component styling.
- Keep backend normalization at the HTTP/API boundary (`http.py`, `frontend/src/lib/api.ts`) instead of leaking transport shapes into core models.
- Avoid new module names that collide with stdlib names in `src/allhands_host/`; direct file execution can expose import-shadowing bugs.

## Testing Guidelines

- Backend uses `pytest` and `pytest-asyncio`; prefer focused regression tests for lifecycle, SSE, notifications, and bootstrapping changes.
- Frontend uses Vitest plus `@solidjs/testing-library`; add tests for stores, routes, and push/PWA behavior when changing UI flow.
- Run both test suites before committing. If you change frontend assets or routing, also run `pnpm --dir frontend build`.

## Commit & Pull Request Guidelines

- Follow the existing commit style: `feat: ...`, `docs: ...`, concise imperative subjects.
- Keep commits scoped to one logical change. Separate docs-only updates from behavior changes when practical.
- PRs should include: summary, verification commands/results, linked spec or plan in `docs/superpowers/` if applicable, and screenshots/GIFs for UI or PWA changes.

## Security & Configuration Tips

- Keep VAPID keys in local shell config such as `.envrc`; generate them with `./scripts/generate-vapid-keys`.
- The backend seeds a default HTTP Basic Auth user on startup. Override `--default-username` and `--default-password` outside local development instead of relying on the repository defaults.
- Do not commit `.envrc`, `.venv`, local SQLite files, or any secret values.
