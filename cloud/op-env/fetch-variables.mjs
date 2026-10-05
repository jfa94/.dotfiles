// Prints the 1Password Environment's variables as JSON [{name, value}].
// Failures print one fixed line: SDK errors are never forwarded.
try {
  const { createClient } = await import('@1password/sdk');
  const client = await createClient({
    auth: process.env.OP_SERVICE_ACCOUNT_TOKEN,
    integrationName: 'dotfiles-cloud-env',
    integrationVersion: '1.0.0',
  });
  const { variables } = await client.environments.getVariables(process.env.OP_ENVIRONMENT_ID);
  process.stdout.write(JSON.stringify(variables.map(({ name, value }) => ({ name, value }))));
} catch {
  process.stderr.write('1Password read failed\n');
  process.exitCode = 1;
}
