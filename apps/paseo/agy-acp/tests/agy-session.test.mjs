// Unit tests for AgySession against tests/fixtures/mock-agy.mjs — an offline
// stand-in that never touches the network or a real agy binary. Run against
// the built dist/ (the shape actually shipped), not the TS source directly:
//   npm run build && node --test tests/agy-session.test.mjs
import assert from 'node:assert/strict';
import { after, afterEach, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { AgySession } from '../dist/agy-session.js';
import { cleanupMaterializedFixtures, materializeFixture } from './materialize-fixture.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const mockAgyPath = await materializeFixture(join(__dirname, 'fixtures', 'mock-agy.mjs'));

after(cleanupMaterializedFixtures);

describe('AgySession', () => {
  let session = null;

  afterEach(() => {
    if (session) {
      session.close();
      session = null;
    }
  });

  it('starts a session and emits the init event', async () => {
    session = new AgySession({ binaryPath: mockAgyPath, cwd: process.cwd() });

    const init = await session.start();
    assert.equal(init.event, 'init');
    assert.equal(init.conversation_id, 'mock-conv-1234');
    assert.equal(session.isRunning(), true);
    assert.equal(session.getConversationId(), 'mock-conv-1234');
  });

  it('streams step updates and resolves the prompt result', async () => {
    session = new AgySession({ binaryPath: mockAgyPath, cwd: process.cwd() });

    const stepUpdates = [];
    const result = await session.prompt('hello mock agy', (event) => {
      stepUpdates.push(event);
    });

    assert.equal(result.status, 'SUCCESS');
    assert.match(result.response, /Echo: hello mock agy/);
    assert.ok(stepUpdates.length >= 2);

    const textDelta = stepUpdates.find(
      (s) => s.step_update.step_type === 'agent_response' && s.step_update.text_delta
    );
    assert.ok(textDelta);
    assert.equal(textDelta.step_update.text_delta, 'Echo: hello mock agy');
  });

  it('supports multiple consecutive turns', async () => {
    session = new AgySession({ binaryPath: mockAgyPath, cwd: process.cwd() });

    const res1 = await session.prompt('first');
    assert.match(res1.response, /Echo: first/);

    const res2 = await session.prompt('second');
    assert.match(res2.response, /Echo: second/);
  });

  it('rejects the active prompt on cancel', async () => {
    session = new AgySession({ binaryPath: mockAgyPath, cwd: process.cwd() });
    await session.start();

    const promptPromise = session.prompt('__HANG__');
    setTimeout(() => session.cancel(), 50);

    await assert.rejects(promptPromise, /Prompt was cancelled/);
  });

  it('runs a new prompt right after cancelling one (the respawn race)', async () => {
    session = new AgySession({ binaryPath: mockAgyPath, cwd: process.cwd() });
    await session.start();

    const hung = session.prompt('__HANG__');
    await new Promise((resolve) => setTimeout(resolve, 50));
    session.cancel();
    await assert.rejects(hung, /Prompt was cancelled/);

    // An ACP client sends the replacement prompt as soon as the cancelled one
    // settles, while the SIGINT'd agy is still exiting. Before the fix this
    // wrote to the exiting process's stdin and the reply never arrived.
    const next = await session.prompt('after cancel');
    assert.match(next.response, /Echo: after cancel/);

    const again = await session.prompt('and again');
    assert.match(again.response, /Echo: and again/);
  });

  it('settles a prompt cancelled while agy is still restarting', async () => {
    session = new AgySession({ binaryPath: mockAgyPath, cwd: process.cwd() });
    await session.start();

    const hung = session.prompt('__HANG__');
    await new Promise((resolve) => setTimeout(resolve, 50));
    session.cancel();
    await assert.rejects(hung, /Prompt was cancelled/);

    // Cancelled before it ever reached agy: must settle now, not after the restart.
    const pending = session.prompt('never sent');
    session.cancel();
    await assert.rejects(pending, /Prompt was cancelled/);

    const next = await session.prompt('after restart');
    assert.match(next.response, /Echo: after restart/);
  });

  it('closes the process cleanly', async () => {
    session = new AgySession({ binaryPath: mockAgyPath, cwd: process.cwd() });
    await session.start();
    assert.equal(session.isRunning(), true);

    session.close();
    assert.equal(session.isRunning(), false);
  });

  it('reports a conversation mismatch when a resume lands in a new conversation', async () => {
    // mock-agy always answers with 'mock-conv-1234' regardless of the
    // requested --conversation=, so requesting a different id triggers the
    // mismatch path used to warn the user in acp-agent.ts.
    session = new AgySession({
      binaryPath: mockAgyPath,
      cwd: process.cwd(),
      conversationId: 'stale-conv-id',
    });
    await session.start();

    const mismatch = session.getConversationMismatch();
    assert.ok(mismatch);
    assert.equal(mismatch.requested, 'stale-conv-id');
    assert.equal(mismatch.actual, 'mock-conv-1234');
  });

  it('reconfigure() respawns on the next prompt, not mid-turn', async () => {
    session = new AgySession({ binaryPath: mockAgyPath, cwd: process.cwd() });
    await session.start();
    const firstPid = session.isRunning();
    assert.equal(firstPid, true);

    session.reconfigure({ model: 'a-different-model' });
    // The running process is untouched until the next prompt is written.
    assert.equal(session.isRunning(), true);

    const res = await session.prompt('after reconfigure');
    assert.match(res.response, /Echo: after reconfigure/);
  });
});
