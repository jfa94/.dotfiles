# Configure a project's AWS account

Projects select an AWS account without committing credentials. Setup does not create profiles or log in; authenticate with `aws login` first.

1. Claude Code: set `AWS_PROFILE` in the project's `.claude/settings.json` `env` object.
2. Codex: set `AWS_PROFILE` in the trusted project's `.codex/config.toml` `[shell_environment_policy.set]` table and use the ordinary AWS CLI.
3. Interactive shells: use a secret-free `.envrc` that exports the same profile and the matching `AGENT_ENV_FILE`, then run `direnv allow` for the project. See [Configure a project's agent credentials](configure-project-credentials.md).
4. Verify (Outsidey example — configure both mechanisms with the `Outsidey` profile):

   ```sh
   aws --version
   uvx --version
   AWS_PROFILE=Outsidey aws agent-toolkit list-available-skills --region us-east-1
   cd /Users/Javier/Projects/outsidey
   aws sts get-caller-identity
   aws amplify list-apps --region eu-west-1
   ```

5. Compare the STS result with the [expected Outsidey identity](../reference/aws-agent-toolkit.md#outsidey).
