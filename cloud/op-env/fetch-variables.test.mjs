import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const FETCHER = fileURLToPath(new URL('./fetch-variables.mjs', import.meta.url));

// The fake SDK logs what it receives and returns or throws what the test asks for.
const FAKE_SDK = `
import { appendFileSync } from 'node:fs';
const log = (entry) => appendFileSync(process.env.FAKE_LOG, JSON.stringify(entry) + '\\n');
export const createClient = async (opts) => {
  log({ auth: opts.auth, integrationName: opts.integrationName, integrationVersion: opts.integrationVersion });
  return {
    environments: {
      getVariables: async (id) => {
        log({ id });
        if (process.env.FAKE_ERROR) throw new Error(process.env.FAKE_ERROR);
        return { variables: JSON.parse(process.env.FAKE_VARS) };
      },
    },
  };
};
`;

const marker = () => ['synthetic', Math.random().toString(36).slice(2)].join('-');

const run = (extraEnv) => {
  const dir = mkdtempSync(join(tmpdir(), 'op-env-fetch-'));
  try {
    const sdk = join(dir, 'node_modules', '@1password', 'sdk');
    mkdirSync(sdk, { recursive: true });
    writeFileSync(join(sdk, 'package.json'), JSON.stringify({ name: '@1password/sdk', type: 'module', exports: './index.js' }));
    writeFileSync(join(sdk, 'index.js'), FAKE_SDK);
    copyFileSync(FETCHER, join(dir, 'fetch-variables.mjs'));
    const log = join(dir, 'calls.log');
    const result = spawnSync(process.execPath, [join(dir, 'fetch-variables.mjs')], {
      env: { PATH: process.env.PATH, FAKE_LOG: log, ...extraEnv },
      encoding: 'utf8',
    });
    const calls = readFileSync(log, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    return { ...result, calls };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
};

test('prints name/value pairs, drops other fields, and passes inputs through', () => {
  const token = marker();
  const vars = [
    { name: 'A', value: 'one', masked: true },
    { name: 'B', value: '', masked: false },
  ];
  const r = run({ OP_SERVICE_ACCOUNT_TOKEN: token, OP_ENVIRONMENT_ID: 'env-123', FAKE_VARS: JSON.stringify(vars) });
  assert.equal(r.status, 0);
  assert.deepEqual(JSON.parse(r.stdout), [{ name: 'A', value: 'one' }, { name: 'B', value: '' }]);
  assert.equal(r.stderr, '');
  assert.equal(r.calls[0].auth, token);
  assert.ok(r.calls[0].integrationName && r.calls[0].integrationVersion);
  assert.equal(r.calls[1].id, 'env-123');
});

test('SDK failure exits nonzero and leaks neither the error nor the token', () => {
  const token = marker();
  const r = run({
    OP_SERVICE_ACCOUNT_TOKEN: token,
    OP_ENVIRONMENT_ID: 'env-123',
    FAKE_ERROR: `rejected ${token}`,
  });
  assert.notEqual(r.status, 0);
  assert.equal(r.stdout, '');
  assert.ok(r.stderr.length > 0);
  assert.ok(!r.stdout.includes(token) && !r.stderr.includes(token));
  assert.ok(!r.stderr.includes('rejected'));
});
