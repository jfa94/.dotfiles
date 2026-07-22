# AWS Agent Toolkit

The global Claude context includes the official [AWS Agent Toolkit rules](https://github.com/aws/agent-toolkit-for-aws/blob/main/rules/aws-agent-rules.md). Keep that section synchronized when the upstream rules change.

`direnv` is installed on macOS, Ubuntu, and Arch through the repository package manifests. The guarded zsh hook is inert when `direnv` is unavailable. User-local binaries precede system binaries so the user-local AWS CLI wins over older system installations.

Projects select an AWS account without committing credentials:

- Claude Code: set `AWS_PROFILE` in the project's `.claude/settings.json` `env` object.
- Interactive shells: create a machine-local `.envrc` that exports the same profile, ignore it in Git, then run `direnv allow` for the project.

For Outsidey, configure both mechanisms with the `Outsidey` profile. Its application region is `eu-west-1`; Agent Toolkit commands use `us-east-1`.

Verify with:

```sh
aws --version
AWS_PROFILE=Outsidey aws agent-toolkit list-available-skills --region us-east-1
direnv exec /Users/Javier/Projects/outsidey aws sts get-caller-identity
```
