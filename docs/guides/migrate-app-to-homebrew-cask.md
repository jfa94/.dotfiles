# Migrate an existing app to Homebrew cask ownership

Use this once per app when moving an existing `/Applications/*.app` under cask ownership. Setup never
does this for you.

1. Preserve the app's Library data.
2. Stage the old bundle.
3. Rename the backup so it no longer ends in `.app`. This prevents Launch Services from indexing both copies.
4. Install the cask. Do not use `--zap` for these migrations.
5. Verify login, licensing, permissions, helpers, and local data.
6. Delete the staged copy.
