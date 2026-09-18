// Drives AntigravityAcpAgent through the real ACP protocol (in-process, via
// the SDK's client<->agent direct connection) against fixtures/fake-agy.mjs.
// No real agy binary, no real Paseo daemon — this is the "fake-agy matrix"
// unit-level proof for the verified fixes: interrupt/cancel respawn race,
// session load/resume + transcript replay, model/effort/mode config options
// sourced from `agy models` (no static list), tool titles, slash commands via
// `agy --print`, image attachment, agy ERROR -> turn failure/recovery.
import assert from 'node:assert/strict';
import * as acp from '@agentclientprotocol/sdk';
import { existsSync } from 'node:fs';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, afterEach, before, beforeEach, describe, it } from 'node:test';
import { AntigravityAcpAgent } from '../dist/acp-agent.js';
import { cleanupMaterializedFixtures, materializeFixture } from './materialize-fixture.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const fakeAgyPath = await materializeFixture(join(__dirname, 'fixtures', 'fake-agy.mjs'));

let workDir;
let stateDir;
let liveAgents;

after(cleanupMaterializedFixtures);

before(async () => {
  workDir = await mkdtemp(join(tmpdir(), 'agy-acp-matrix-ws-'));
  stateDir = await mkdtemp(join(tmpdir(), 'agy-acp-matrix-state-'));
});

after(async () => {
  await rm(workDir, { recursive: true, force: true });
  await rm(stateDir, { recursive: true, force: true });
});

beforeEach(() => {
  liveAgents = [];
});

// Every fake-agy child spawned during a test is a real OS process with open
// stdio pipes; leaving one running keeps the test file's event loop alive
// past all tests reporting done, and `node --test` then times out the whole
// file waiting for it to exit on its own. closeAll() SIGTERMs them.
afterEach(() => {
  for (const agent of liveAgents) {
    agent.closeAll();
  }
});

function newAgent(overrides = {}) {
  const agent = new AntigravityAcpAgent({
    binaryPath: fakeAgyPath,
    dangerouslySkipPermissions: true,
    stateDir,
    ...overrides,
  });
  liveAgents.push(agent);
  return { agent, app: agent.createApp() };
}

// Drains session_update notifications until the turn's stop message, since
// PromptResponse itself carries only stopReason/usage — the reply text and
// tool-call detail arrive as separate session/update notifications.
async function drainToStop(session) {
  const events = [];
  let text = '';
  for (;;) {
    const msg = await session.nextUpdate();
    if (msg.kind === 'stop') {
      return { events, text, response: msg.response };
    }
    events.push(msg.update);
    if (msg.update.sessionUpdate === 'agent_message_chunk' && msg.update.content?.type === 'text') {
      text += msg.update.content.text;
    }
  }
}

