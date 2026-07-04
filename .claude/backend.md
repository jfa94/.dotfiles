# Backend Guidelines

## Preferred stack

- **Language:** TypeScript
- **Runtime:** Node

## Conventions

- Manage dependencies via `package.json` (pnpm); avoid ad-hoc global installs
- Use ESM: set `"type": "module"` and explicit `.js` extensions on relative imports
- Bootstrap linting/formatting/testing with `ts/configure.sh node <project-dir>`
- Commands (from the scaffold): `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm format`
