# Update Codex plugins

Normal setup adds missing marketplaces/plugins but never upgrades installed marketplaces.

1. From a normal terminal outside an active Codex task, run:

   ```sh
   bash .codex/update-plugins.sh
   ```

   It validates enabled plugin hook manifests and command targets.

2. Restart Codex/ChatGPT and review changed hooks with `/hooks`.
3. If shell commands fail after the update, restart Codex so it reloads the current `com.anthropic.claude-code/hooks/secret-safety.py` path.
4. If validation still fails, leave AWS Core disabled and file an upstream issue with the old/new manifests and cache timestamps. Never patch the vendor cache or add a compatibility symlink.