describe('fake-agy matrix', () => {
  it('lists models from `agy models` in the new-session config options (no static list)', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const modelOption = session.newSessionResponse.configOptions.find((o) => o.id === 'model');
        assert.ok(modelOption, 'expected a "model" config option');
        const ids = modelOption.options.map((o) => o.value);
        // From fixtures/fake-agy.mjs's `models` subcommand output, not a hardcoded list.
        assert.ok(ids.includes('claude-opus-4-6-thinking'));
        // One row per family: the effort is picked in the thinking selector, not in the model name.
        assert.ok(ids.includes('gemini-3.8-flash'));
        assert.ok(!ids.includes('gemini-3.8-flash-high'));
        assert.equal(modelOption.currentValue, 'gemini-3.8-flash');
        const thinking = session.newSessionResponse.configOptions.find((o) => o.id === 'thinking');
        assert.equal(thinking.currentValue, 'medium');
      });
    });
  });

  it('uses a live default when the preferred family is absent and rejects a missing explicit default', async () => {
    const binary = join(workDir, 'live-catalog-agy.mjs');
    await writeFile(binary, `#!/usr/bin/env node
import { spawn } from 'node:child_process';
if (process.argv[2] === 'models') {
  process.stdout.write('gemini-3.7-flash-medium\\tGemini 3.7 Flash (Medium)\\n');
} else {
  const child = spawn(${JSON.stringify(fakeAgyPath)}, process.argv.slice(2), { stdio: 'inherit' });
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
  child.on('exit', (code) => process.exit(code ?? 1));
}
`, { mode: 0o700 });
    const { app } = newAgent({ binaryPath: binary });
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const model = session.newSessionResponse.configOptions.find((o) => o.id === 'model');
        assert.equal(model.currentValue, 'gemini-3.7-flash');
        assert.deepEqual(model.options.map((o) => o.value), ['gemini-3.7-flash']);
        const responsePromise = session.prompt('live default works');
        const reply = await drainToStop(session);
        await responsePromise;
        assert.equal(reply.response.stopReason, 'end_turn');
      });
    });
    const invalid = newAgent({ binaryPath: binary, defaultModel: 'gemini-3.8-flash-medium' });
    await assert.rejects(acp.client().connectWith(invalid.app, async (cx) => {
      await cx.buildSession(workDir).withSession(async () => assert.fail('missing model must not open'));
    }), /Configured agy model is not in the live catalog/);
  });

  it('advertises discovered skills in available_commands_update', async () => {
    const fakeHome = await mkdtemp(join(tmpdir(), 'agy-acp-fakehome-'));
    const skillsRoot = join(fakeHome, 'skills');
    await mkdir(join(skillsRoot, 'matrix-skill'), { recursive: true });
    await writeFile(
      join(skillsRoot, 'matrix-skill', 'SKILL.md'),
      '---\nname: matrix-skill\ndescription: Matrix fixture skill\n---\n',
    );
    await mkdir(join(fakeHome, '.gemini', 'config'), { recursive: true });
    await writeFile(
      join(fakeHome, '.gemini', 'config', 'skills.json'),
      JSON.stringify({ entries: [{ path: skillsRoot }] }),
    );
    const { app } = newAgent({ home: fakeHome });
    try {
      await acp.client().connectWith(app, async (cx) => {
        await cx.buildSession(workDir).withSession(async (session) => {
          const deadline = Date.now() + 10_000;
          for (;;) {
            assert.ok(Date.now() < deadline, 'timed out waiting for available_commands_update');
            const msg = await session.nextUpdate();
            assert.notEqual(msg.kind, 'stop', 'session ended before available_commands_update');
            if (msg.update?.sessionUpdate === 'available_commands_update') {
              const names = msg.update.availableCommands.map((c) => c.name);
              assert.ok(names.includes('usage'), 'local commands still advertised');
              assert.ok(names.includes('matrix-skill'), 'discovered skill advertised');
              return;
            }
          }
        });
      });
    } finally {
      await rm(fakeHome, { recursive: true, force: true });
    }
  });

  it('runs a basic turn and streams the reply text', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const responsePromise = session.prompt('reply with word HELLO');
        const { text, response } = await drainToStop(session);
        await responsePromise;
        assert.equal(response.stopReason, 'end_turn');
        assert.match(text, /HELLO/);
      });
    });
  });

  it('reports tool_call updates with a human title and kind', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const responsePromise = session.prompt('please TOOLSTEP then reply with word DONE');
        const { events } = await drainToStop(session);
        await responsePromise;
        const toolCall = events.find((e) => e.sessionUpdate === 'tool_call');
        assert.ok(toolCall, 'expected a tool_call update');
        assert.equal(toolCall.kind, 'execute');
        assert.match(toolCall.title, /^Run /);
      });
    });
  });

  it('interrupt: cancel mid-turn, then the very next prompt on the same session succeeds (the respawn race)', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const hungPromise = session.prompt('please sleep then reply with word NEVER');
        // Let the turn actually start (past user_input DONE + tool ACTIVE) before cancelling.
        await new Promise((r) => setTimeout(r, 80));
        await cx.notify(acp.methods.agent.session.cancel, { sessionId: session.sessionId });
        // Drain this turn's queued updates (including its 'stop' message) before
        // sending the next prompt — an undrained stop would be the first thing
        // the next drainToStop() sees, misattributing it to the wrong turn.
        const { response: cancelled } = await drainToStop(session);
        await hungPromise;
        assert.equal(cancelled.stopReason, 'cancelled');

        // Sent immediately, while the SIGINT'd fake-agy may still be exiting.
        const nextPromise = session.prompt('reply with word AFTERCANCEL');
        const { text, response } = await drainToStop(session);
        await nextPromise;
        assert.equal(response.stopReason, 'end_turn');
        assert.match(text, /AFTERCANCEL/);
      });
    });
  });

  it('double interrupt: a second rapid-fire cancel never wedges the session', async () => {
    // AgySession's own unit test ("settles a prompt cancelled while agy
    // restarts") pins the exact pre-write-cancel timing deterministically via
    // direct synchronous calls. Over real ACP request/notification RPCs there
    // is no such guarantee of who reaches the server first, so this test
    // instead proves the property that actually matters at this layer: firing
    // cancel twice in a row, with no delay, never hangs or corrupts session
    // state — the session keeps serving turns afterward regardless of which
    // exact stopReason the raced second prompt received.
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const first = session.prompt('please sleep then reply with word A');
        await new Promise((r) => setTimeout(r, 80));
        await cx.notify(acp.methods.agent.session.cancel, { sessionId: session.sessionId });
        const { response: firstStop } = await drainToStop(session);
        await first;
        assert.equal(firstStop.stopReason, 'cancelled');

        // Cancelled again immediately — may land before or after agy sees it.
        const second = session.prompt('reply with word B');
        await cx.notify(acp.methods.agent.session.cancel, { sessionId: session.sessionId });
        const { response: secondStop } = await drainToStop(session);
        await second;
        assert.ok(['cancelled', 'end_turn'].includes(secondStop.stopReason));

        const third = session.prompt('reply with word C');
        const { text } = await drainToStop(session);
        await third;
        assert.match(text, /\bC\b/);
      });
    });
  });

  it('agy ERROR with no response becomes a failed turn', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        await assert.rejects(session.prompt('trigger FAIL503 please'));
      });
    });
  });

  it('agy ERROR after a real reply keeps the answer and ends the turn (not a thrown failure)', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const responsePromise = session.prompt('REPLY_THEN_FAIL reply with word LIMPING');
        const { text, response } = await drainToStop(session);
        await responsePromise;
        assert.equal(response.stopReason, 'end_turn');
        assert.match(text, /LIMPING/);
        assert.match(text, /agy reported an error after replying/);
      });
    });
  });

  it('denied actions are surfaced as a message in the transcript', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const responsePromise = session.prompt('DENY reply with word OK');
        const { text } = await drainToStop(session);
        await responsePromise;
        assert.match(text, /auto-denied/);
      });
    });
  });

  it('switching model/effort via config option takes effect from the next turn without cutting the current one', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const setResult = await cx.request(acp.methods.agent.session.setConfigOption, {
          sessionId: session.sessionId,
          configId: 'model',
          value: 'claude-opus-4-6-thinking',
        });
        const modelOption = setResult.configOptions.find((o) => o.id === 'model');
        assert.equal(modelOption.currentValue, 'claude-opus-4-6-thinking');

        // The reconfigure is deferred (restartPending), so this turn still runs to completion.
        const responsePromise = session.prompt('reply with word STILLALIVE');
        const { text, response } = await drainToStop(session);
        await responsePromise;
        assert.equal(response.stopReason, 'end_turn');
        assert.match(text, /STILLALIVE/);
      });
    });
  });

  it('mode switch marks bypassPermissions modes as unattended-capable', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const bypass = session.newSessionResponse.modes.availableModes.find((m) => m.id === 'bypassPermissions');
        assert.ok(bypass);
        assert.equal(bypass._meta.paseo.isUnattended, true);
        const plan = session.newSessionResponse.modes.availableModes.find((m) => m.id === 'plan');
        assert.equal(plan._meta, undefined);
      });
    });
  });

  it('[S9] a session opened with no explicit permission opt-in defaults to readOnly, not bypass, and does not advertise itself as unattended', async () => {
    // No dangerouslySkipPermissions override at all — the shape a child agent
    // spawned by an unattended parent of another provider would get, with no
    // opportunity to opt in. It must not silently inherit full tool bypass.
    //
    // What this proves, and what it does not: `_meta.paseo.isUnattended` is
    // the ONLY signal this fork emits that Paseo's own cross-provider
    // create-agent logic (create-agent-mode.js, owned by C2's Paseo-side
    // patches, not this fork) reads to decide whether a CHILD of some OTHER
    // provider inherits an unattended default from an agy PARENT. Proving
    // readOnly is both the default mode AND carries no isUnattended tag means
    // an unconfigured agy session cannot be the source of that propagation.
    // Proving the far end — that Paseo's own resolveDefaultAgentCreateConfig
    // actually honors the flag's absence for a real Claude child — needs the
    // 0.8.0 Paseo server this fork's own tests do not vendor; that half is
    // C2.5's combined-revision suite (docs/tasks/active/paseo-080-agy-20260915.md).
    const { app } = newAgent({ dangerouslySkipPermissions: undefined });
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        assert.equal(session.newSessionResponse.modes.currentModeId, 'readOnly');
        const readOnly = session.newSessionResponse.modes.availableModes.find((m) => m.id === 'readOnly');
        assert.equal(readOnly._meta, undefined, 'readOnly must not be marked isUnattended');
      });
    });
  });

  it('slash command runs as a separate `agy --print` call, not a turn', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const responsePromise = session.prompt('/usage');
        const { text, response } = await drainToStop(session);
        await responsePromise;
        assert.equal(response.stopReason, 'end_turn');
        assert.match(text, /fake-agy print: \/usage/);
      });
    });
  });

  it('attaches an image to a temp file under the session workspace', async () => {
    const { app } = newAgent();
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        const onePixelPng = Buffer.from(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          'base64'
        );
        const responsePromise = session.prompt([
          { type: 'text', text: 'describe the attached image, reply with word PIXEL' },
          { type: 'image', data: onePixelPng.toString('base64'), mimeType: 'image/png' },
        ]);
        const { text, response } = await drainToStop(session);
        await responsePromise;
        assert.equal(response.stopReason, 'end_turn');
        assert.match(text, /PIXEL/);
      });
    });
  });

  it('session/load replays the prior transcript then continues the conversation', async () => {
    const { app } = newAgent();
    let sessionId;
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        sessionId = session.sessionId;
        const responsePromise = session.prompt('reply with word FIRST');
        await drainToStop(session);
        await responsePromise;
      });
    });

    // Fresh adapter instance, same stateDir: simulates a daemon restart. The
    // conversation continues via agy's own --conversation flag; only the
    // transcript this adapter showed the client is replayed from disk.
    const reloaded = newAgent();
    const replayed = [];
    const client = acp.client().onNotification(acp.methods.client.session.update, async (ctx) => {
      if (ctx.params.sessionId === sessionId) {
        replayed.push(ctx.params.update);
      }
    });
    await client.connectWith(reloaded.app, async (cx) => {
      const loaded = await cx.request(acp.methods.agent.session.load, { sessionId, cwd: workDir, mcpServers: [] });
      assert.equal(loaded.sessionId, sessionId);

      const replayedText = replayed
        .filter((u) => u.sessionUpdate === 'agent_message_chunk')
        .map((u) => u.content.text)
        .join('');
      assert.match(replayedText, /FIRST/);

      // The loaded session is live: a prompt continues the same conversation.
      const continueResponse = await cx.request(acp.methods.agent.session.prompt, {
        sessionId,
        prompt: [{ type: 'text', text: 'reply with word CONTINUED' }],
      });
      assert.equal(continueResponse.stopReason, 'end_turn');
      const continuedText = replayed
        .filter((u) => u.sessionUpdate === 'agent_message_chunk')
        .map((u) => u.content.text)
        .join('');
      assert.match(continuedText, /CONTINUED/);
    });
  });

  it('session/delete removes the transcript + meta cache from disk (S14: no TTL, so delete is the cleanup path)', async () => {
    const { app } = newAgent();
    let sessionId;
    await acp.client().connectWith(app, async (cx) => {
      await cx.buildSession(workDir).withSession(async (session) => {
        sessionId = session.sessionId;
        const responsePromise = session.prompt('reply with word BEFOREDELETE');
        await drainToStop(session);
        await responsePromise;
      });

      const transcriptPath = join(stateDir, `${sessionId}.jsonl`);
      assert.ok(existsSync(transcriptPath), 'transcript should exist before delete');

      await cx.request(acp.methods.agent.session.delete, { sessionId });
      assert.equal(existsSync(transcriptPath), false, 'transcript must be removed after session/delete');
      assert.equal(existsSync(join(stateDir, `${sessionId}.meta.json`)), false, 'meta.json must be removed after session/delete');
    });
  });
});
