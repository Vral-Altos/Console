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
    await setDoc(doc(db, 'approvals/a1'), { requestedBy: 'director-x', action: 'spend', status: 'pending' });
    await setDoc(doc(db, 'approvals/done'), { requestedBy: 'director-x', action: 'spend', status: 'approved' });
    await setDoc(doc(db, 'factory_requests/r1'), { action: 'stop', devstationId: 'ds', status: 'done' });
    await setDoc(doc(db, 'messages/q1'), { threadId: 't1', role: 'operator', text: 'q', status: 'queued' });
    await setDoc(doc(db, 'messages/r1'), { threadId: 't1', role: 'operator', text: 'r', status: 'running' });
    await setDoc(doc(db, 'messages/d1'), { threadId: 't1', role: 'operator', text: 'd', status: 'done' });
    await setDoc(doc(db, 'stats/usage'), { turns: 1 });
    await setDoc(doc(db, 'usage_days/2026-11-04'), { turns: 1 });
    await setDoc(doc(db, 'billing/current'), { costAmount: 1 });
  });
});

describe('reads', () => {
  const readable = ['threads/t1', 'messages/m1', 'status/mac', 'agent_mesh/state', 'autobench/latest', 'devstations/d1',
    'stats/usage', 'usage_days/2026-11-04', 'billing/current'];

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

  test('the operator renames, pins and archives a thread', async () => {
    await assertSucceeds(updateDoc(doc(owner(), 'threads/t1'), { title: 'Renamed' }));
    await assertSucceeds(updateDoc(doc(owner(), 'threads/t1'), { pinned: true }));
    await assertSucceeds(updateDoc(doc(owner(), 'threads/t1'), { archived: true }));
  });

  test('other thread changes, and deletes, are refused', async () => {
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { title: '' }));
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { closed: true, title: 'x' }));
    await assertFails(updateDoc(doc(owner(), 'threads/closed'), { closed: false }));
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { agent: 'roman' }));
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { pinned: 'yes' }));
    await assertFails(updateDoc(doc(stranger(), 'threads/t1'), { title: 'x' }));
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

  test('the operator cancels a queued message or asks a running one to stop', async () => {
    await assertSucceeds(updateDoc(doc(owner(), 'messages/q1'), { status: 'cancelled' }));
    await assertSucceeds(updateDoc(doc(owner(), 'messages/r1'), { cancelRequested: true }));
  });

  test('messages are otherwise never changed or deleted by clients', async () => {
    await assertFails(updateDoc(doc(owner(), 'messages/m1'), { text: 'x' }));
    await assertFails(updateDoc(doc(owner(), 'messages/q1'), { status: 'done' }));
    await assertFails(updateDoc(doc(owner(), 'messages/q1'), { status: 'cancelled', text: 'x' }));
    await assertFails(updateDoc(doc(owner(), 'messages/r1'), { status: 'cancelled' }));
    await assertFails(updateDoc(doc(owner(), 'messages/d1'), { cancelRequested: true }));
    await assertFails(updateDoc(doc(owner(), 'messages/d1'), { status: 'cancelled' }));
    await assertFails(updateDoc(doc(owner(), 'messages/m1'), { cancelRequested: true }));
    await assertFails(updateDoc(doc(stranger(), 'messages/q1'), { status: 'cancelled' }));
    await assertFails(deleteDoc(doc(owner(), 'messages/m1')));
  });

  test('system documents are read-only', async () => {
    await assertFails(setDoc(doc(owner(), 'status/mac'), { host: 'evil' }));
    await assertFails(setDoc(doc(owner(), 'agent_mesh/state'), { json: '{}' }));
    await assertFails(setDoc(doc(owner(), 'autobench/latest'), { nav: 0 }));
    await assertFails(setDoc(doc(owner(), 'devstations/d2'), { project: 'p' }));
    await assertFails(setDoc(doc(owner(), 'stats/usage'), { turns: 0 }));
    await assertFails(setDoc(doc(owner(), 'usage_days/2026-11-05'), { turns: 0 }));
    await assertFails(setDoc(doc(owner(), 'billing/current'), { costAmount: 0 }));
  });
});

describe('factory', () => {
  const create = (extra = {}) => ({
    action: 'create', devstationId: 'atlas', project: 'Atlas', machineType: 'e2-standard-2',
    repoUrl: '', status: 'queued', createdAt: serverTimestamp(), ...extra,
  });

  test('the operator queues create, start, stop and destroy', async () => {
    await assertSucceeds(setDoc(doc(owner(), 'factory_requests/a'), create()));
    for (const action of ['start', 'stop', 'destroy']) {
      await assertSucceeds(setDoc(doc(owner(), `factory_requests/${action}`),
        { action, devstationId: 'atlas', status: 'queued', createdAt: serverTimestamp() }));
    }
    await assertSucceeds(getDoc(doc(owner(), 'factory_requests/r1')));
  });

  test('malformed or forged requests are refused', async () => {
    const bad = [
      create({ action: 'reboot' }), create({ devstationId: 'Bad_Id' }), create({ status: 'done' }),
      create({ machineType: 'n2-highmem-96' }), create({ project: "x'; rm -rf /" }),
      create({ buildId: 'forged' }), create({ createdAt: new Date(0) }),
    ];
    for (const [i, b] of bad.entries()) await assertFails(setDoc(doc(owner(), `factory_requests/b${i}`), b));
    await assertFails(updateDoc(doc(owner(), 'factory_requests/r1'), { status: 'queued' }));
  });

  test('nobody else touches the Factory', async () => {
    for (const db of [anonymous(), stranger(), otherAccount()]) {
      await assertFails(setDoc(doc(db, 'factory_requests/x'), create()));
      await assertFails(getDoc(doc(db, 'factory_requests/r1')));
    }
  });
});

describe('approvals', () => {
  test('the operator approves or rejects a pending request', async () => {
    await assertSucceeds(updateDoc(doc(owner(), 'approvals/a1'), { status: 'approved', decidedAt: serverTimestamp() }));
  });

  test('decided requests, other fields and other people are refused', async () => {
    await assertFails(updateDoc(doc(owner(), 'approvals/done'), { status: 'rejected', decidedAt: serverTimestamp() }));
    await assertFails(updateDoc(doc(owner(), 'approvals/a1'), { action: 'other', status: 'approved', decidedAt: serverTimestamp() }));
    await assertFails(updateDoc(doc(owner(), 'approvals/a1'), { status: 'maybe', decidedAt: serverTimestamp() }));
    await assertFails(setDoc(doc(owner(), 'approvals/new'), { requestedBy: 'me', status: 'approved' }));
    await assertFails(updateDoc(doc(stranger(), 'approvals/a1'), { status: 'approved', decidedAt: serverTimestamp() }));
    await assertFails(updateDoc(doc(otherAccount(), 'approvals/a1'), { status: 'approved', decidedAt: serverTimestamp() }));
  });
});
