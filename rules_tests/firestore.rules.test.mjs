// Security rules of the platform database (../firestore.rules), on the
// Firestore emulator: FIRESTORE_EMULATOR_PORT (default 8086) on 127.0.0.1.
//   npm test
import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, describe, test } from 'node:test';

import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, doc, getDoc, getDocs, serverTimestamp, setDoc, updateDoc, writeBatch,
} from 'firebase/firestore';

const port = Number.parseInt(process.env.FIRESTORE_EMULATOR_PORT ?? '8086', 10);
let env;

const owner = () => env.authenticatedContext('owner', {
  email: 'siddharth.chitikela@gmail.com', email_verified: true,
}).firestore();
// The operator's other Google account is deliberately not admitted.
const otherAccount = () => env.authenticatedContext('other', {
  email: 'obsidian.infinitum@gmail.com', email_verified: true,
}).firestore();
const unverified = () => env.authenticatedContext('u', {
  email: 'siddharth.chitikela@gmail.com', email_verified: false,
}).firestore();
const stranger = () => env.authenticatedContext('s', {
  email: 'someone@example.com', email_verified: true,
}).firestore();
const anonymous = () => env.unauthenticatedContext().firestore();

const thread = (extra = {}) => ({
  agent: 'genie', title: 'Hello', createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
  closed: false, ...extra,
});
const message = (extra = {}) => ({
  threadId: 't1', role: 'operator', kind: 'turn', text: 'hi', status: 'queued',
  createdAt: serverTimestamp(), ...extra,
});

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-va-console',
    firestore: { host: '127.0.0.1', port, rules: await readFile(new URL('../firestore.rules', import.meta.url), 'utf8') },
  });
});
after(() => env.cleanup());

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'threads/t1'), { agent: 'genie', title: 'T', closed: false });
    await setDoc(doc(db, 'threads/closed'), { agent: 'genie', title: 'C', closed: true });
    await setDoc(doc(db, 'messages/m1'), { threadId: 't1', role: 'agent', text: 'reply' });
    await setDoc(doc(db, 'status/mac'), { host: 'mac' });
    await setDoc(doc(db, 'agent_mesh/state'), { json: '{}' });
    await setDoc(doc(db, 'autobench/latest'), { nav: 1 });
    await setDoc(doc(db, 'autobench/latest/days/2026-11-04'), { nav: 1 });
    await setDoc(doc(db, 'devstations/d1'), { project: 'p' });
    await setDoc(doc(db, 'secrets/x'), { v: 1 });
  });
});

describe('reads', () => {
  const readable = ['threads/t1', 'messages/m1', 'status/mac', 'agent_mesh/state', 'autobench/latest', 'devstations/d1'];

  test('the operator reads the Console data', async () => {
    for (const path of readable) {
      await assertSucceeds(getDoc(doc(owner(), path)));
    }
    await assertSucceeds(getDocs(collection(owner(), 'threads')));
  });

  test('nobody else reads anything', async () => {
    for (const db of [anonymous(), stranger(), unverified(), otherAccount()]) {
      for (const path of readable) await assertFails(getDoc(doc(db, path)));
      await assertFails(getDocs(collection(db, 'messages')));
    }
  });

  test('collections outside the Console stay closed, even to the operator', async () => {
    await assertFails(getDoc(doc(owner(), 'secrets/x')));
    await assertFails(getDoc(doc(owner(), 'autobench/latest/days/2026-11-04')));
  });
});

describe('threads', () => {
  test('the operator starts a thread with its first message in one batch', async () => {
    const db = owner();
    const batch = writeBatch(db);
    batch.set(doc(db, 'threads/new'), thread());
    batch.set(doc(db, 'messages/first'), message({ threadId: 'new' }));
    await assertSucceeds(batch.commit());
  });

  test('malformed threads are refused', async () => {
    await assertFails(setDoc(doc(owner(), 'threads/a'), thread({ agent: '../genie' })));
    await assertFails(setDoc(doc(owner(), 'threads/b'), thread({ title: '' })));
    await assertFails(setDoc(doc(owner(), 'threads/c'), thread({ closed: true })));
    await assertFails(setDoc(doc(owner(), 'threads/d'), thread({ lastMessage: 'forged' })));
    await assertFails(setDoc(doc(owner(), 'threads/e'), thread({ createdAt: new Date(0) })));
  });

  test('threads are never changed or deleted by clients', async () => {
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { title: 'x' }));
    await assertFails(deleteDoc(doc(owner(), 'threads/t1')));
  });

  test('strangers cannot start threads', async () => {
    await assertFails(setDoc(doc(stranger(), 'threads/x'), thread()));
    await assertFails(setDoc(doc(anonymous(), 'threads/x'), thread()));
  });
});

describe('messages', () => {
  test('the operator queues turns and close requests', async () => {
    await assertSucceeds(setDoc(doc(owner(), 'messages/a'), message()));
    await assertSucceeds(setDoc(doc(owner(), 'messages/b'), message({ kind: 'close' })));
  });

  test('clients cannot forge replies or statuses', async () => {
    await assertFails(setDoc(doc(owner(), 'messages/a'), message({ role: 'agent' })));
    await assertFails(setDoc(doc(owner(), 'messages/b'), message({ status: 'done' })));
    await assertFails(setDoc(doc(owner(), 'messages/c'), message({ kind: 'shell' })));
    await assertFails(setDoc(doc(owner(), 'messages/d'), message({ claimedBy: 'mac' })));
    await assertFails(setDoc(doc(owner(), 'messages/e'), message({ text: '' })));
    await assertFails(setDoc(doc(owner(), 'messages/f'), message({ text: 'x'.repeat(20001) })));
  });

  test('messages need an open thread', async () => {
    await assertFails(setDoc(doc(owner(), 'messages/a'), message({ threadId: 'missing' })));
    await assertFails(setDoc(doc(owner(), 'messages/b'), message({ threadId: 'closed' })));
  });

  test('messages are never changed or deleted by clients', async () => {
    await assertFails(updateDoc(doc(owner(), 'messages/m1'), { text: 'x' }));
    await assertFails(deleteDoc(doc(owner(), 'messages/m1')));
  });

  test('system documents are read-only', async () => {
    await assertFails(setDoc(doc(owner(), 'status/mac'), { host: 'evil' }));
    await assertFails(setDoc(doc(owner(), 'agent_mesh/state'), { json: '{}' }));
    await assertFails(setDoc(doc(owner(), 'autobench/latest'), { nav: 0 }));
    await assertFails(setDoc(doc(owner(), 'devstations/d2'), { project: 'p' }));
  });
});
