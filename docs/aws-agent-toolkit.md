# AWS Agent Toolkit

The shared global context in `instructions/AGENTS.md` includes AWS guidance from
the official [AWS Agent Toolkit rules](https://github.com/aws/agent-toolkit-for-aws/blob/main/rules/aws-agent-rules.md).
Keep common guidance synchronized when upstream rules change, preserving the
runtime-specific routing: Claude's MCP preference belongs only to its tool
section; Codex authenticated resource access remains CLI-only. Secret-safety
requirements apply to both tools.

Claude installs `aws-core@agent-toolkit-for-aws` but leaves it disabled. Codex installs and enables the same AWS-maintained `aws-core` bundle. It supersedes the retired `aws-serverless@claude-plugins-official` plugin and includes serverless guidance alongside broader AWS skills and the AWS MCP server.

On Linux/cloud, setup installs the official AWS CLI in user-local storage when it is absent or older than 2.35.0, plus `uv`/`uvx` for the MCP proxy. On macOS, Homebrew owns AWS CLI and uv; setup verifies that ownership and does not install a user-local AWS CLI. `direnv` is installed on macOS, Ubuntu, and Arch through the repository package manifests. The guarded zsh hook is inert when `direnv` is unavailable. User-local binaries precede system binaries so Linux user-local AWS installations win over older system installations.

Projects select an AWS account without committing credentials:

- Claude Code: set `AWS_PROFILE` in the project's `.claude/settings.json` `env` object.
- Codex: set `AWS_PROFILE` in the trusted project's `.codex/config.toml` `[shell_environment_policy.set]` table and use the ordinary AWS CLI.
- Interactive shells: use a secret-free `.envrc` that exports the same profile and the matching `AGENT_ENV_FILE`, then run `direnv allow` for the project. See [agent-credentials.md](agent-credentials.md).

For Outsidey, configure both mechanisms with the `Outsidey` profile. Its application region is `eu-west-1`; Agent Toolkit commands use `us-east-1`.

Setup does not edit `~/.aws/config`, `~/.aws/credentials`, run `aws login`, or run the global `aws configure agent-toolkit --yes` wizard. Authentication and profile creation are deliberate manual steps. Codex may use AWS knowledge, documentation, skill-discovery, and region tools. Repository hooks deny authenticated AWS MCP `call_aws`, `run_script`, and presigned-URL operations; use the audited AWS CLI rules for resource reads. AWS writes and unlisted CLI operations continue to prompt.

Trusted workspace `.env*` files are readable by Codex so it can understand local configuration, but they remain protected from edits and commits. Exact Claude parity intentionally permits Codex to read `~/.aws/credentials`; AWS config is also readable. Root filesystem read access also covers `.env*` outside trusted workspaces, SSH material, private keys, certificates, `secrets/`, and Codex authentication data, subject to OS permissions. There are no filesystem read-denies; see [Codex permission boundaries](codex-claude-parity.md#intentional-gaps) for edit authorization and commit safeguards. The secret-output hook and environment-variable filter remain active.

Normal setup adds missing marketplaces/plugins but never upgrades installed marketplaces. Run `bash .codex/update-plugins.sh` only from a normal terminal outside an active Codex task. It validates enabled plugin hook manifests and command targets, then requires a Codex/ChatGPT restart and `/hooks` review.

If shell commands fail after a plugin update, restart Codex so it reloads the current `com.anthropic.claude-code/hooks/secret-safety.py` path. If validation still fails, leave AWS Core disabled and file an upstream issue with the old/new manifests and cache timestamps. Never patch the vendor cache or add a compatibility symlink.

Verify with:

```sh
aws --version
uvx --version
AWS_PROFILE=Outsidey aws agent-toolkit list-available-skills --region us-east-1
cd /Users/Javier/Projects/outsidey
aws sts get-caller-identity
aws amplify list-apps --region eu-west-1
```

In a fresh Outsidey Codex session, STS must report account `412868037405` and IAM user `jflores`. No wrapper or login command is involved. Authenticated AWS resource access remains CLI-only; AWS MCP is limited to documentation, skills, and region metadata.
