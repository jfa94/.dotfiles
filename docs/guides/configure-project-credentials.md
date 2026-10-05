# Configure a project's agent credentials

1. Add a repository-local `.agent-env` containing only `op://` references and non-secret routing metadata, in the [supported env-file format](../reference/agent-credentials.md#env-file-format). Use `/dev/null` instead when the project has no agent service credentials.
2. Add a `.envrc` that selects only that file and native provider profiles (see [selector examples](../reference/agent-credentials.md#project-envrc-selectors)). It must not call `op`, source a resolved file, or export a token.
3. After adding or changing a selector, run `direnv allow` in that repository.
4. For a non-interactive shell, run credentialed commands through the explicit runner:

   ```sh
   "$HOME/.config/agent-env/agent-env-run" supabase projects list
   ```

5. For Stripe in Outsidey, run `op plugin init stripe` once per machine if the transparent alias has not been generated yet.

To select the project's AWS account for Claude Code and Codex as well, see [Configure a project's AWS account](configure-project-aws-account.md).
