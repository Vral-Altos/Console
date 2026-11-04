// Security rules of the attachments bucket (../storage.rules), on the
// Storage emulator: STORAGE_EMULATOR_PORT (default 9199) on 127.0.0.1.
//   npm run test:storage
import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, describe, test } from 'node:test';

import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { deleteObject, getBytes, ref, uploadBytes, uploadString } from 'firebase/storage';

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

const id = 'abcdefghij0123456789';
const png = new Uint8Array([137, 80, 78, 71, 1, 2, 3]);

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-va-console',
    storage: { host: '127.0.0.1', port, rules: await readFile(new URL('../storage.rules', import.meta.url), 'utf8') },
  });
});
after(() => env.cleanup());

beforeEach(async () => {
  await env.clearStorage();
  await env.withSecurityRulesDisabled(async (ctx) => {
    await uploadBytes(ref(ctx.storage(), `attachments/${id}/kept.png`), png);
    await uploadString(ref(ctx.storage(), 'elsewhere/x.txt'), 'x');
  });
});

describe('attachments', () => {
  test('the operator uploads, reads and removes files', async () => {
    await assertSucceeds(uploadBytes(ref(owner(), 'attachments/zyxwvutsrq9876543210/chart.png'), png, { contentType: 'image/png' }));
    await assertSucceeds(getBytes(ref(owner(), `attachments/${id}/kept.png`)));
    await assertSucceeds(deleteObject(ref(owner(), `attachments/${id}/kept.png`)));
  });

  test('uploads stay within their limits', async () => {
    const refused = {
      shortId: 'attachments/short/a.png',
      longName: `attachments/zyxwvutsrq9876543210/${'n'.repeat(141)}`,
      deeper: 'attachments/zyxwvutsrq9876543210/deep/a.png',
    };
    for (const [why, path] of Object.entries(refused)) {
      await assertFails(uploadBytes(ref(owner(), path), png)).catch((e) => { throw new Error(`${why}: ${e.message}`); });
    }
    await assertFails(uploadBytes(ref(owner(), 'attachments/zyxwvutsrq9876543210/empty.txt'), new Uint8Array())).catch((e) => { throw new Error(`empty: ${e.message}`); });
    await assertFails(uploadBytes(ref(owner(), 'attachments/zyxwvutsrq9876543210/big.bin'), new Uint8Array(25 * 1024 * 1024 + 1))).catch((e) => { throw new Error(`big: ${e.message}`); });
  });

  test('nobody else reads, uploads or removes', async () => {
    for (const s of [otherAccount, unverified, anonymous]) {
      await assertFails(getBytes(ref(s(), `attachments/${id}/kept.png`)));
      await assertFails(uploadBytes(ref(s(), 'attachments/zyxwvutsrq9876543210/a.png'), png));
      await assertFails(deleteObject(ref(s(), `attachments/${id}/kept.png`)));
    }
  });

  test('the rest of the bucket is closed, even to the operator', async () => {
    await assertFails(getBytes(ref(owner(), 'elsewhere/x.txt')));
    await assertFails(uploadString(ref(owner(), 'elsewhere/y.txt'), 'y'));
  });
});
