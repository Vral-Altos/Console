// Security rules of the project files (../project_files.rules), on the
// Storage emulator: STORAGE_EMULATOR_PORT (default 9199) on 127.0.0.1.
//   npm run test:projects
import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, test } from 'node:test';

import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { deleteObject, getBytes, listAll, ref, uploadBytes, uploadString } from 'firebase/storage';

const port = Number.parseInt(process.env.STORAGE_EMULATOR_PORT ?? '9199', 10);
let env;

const owner = () => env.authenticatedContext('owner', {
  email: 'siddharth.chitikela@gmail.com', email_verified: true,
}).storage();
const otherAccount = () => env.authenticatedContext('other', {
  email: 'obsidian.infinitum@gmail.com', email_verified: true,
}).storage();
const unverified = () => env.authenticatedContext('u', {
  email: 'siddharth.chitikela@gmail.com', email_verified: false,
}).storage();
const anonymous = () => env.unauthenticatedContext().storage();

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-va-console',
    storage: { host: '127.0.0.1', port, rules: await readFile(new URL('../project_files.rules', import.meta.url), 'utf8') },
  });
});
after(() => env.cleanup());

beforeEach(async () => {
  await env.clearStorage();
  await env.withSecurityRulesDisabled(async (ctx) => {
    await uploadString(ref(ctx.storage(), 'projects/atlas/STATE.md'), '# State');
    await uploadString(ref(ctx.storage(), 'agents/genie/state/profile.md'), 'private');
  });
});

test('the operator reads, lists, writes and deletes project files', async () => {
  const s = owner();
  await assertSucceeds(getBytes(ref(s, 'projects/atlas/STATE.md')));
  await assertSucceeds(listAll(ref(s, 'projects/atlas')));
  await assertSucceeds(uploadString(ref(s, 'projects/atlas/notes/call.md'), 'notes'));
  await assertSucceeds(uploadString(ref(s, 'projects/atlas/STATE.md'), '# State\n\nEdited'));
  await assertSucceeds(deleteObject(ref(s, 'projects/atlas/notes/call.md')));
});

test('agents\' private state is never reachable through Firebase', async () => {
  await assertFails(getBytes(ref(owner(), 'agents/genie/state/profile.md')));
  await assertFails(uploadString(ref(owner(), 'agents/genie/state/profile.md'), 'x'));
  await assertFails(listAll(ref(owner(), 'agents')));
});

test('bad ids, hidden files and big files are refused', async () => {
  await assertFails(uploadString(ref(owner(), 'projects/Bad Id/a.md'), 'x'));
  await assertFails(uploadString(ref(owner(), 'projects/atlas/.manifest.json'), '{}'));
  await assertFails(uploadString(ref(owner(), 'projects/atlas/sub/.hidden'), 'x'));
  await assertFails(uploadBytes(ref(owner(), 'projects/atlas/big.bin'), new Uint8Array(5 * 1024 * 1024 + 1)));
});

test('nobody else gets in', async () => {
  for (const s of [otherAccount(), unverified(), anonymous()]) {
    await assertFails(getBytes(ref(s, 'projects/atlas/STATE.md')));
    await assertFails(uploadString(ref(s, 'projects/atlas/x.md'), 'x'));
    await assertFails(deleteObject(ref(s, 'projects/atlas/STATE.md')));
  }
});
