# Maintain the cloud setup

## Keep `cloud-setup.sh` in sync with `setup.sh`

`cloud-setup.sh` carries `# keep in sync with setup.sh <function>` markers —
when those setup.sh functions change, update the cloud copies.

## Roll out a change

Env cache is ~7 days: config changes land on next rebuild, or force one by
editing the environment's setup script (any whitespace change). Then run the
[verification checklist](set-up-cloud-environment.md#verification-checklist-first-session-after-changes).

## Bump the 1Password SDK

1. Change the exact version pin in `cloud/op-env/package.json`.
2. Regenerate the lockfile with the cloud's pnpm major (`pnpm dlx pnpm@<version>`).
3. Run `bash tests/cloud-op-env.sh`.
4. Repeat the pilot checks against a synthetic Environment.

## Test coverage

- `tests/cloud-setup.sh` covers syntax, degraded-install behavior, symlinks
  (including the global git ignore and the `~/.claude/hooks` directory link), and the SDK install (arguments, failure,
  no pnpm).
- `tests/cloud-op-env.sh` covers the 1Password hook and fetcher with fake
  tools: hook registration, gating, dependencies, the exact `.env.local`
  content, target guards, refresh, failures, secrecy; it also runs the fetcher's `node --test` suite
  (`cloud/op-env/fetch-variables.test.mjs`).
- `tests/cloud-node-project.sh` covers the project Node and dependency hook
  with fake nvm, node and pnpm: registration, gating, PATH delivery,
  idempotency, the frozen install (cwd, Node used), and the Node and
  dependency failure warnings.
