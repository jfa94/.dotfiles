# Rotate an agent credential

1. Update the existing 1Password item so references stay stable.
2. If an item is renamed or recreated instead, update every tracked reference.
3. Clear the cache for immediate use; otherwise the cached value can remain active for up to 12 hours:

   ```sh
   "$HOME/.config/agent-env/op-read-locked" --clear
   ```

A future Outsidey-specific PostHog key changes only Outsidey's `.agent-env` and the project-level
Claude PostHog `headersHelper` entry; the user-level personal default remains unchanged. Keep legacy
Keychain copies until the [new-machine checklist](set-up-agent-credentials.md) passes on every
machine, then remove them only as a separately approved cleanup.
