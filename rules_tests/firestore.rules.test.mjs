// Security rules of the platform database (../firestore.rules), on the
// Firestore emulator: FIRESTORE_EMULATOR_PORT (default 8086) on 127.0.0.1.
//   npm test
import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, describe, test } from 'node:test';

import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, doc, getDoc, getDocs, serverTimestamp, deleteField, setDoc, updateDoc, writeBatch,
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
    await setDoc(doc(db, 'topology/current'), { resources: [] });
    await setDoc(doc(db, 'billing/breakdown'), { status: 'ok', total: 1 });
    await setDoc(doc(db, 'logs/l1'), { source: 'mac-worker', message: 'x' });
    await setDoc(doc(db, 'metrics/mac-worker~2026110410'), { source: 'mac-worker' });
  });
});

describe('reads', () => {
  const readable = ['threads/t1', 'messages/m1', 'status/mac', 'agent_mesh/state', 'autobench/latest', 'devstations/d1',
    'stats/usage', 'usage_days/2026-11-04', 'billing/current', 'billing/breakdown', 'topology/current', 'logs/l1', 'metrics/mac-worker~2026110410'];

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

  test('the operator files a thread: project, purpose, topic', async () => {
    await assertSucceeds(setDoc(doc(owner(), 'threads/p'), thread({ project: 'Financier', projectSet: true })));
    await assertSucceeds(updateDoc(doc(owner(), 'threads/t1'), { project: 'EOS', projectSet: true }));
    await assertSucceeds(updateDoc(doc(owner(), 'threads/t1'), { project: null, projectSet: true }));
    await assertSucceeds(updateDoc(doc(owner(), 'threads/t1'), { purpose: 'research' }));
    await assertSucceeds(updateDoc(doc(owner(), 'threads/t1'), { title: 'Topic', titleSet: true }));
  });

  test('the operator picks a conversation\'s model and effort, from the offered ones', async () => {
    await assertSucceeds(updateDoc(doc(owner(), 'threads/t1'), { model: 'claude-sonnet-5-5', effort: 'high' }));
    await assertSucceeds(updateDoc(doc(owner(), 'threads/t1'), { model: deleteField(), effort: deleteField() }));
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { model: 'gpt-5' }));
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { effort: 'ludicrous' }));
    await assertFails(updateDoc(doc(stranger(), 'threads/t1'), { model: 'claude-opus-5-5' }));
  });

  test('bad filing, and the costs and names only workers write, are refused', async () => {
    await assertFails(setDoc(doc(owner(), 'threads/p'), thread({ project: '' })));
    await assertFails(setDoc(doc(owner(), 'threads/p'), thread({ costUsd: 0 })));
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { project: 'x'.repeat(81) }));
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { purpose: 'dance' }));
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { titleSet: 'yes' }));
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { costUsd: 0 }));
    await assertFails(updateDoc(doc(owner(), 'threads/t1'), { namedAt: new Date() }));
    await assertFails(updateDoc(doc(stranger(), 'threads/t1'), { project: 'EOS' }));
  });

  test('strangers cannot start threads', async () => {
    await assertFails(setDoc(doc(stranger(), 'threads/x'), thread()));
    await assertFails(setDoc(doc(anonymous(), 'threads/x'), thread()));
  });
});

