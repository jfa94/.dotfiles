# AWS Agent Toolkit

The global Claude context includes the official [AWS Agent Toolkit rules](https://github.com/aws/agent-toolkit-for-aws/blob/main/rules/aws-agent-rules.md). Keep that section synchronized when the upstream rules change.

Claude installs `aws-core@agent-toolkit-for-aws` but leaves it disabled. Codex installs and enables the same AWS-maintained `aws-core` bundle. It supersedes the retired `aws-serverless@claude-plugins-official` plugin and includes serverless guidance alongside broader AWS skills and the AWS MCP server.

Setup installs the official AWS CLI in user-local storage when it is absent or older than 2.35.0, plus `uv`/`uvx` for the MCP proxy. `direnv` is installed on macOS, Ubuntu, and Arch through the repository package manifests. The guarded zsh hook is inert when `direnv` is unavailable. User-local binaries precede system binaries so the managed AWS CLI wins over older system installations.

Projects select an AWS account without committing credentials:

- Claude Code: set `AWS_PROFILE` in the project's `.claude/settings.json` `env` object.
- Codex: authenticate the AWS CLI manually and select the profile through the shell or a project-local `.envrc`.
- Interactive shells: create a machine-local `.envrc` that exports the same profile, ignore it in Git, then run `direnv allow` for the project.

For Outsidey, configure both mechanisms with the `Outsidey` profile. Its application region is `eu-west-1`; Agent Toolkit commands use `us-east-1`.

Setup does not edit `~/.aws/config`, `~/.aws/credentials`, run `aws login`, or run the global `aws configure agent-toolkit --yes` wizard. Authentication and profile creation are deliberate manual steps. Codex may use AWS knowledge, documentation, skill-discovery, and region tools. Repository hooks deny authenticated AWS MCP `call_aws`, `run_script`, and presigned-URL operations; use the audited AWS CLI rules for resource reads. AWS writes and unlisted CLI operations continue to prompt.

Trusted workspace `.env*` files are readable by Codex so it can understand local configuration, but they remain protected from edits and commits. AWS credential files, private keys, certificates, `secrets/`, and Codex authentication data remain unreadable. Read permission never implies that all environment variables are inherited by child processes.

After setup, open Codex `/hooks` and review the new AWS MCP read-only hook by exact hash. Setup never uses the global hook-trust bypass.

Verify with:

```sh
aws --version
uvx --version
AWS_PROFILE=Outsidey aws agent-toolkit list-available-skills --region us-east-1
direnv exec /Users/Javier/Projects/outsidey aws sts get-caller-identity
```
