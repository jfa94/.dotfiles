# Troubleshoot Claude Auto-mode confirmation prompts

Why these prompts happen, and the investigation behind this guide: [Claude Auto-mode denials](../explanation/claude-auto-mode-denials.md).

## Respond to an unexpected confirmation prompt

1. Keep classifier review enabled.
2. Review the preceding actions: Auto mode falls back to confirmation after three consecutive
   classifier denials or twenty total denials, and the counter spans actions.
3. Approve the specific intended action if appropriate. Do not select a permanent `corepack *`
   allowance; it would also preapprove unrelated commands.

## Run validation commands so failures are preserved

1. Run validation commands individually without output-filter pipelines. For
   goodbyespy, execute each of these in a separate tool call from the project root:

   ```sh
   corepack pnpm@10.34.3 exec tsc --noEmit
   ```

   ```sh
   corepack pnpm@10.34.3 exec eslint .
   ```

   ```sh
   env -u NEXT_PUBLIC_SUPABASE_URL -u NEXT_PUBLIC_SUPABASE_KEY -u NEXT_SECRET_SUPABASE_KEY corepack pnpm@10.34.3 exec vitest run utils/sweep/createSweep.test.ts
   ```

   The pinned Corepack invocation is a goodbyespy project requirement. Its documented
   `env -u` prefix removes inherited hosted Supabase settings from the child process
   so Vitest can load local test settings. It does not edit environment files. The
   suite uses a real local database with a localhost guard; keep that isolation and
   the project's test prerequisites. These examples are not global package-version
   or test-environment defaults.

2. If output filtering is necessary, enable `set -o pipefail` in the same Bash or
   zsh invocation, and leave the pipeline as the final command:

   ```sh
   set -o pipefail
   corepack pnpm@10.34.3 exec eslint . 2>&1 | tail -5
   ```

3. A nonzero result requires inspecting the full diagnostics before reporting the
   outcome. Do not infer a passing gate from empty output or a printed success
   marker. Standalone commands are the default; shell-specific status arrays and
   custom wrappers add no value for these examples.