describe('chat projects', () => {
  test('the operator adds, renames and deletes projects', async () => {
    await assertSucceeds(setDoc(doc(owner(), 'chat_projects/eos'), { name: 'EOS', createdAt: serverTimestamp() }));
    await assertSucceeds(getDocs(collection(owner(), 'chat_projects')));
    await assertSucceeds(updateDoc(doc(owner(), 'chat_projects/eos'), { name: 'EOS NewsFrontier' }));
    await assertSucceeds(deleteDoc(doc(owner(), 'chat_projects/eos')));
  });

  test('malformed projects and other people are refused', async () => {
    await assertFails(setDoc(doc(owner(), 'chat_projects/a'), { name: '', createdAt: serverTimestamp() }));
    await assertFails(setDoc(doc(owner(), 'chat_projects/b'), { name: 'B', createdAt: serverTimestamp(), colour: 1 }));
    await assertFails(setDoc(doc(owner(), 'chat_projects/c'), { name: 'C', createdAt: new Date(0) }));
    await assertSucceeds(setDoc(doc(owner(), 'chat_projects/d'), { name: 'D', createdAt: serverTimestamp() }));
    await assertFails(updateDoc(doc(owner(), 'chat_projects/d'), { createdAt: new Date(0) }));
    await assertFails(setDoc(doc(stranger(), 'chat_projects/e'), { name: 'E', createdAt: serverTimestamp() }));
    await assertFails(getDocs(collection(stranger(), 'chat_projects')));
    await assertFails(deleteDoc(doc(stranger(), 'chat_projects/d')));
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

  test('messages carry attachments and mentions; with files the text may be empty', async () => {
    const file = { path: 'attachments/abcdefghij0123456789/a.png', name: 'a.png', contentType: 'image/png', size: 10 };
    const mention = { kind: 'thread', id: 't2', label: 'Plan' };
    await assertSucceeds(setDoc(doc(owner(), 'messages/a'), message({ attachments: [file], mentions: [mention] })));
    await assertSucceeds(setDoc(doc(owner(), 'messages/b'), message({ text: '', attachments: [file] })));
    await assertFails(setDoc(doc(owner(), 'messages/c'), message({ text: '', mentions: [mention] })));
    await assertFails(setDoc(doc(owner(), 'messages/d'), message({ attachments: Array(11).fill(file) })));
    await assertFails(setDoc(doc(owner(), 'messages/e'), message({ mentions: Array(11).fill(mention) })));
    await assertFails(setDoc(doc(owner(), 'messages/f'), message({ attachments: file })));
    await assertFails(setDoc(doc(owner(), 'messages/g'), message({ attachments: [] })));
    await assertFails(setDoc(doc(stranger(), 'messages/h'), message({ attachments: [file] })));
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
    await assertFails(setDoc(doc(owner(), 'topology/current'), { resources: [] }));
    await assertFails(setDoc(doc(owner(), 'billing/breakdown'), { status: 'ok' }));
  });
});

describe('factory', () => {
  const create = (extra = {}) => ({
    action: 'create', devstationId: 'atlas', project: 'Atlas', machineType: 'e2-standard-2',
    repoUrl: '', status: 'queued', createdAt: serverTimestamp(), ...extra,
  });

  test('the operator queues create, start, stop and destroy', async () => {
    await assertSucceeds(setDoc(doc(owner(), 'factory_requests/a'), create()));
    await assertSucceeds(setDoc(doc(owner(), 'factory_requests/disk'), create({ diskGb: 60 })));
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
      create({ diskGb: 20 }), create({ diskGb: 500 }), create({ diskGb: '60' }), create({ diskGb: 60.5 }),
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

describe('telemetry', () => {
  const entry = (extra = {}) => ({
    at: serverTimestamp(), source: 'console', component: 'audit', severity: 'info',
    message: 'Sent a message', fields: { threadId: 't1' },
    expireAt: new Date(Date.now() + 14 * 864e5), ...extra,
  });

  test('the Console adds its audit trail and client errors', async () => {
    await assertSucceeds(setDoc(doc(owner(), 'logs/a'), entry()));
    await assertSucceeds(setDoc(doc(owner(), 'logs/b'), entry({ component: 'client', severity: 'error' })));
  });

  test('it cannot pose as a service or keep entries for long', async () => {
    await assertFails(setDoc(doc(owner(), 'logs/a'), entry({ source: 'mac-worker' })));
    await assertFails(setDoc(doc(owner(), 'logs/b'), entry({ component: 'lifecycle' })));
    await assertFails(setDoc(doc(owner(), 'logs/c'), entry({ expireAt: new Date(Date.now() + 90 * 864e5) })));
    await assertFails(setDoc(doc(owner(), 'logs/d'), entry({ at: new Date(0) })));
    await assertFails(setDoc(doc(owner(), 'logs/e'), entry({ host: 'x' })));
    await assertFails(setDoc(doc(owner(), 'logs/f'), entry({ message: '' })));
    await assertFails(setDoc(doc(stranger(), 'logs/g'), entry()));
  });

  test('entries and metrics are never changed by clients', async () => {
    await assertFails(updateDoc(doc(owner(), 'logs/l1'), { message: 'y' }));
    await assertFails(deleteDoc(doc(owner(), 'logs/l1')));
    await assertFails(setDoc(doc(owner(), 'metrics/x'), { source: 'console' }));
  });
});

describe('TUCSON plan', () => {
  const node = (extra = {}) => ({
    kind: 'task', title: 'Write the brief', notes: '', status: 'planned', priority: 2,
    startAt: new Date('2026-11-18T02:00:00Z'), endAt: new Date('2026-11-18T03:00:00Z'), dueAt: null,
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(), ...extra,
  });
  const link = (extra = {}) => ({
    from: 'a', to: 'b', kind: 'branch', condition: 'visa approved', outcome: 'pending',
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(), ...extra,
  });
  const canvas = (extra = {}) => ({
    name: 'Plan', kind: 'timescale', order: 1, viewX: -120.5, viewY: 0, viewScale: 1, pxPerHour: 60,
    showAllTimed: true, createdAt: serverTimestamp(), updatedAt: serverTimestamp(), ...extra,
  });

  test('the owner writes, reads and deletes nodes, links, canvases and placements', async () => {
    const db = owner();
    await assertSucceeds(setDoc(doc(db, 'tucson_plan_nodes/a'), node()));
    await assertSucceeds(updateDoc(doc(db, 'tucson_plan_nodes/a'), { status: 'done', startAt: null }));
    await assertSucceeds(setDoc(doc(db, 'tucson_plan_links/l'), link()));
    await assertSucceeds(updateDoc(doc(db, 'tucson_plan_links/l'), { outcome: 'taken' }));
    await assertSucceeds(setDoc(doc(db, 'tucson_plan_canvases/c'), canvas()));
    await assertSucceeds(setDoc(doc(db, 'tucson_plan_placements/c__a'), { canvasId: 'c', nodeId: 'a', x: 10, y: 1.5 }));
    // Undo restores earlier states, old createdAt included.
    await assertSucceeds(setDoc(doc(db, 'tucson_plan_nodes/b'), node({ createdAt: new Date('2026-01-01') })));
    await assertSucceeds(getDocs(collection(db, 'tucson_plan_nodes')));
    for (const p of ['tucson_plan_nodes/a', 'tucson_plan_links/l', 'tucson_plan_canvases/c', 'tucson_plan_placements/c__a']) {
      await assertSucceeds(deleteDoc(doc(db, p)));
    }
  });

  test('malformed documents are refused', async () => {
    const db = owner();
    await assertFails(setDoc(doc(db, 'tucson_plan_nodes/a'), node({ kind: 'epic' })));
    await assertFails(setDoc(doc(db, 'tucson_plan_nodes/a'), node({ priority: 4 })));
    await assertFails(setDoc(doc(db, 'tucson_plan_nodes/a'), node({ startAt: 'tomorrow' })));
    await assertFails(setDoc(doc(db, 'tucson_plan_nodes/a'), node({ owner: 'x' })));
    await assertFails(setDoc(doc(db, 'tucson_plan_nodes/a'), node({ title: 'x'.repeat(501) })));
    await assertFails(setDoc(doc(db, 'tucson_plan_links/l'), link({ to: 'a' })));
    await assertFails(setDoc(doc(db, 'tucson_plan_links/l'), link({ outcome: 'maybe' })));
    await assertFails(setDoc(doc(db, 'tucson_plan_canvases/c'), canvas({ kind: 'kanban' })));
    await assertFails(setDoc(doc(db, 'tucson_plan_canvases/c'), canvas({ name: '' })));
    await assertFails(setDoc(doc(db, 'tucson_plan_canvases/c'), canvas({ viewScale: 0 })));
    await assertFails(setDoc(doc(db, 'tucson_plan_placements/c__b'), { canvasId: 'c', nodeId: 'a', x: 0, y: 0 }));
    await assertFails(setDoc(doc(db, 'tucson_plan_placements/c__a'), { canvasId: 'c', nodeId: 'a', x: '0', y: 0 }));
  });

  test('nobody else reads or writes the plan', async () => {
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), 'tucson_plan_nodes/a'), { kind: 'task', title: 'x' }));
    for (const db of [otherAccount(), unverified(), stranger(), anonymous()]) {
      await assertFails(getDoc(doc(db, 'tucson_plan_nodes/a')));
      await assertFails(setDoc(doc(db, 'tucson_plan_nodes/b'), node()));
      await assertFails(deleteDoc(doc(db, 'tucson_plan_nodes/a')));
      await assertFails(setDoc(doc(db, 'tucson_plan_placements/c__a'), { canvasId: 'c', nodeId: 'a', x: 0, y: 0 }));
    }
  });

  test('calendar events mirrored into the plan, and TUCSON\'s change log', async () => {
    const db = owner();
    await assertSucceeds(setDoc(doc(db, 'tucson_plan_nodes/gcal_1'), node({
      kind: 'event', source: 'calendar', calendarId: 'primary', eventId: 'ev1', link: 'https://calendar.google.com/x',
    })));
    await assertFails(setDoc(doc(db, 'tucson_plan_nodes/gcal_2'), node({ source: 'notion' })));
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'tucson_plan_changes/c1'), { summary: 'Added task', writes: [] });
      await setDoc(doc(ctx.firestore(), 'tucson_plan_sync/calendar'), { events: 3 });
    });
    await assertSucceeds(getDoc(doc(db, 'tucson_plan_changes/c1')));
    await assertSucceeds(getDoc(doc(db, 'tucson_plan_sync/calendar')));
    await assertSucceeds(updateDoc(doc(db, 'tucson_plan_changes/c1'), { revertedAt: new Date() }));
    await assertFails(updateDoc(doc(db, 'tucson_plan_changes/c1'), { summary: 'rewritten' }));
    await assertFails(setDoc(doc(db, 'tucson_plan_changes/c2'), { summary: 'forged' }));
    await assertFails(deleteDoc(doc(db, 'tucson_plan_changes/c1')));
    await assertFails(setDoc(doc(db, 'tucson_plan_sync/calendar'), { events: 0 }));
    await assertFails(getDoc(doc(stranger(), 'tucson_plan_changes/c1')));
  });
});
