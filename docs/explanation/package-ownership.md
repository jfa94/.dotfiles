# Package ownership

Each executable has exactly one owner so updates are predictable and setup never fights another
installer.

## Selective Brewfile

The Brewfile is intentionally selective. It owns the chosen developer tools,
Docker Desktop, 1Password, and the chosen desktop apps; it does not mirror every
Homebrew package already installed on a machine. Setup never runs
`brew bundle cleanup`, so unlisted packages and applications are left alone.

Moving an existing `/Applications/*.app` under cask ownership is a one-time
migration, not setup behavior ([procedure](../guides/migrate-app-to-homebrew-cask.md)).

## Vendor-owned agent CLIs

Claude Code and Codex are owned by their vendors' standalone installers on every platform rather
than Homebrew casks or npm, because Homebrew casks block their built-in auto-updaters. Setup refuses
an active Homebrew or npm installation to avoid ambiguous duplicate CLIs.

## Credential-adjacent CLIs

On macOS, Homebrew owns the AWS, uv, Stripe, Supabase, and 1Password CLI executables; Linux retains
the native/official installers. Changing an executable's owner is deliberately narrow: it must not
touch configuration or auth state. See [executable ownership](../reference/agent-credentials.md#executable-ownership).
