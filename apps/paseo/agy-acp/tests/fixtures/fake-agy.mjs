#!/usr/bin/env node
// Offline stand-in for the real `agy` CLI, shaped after its observed behavior
// (agy 1.2.3): ~4s startup before `init` (tunable here via env for fast
// tests), one turn per stream-json `user` line, SIGINT -> ERROR result +
// process exit ~1.2s later, and two extra invocation shapes the translator
// also drives it with: `agy models` (tab-separated catalog) and
// `agy --print /command` (one-shot local-command output).
//
// Prompt keywords drive scripted behavior for the fake-agy matrix:
//   "sleep"    -> a long-running tool call before the reply (interrupt target)
//   "TOOLSTEP" -> a fast tool call before the reply, no delay (tool-title tests)
//   "FAIL503"  -> ERROR result with no response text (server-error path)
//   "REPLY_THEN_FAIL" -> replies, THEN reports ERROR (agy's "answered anyway" case)
//   "DENY"     -> result carries denied_actions
//   "SPAWN_CHILD" -> spawns a detached grandchild (sleep) and writes its pid to
//                    $FAKE_AGY_CHILD_PIDFILE, to prove a process-tree kill
//                    reaches tool subprocesses, not just this process
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const STARTUP_MS = Number(process.env.FAKE_AGY_STARTUP_MS ?? 150);
const RESUME_STARTUP_MS = Number(process.env.FAKE_AGY_RESUME_STARTUP_MS ?? STARTUP_MS);
const TURN_MS = Number(process.env.FAKE_AGY_TURN_MS ?? 30);
const LONG_TURN_MS = Number(process.env.FAKE_AGY_LONG_TURN_MS ?? 5000);

const args = process.argv.slice(2);

// `agy models` — printed as "id\tlabel" lines, matching acp-agent.ts's parser.
if (args[0] === 'models') {
  const rows = [
    ['gemini-3.8-flash-high', 'Gemini 3.8 Flash (High)'],
    ['gemini-3.8-flash-medium', 'Gemini 3.8 Flash (Medium)'],
    ['gemini-3.8-flash-low', 'Gemini 3.8 Flash (Low)'],
    ['claude-opus-4-6-thinking', 'Claude Opus 4.6 (Thinking)'],
  ];
  process.stdout.write(rows.map(([id, label]) => `${id}\t${label}`).join('\n') + '\n');
  process.exit(0);
}

// `agy --print /command` — one-shot local-command echo.
const printIdx = args.indexOf('--print');
if (printIdx !== -1) {
  const command = args[printIdx + 1] ?? '';
  process.stdout.write(`fake-agy print: ${command}\n`);
  process.exit(0);
}

const conv = (args.find((a) => a.startsWith('--conversation=')) ?? '').split('=')[1] || randomUUID();
const resuming = args.some((a) => a.startsWith('--conversation='));
const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');
let step = 0;
let turns = 0;
let busy = null;
const queue = [];

function runNext() {
  if (busy || queue.length === 0) return;
  const text = queue.shift();
  turns++;
  out({ event: 'step_update', step_update: { step_index: step++, step_type: 'user_input', state: 'DONE' } });

  if (text.includes('FAIL503')) {
    out({
      event: 'result',
      result: {
        conversation_id: conv,
        status: 'ERROR',
        response: '',
        error: 'API error (attempt 3): UNAVAILABLE (code 503): No capacity available for model fake on the server',
        num_turns: turns,
      },
    });
    runNext();
    return;
  }

  const deniedActions = text.includes('DENY') ? [{ action: 'run_command', display_name: 'Run command' }] : undefined;
  const ms = text.includes('sleep') || text.includes('SPAWN_CHILD') ? LONG_TURN_MS : TURN_MS;
  if (text.includes('sleep') || text.includes('SPAWN_CHILD') || text.includes('TOOLSTEP')) {
    out({ event: 'step_update', step_update: { step_index: step++, step_type: 'tool', state: 'ACTIVE', tool_info: { name: 'run_command', parameters: { CommandLine: 'sleep 999' } } } });
    out({ event: 'step_update', step_update: { step_index: step - 1, step_type: 'tool', state: 'DONE', tool_info: { name: 'run_command', output: 'ok' } } });
  }
  if (text.includes('SPAWN_CHILD') && process.env.FAKE_AGY_CHILD_PIDFILE) {
    // Not detached: a real tool subprocess inherits agy's own process group,
    // which is exactly what makes a plain child.kill() on agy alone leak it.
    const child = spawn('sleep', ['999'], { stdio: 'ignore' });
    writeFileSync(process.env.FAKE_AGY_CHILD_PIDFILE, String(child.pid));
  }

  busy = setTimeout(() => {
    const word = (text.match(/word (\w+)/) ?? [])[1] ?? 'OK';
    out({ event: 'step_update', step_update: { step_index: step, step_type: 'agent_response', state: 'ACTIVE', text_delta: word } });
    out({
      event: 'step_update',
      step_update: {
        step_index: step++,
        step_type: 'agent_response',
        state: 'DONE',
        text_delta: '\n',
        usage: { input_tokens: 100, output_tokens: 20, total_tokens: 120 },
      },
    });
    if (text.includes('REPLY_THEN_FAIL')) {
      out({
        event: 'result',
        result: { conversation_id: conv, status: 'ERROR', response: `${word}\n`, error: 'context deadline exceeded (after reply)', num_turns: turns },
      });
    } else {
      out({
        event: 'result',
        result: { conversation_id: conv, status: 'SUCCESS', response: `${word}\n`, num_turns: turns, denied_actions: deniedActions },
      });
    }
    busy = null;
    runNext();
  }, ms);
}

setTimeout(() => {
  out({ event: 'init', conversation_id: conv, init: { cwd: process.cwd(), tools: ['run_command', 'view_file'], permission_mode: 'always-proceed' } });
  createInterface({ input: process.stdin }).on('line', (l) => {
    let m;
    try {
      m = JSON.parse(l);
    } catch {
      return;
    }
    if (m.event !== 'user') {
      process.stderr.write(`warning: ignoring unsupported stream input message event "${m.event}"\n`);
      return;
    }
    queue.push(String(m.message?.content ?? ''));
    runNext();
  });
}, resuming ? RESUME_STARTUP_MS : STARTUP_MS);

process.on('SIGINT', () => {
  if (process.env.FAKE_AGY_IGNORE_SIGINT) {
    process.stderr.write('fake-agy: ignoring SIGINT (testing SIGKILL fallback)\n');
    return;
  }
  process.stderr.write('error: interrupted\n');
  out({ event: 'result', result: { conversation_id: conv, status: 'ERROR', response: '', error: 'interrupted', num_turns: turns } });
  setTimeout(() => process.exit(1), Number(process.env.FAKE_AGY_SIGINT_EXIT_MS ?? 100));
});
process.on('SIGTERM', () => {
  out({ event: 'result', result: { conversation_id: conv, status: 'ERROR', response: '', error: 'stream input cancelled: context canceled' } });
  process.exit(1);
});
process.stdin.on('end', () => {
  if (process.env.FAKE_AGY_IGNORE_SIGINT) {
    // Simulates a genuinely stuck agy: neither SIGINT nor stdin EOF (both of
    // which detachProcess() sends) gets it to exit on its own, so only the
    // grace-period SIGKILL fallback in agy-session.ts can end it.
    process.stderr.write('fake-agy: ignoring stdin EOF (testing SIGKILL fallback)\n');
    return;
  }
  process.exit(1);
});
