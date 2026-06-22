# Backend Guidelines

## Preferred stack

- **Language:** TypeScript
- **Runtime:** Deno

## Conventions

- Manage imports/dependencies via the `deno.json` import map (prefer JSR); avoid ad-hoc remote URL imports
- Run with explicit, least-privilege permission flags (`--allow-net`, `--allow-env`, etc.); never `-A`/`--allow-all`
- Commands: `deno task`, `deno test`, `deno fmt`, `deno lint`
