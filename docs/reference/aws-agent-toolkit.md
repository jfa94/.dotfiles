# AWS Agent Toolkit

The shared global context in `instructions/AGENTS.md` includes AWS guidance from
the official [AWS Agent Toolkit rules](https://github.com/aws/agent-toolkit-for-aws/blob/main/rules/aws-agent-rules.md).
Keep common guidance synchronized when upstream rules change, preserving the
runtime-specific routing: Claude's MCP preference belongs only to its tool
section; Codex authenticated resource access remains CLI-only. Secret-safety
requirements apply to both tools.

To select a project's AWS account and verify access, see [Configure a project's AWS account](../guides/configure-project-aws-account.md).

## Plugins

Claude installs `aws-core@agent-toolkit-for-aws` but leaves it disabled. Codex installs and enables the same AWS-maintained `aws-core` bundle. It supersedes the retired `aws-serverless@claude-plugins-official` plugin and includes serverless guidance alongside broader AWS skills and the AWS MCP server.

AWS setup registers `aws/agent-toolkit-for-aws`, installs `aws-core`, `uv`/`uvx`, and AWS CLI via Homebrew on macOS or the official user-local installer (minimum 2.35.0) on Linux/cloud. It never edits AWS credentials or profiles. Codex permits AWS knowledge, documentation, skill, and region tools but repository hooks deny authenticated MCP `call_aws`, `run_script`, and presigned-URL operations.

## Installed tools

On Linux/cloud, setup installs the official AWS CLI in user-local storage when it is absent or older than 2.35.0, plus `uv`/`uvx` for the MCP proxy. On macOS, Homebrew owns AWS CLI and uv; setup verifies that ownership and does not install a user-local AWS CLI. `direnv` is installed on macOS, Ubuntu, and Arch through the repository package manifests. The guarded zsh hook is inert when `direnv` is unavailable. User-local binaries precede system binaries so Linux user-local AWS installations win over older system installations.

## Setup boundaries and Codex tool access

Setup does not edit `~/.aws/config`, `~/.aws/credentials`, run `aws login`, or run the global `aws configure agent-toolkit --yes` wizard. Authentication and profile creation are deliberate manual steps. Codex may use AWS knowledge, documentation, skill-discovery, and region tools. Repository hooks deny authenticated AWS MCP `call_aws`, `run_script`, and presigned-URL operations; use the audited AWS CLI rules for resource reads. AWS writes and unlisted CLI operations continue to prompt.

## Codex read access

Trusted workspace `.env*` files are readable by Codex so it can understand local configuration, but they remain protected from edits and commits. Exact Claude parity intentionally permits Codex to read `~/.aws/credentials`; AWS config is also readable. Root filesystem read access also covers `.env*` outside trusted workspaces, SSH material, private keys, certificates, `secrets/`, and Codex authentication data, subject to OS permissions. There are no filesystem read-denies; see [Codex permission boundaries](codex-claude-parity.md#intentional-gaps) for edit authorization and commit safeguards. The secret-output hook and environment-variable filter remain active.

## Outsidey

| Setting                         | Value                     |
| ------------------------------- | ------------------------- |
| Profile (Claude, Codex, direnv) | `Outsidey`                |
| Application region              | `eu-west-1`               |
| Agent Toolkit command region    | `us-east-1`               |

In a fresh Outsidey Codex session, STS must report account `412868037405` and IAM user `jflores`. No wrapper or login command is involved. Authenticated AWS resource access remains CLI-only; AWS MCP is limited to documentation, skills, and region metadata.
