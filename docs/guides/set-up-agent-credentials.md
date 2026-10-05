# Set up agent credentials on a new machine

Background and behavior: [agent credentials reference](../reference/agent-credentials.md).

1. Install and sign in to the 1Password desktop app.
2. Enable system authentication and **Integrate with 1Password CLI**.
3. Clone dotfiles and run `setup.sh`, then confirm `op account list`.
4. Clone the project repositories and run `direnv allow` once in each checkout.
5. In Outsidey, run `op plugin init stripe` if the transparent alias is absent.
6. Authenticate AWS profiles with `aws login` and GitHub with `gh auth login`.
7. Migrate the user-level Claude supabase server: with all Claude sessions
   closed, set `mcpServers.supabase.headersHelper` in `~/.claude.json` to
   `printf '{"Authorization":"Bearer %s"}' "$("$HOME/.config/agent-env/op-read-locked" 'op://Credentials/Supabase Access Token/credential')"`
   (that file is machine-local live state, not tracked here).
8. Verify:

   ```sh
   bash tests/agent-credentials.sh
   aws sts get-caller-identity --profile default
   aws sts get-caller-identity --profile Outsidey
   aws sts get-caller-identity --profile Almunia
   gh auth status
   op plugin inspect stripe
   ```

9. Within Outsidey, verify that PostHog reports project `107700`, project-switching
   and Supabase account tools are absent, and no Stripe write tool is exposed. For
   PostHog, verify what a write through `posthog` actually does — it is no longer
   blocked by MCP permissions, so the result reflects the API key's own scopes.
10. Within Almunia, verify `AGENT_ENV_FILE=/dev/null` and
    that Codex lists personal Supabase/PostHog servers as disabled.
11. Run `env` in the parent shell before and after a credentialed command to confirm tokens were not
    retained. Do not print token-bearing child environments or enable shell tracing.

Keep legacy Keychain copies until this checklist passes on every machine, then remove them
only as a separately approved cleanup.
