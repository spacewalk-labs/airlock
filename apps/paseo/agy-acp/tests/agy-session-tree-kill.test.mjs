// Proves the grace-period SIGKILL fallback in agy-session.ts kills agy's
// whole process group, not just agy itself — a plain `child.kill('SIGKILL')`
// only reaches agy and leaks any tool subprocess it spawned (e.g. a shell
// command still running when the turn is cancelled).
//
// Uses fixtures/fake-agy.mjs, which on a "SPAWN_CHILD" prompt spawns a real
// detached `sleep 999` and writes its pid to $FAKE_AGY_CHILD_PIDFILE, and
// which can be told to ignore SIGINT so cancellation is forced all the way to
// the SIGKILL fallback. AGY_ACP_CANCEL_GRACE_MS shortens that fallback's
// grace period so the test does not wait out the real 5s default.
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, test } from 'node:test';
import { cleanupMaterializedFixtures, materializeFixture } from './materialize-fixture.mjs';

process.env.AGY_ACP_CANCEL_GRACE_MS = '200';
const { AgySession } = await import('../dist/agy-session.js');

const __dirname = dirname(fileURLToPath(import.meta.url));
const fakeAgyPath = await materializeFixture(join(__dirname, 'fixtures', 'fake-agy.mjs'));

after(cleanupMaterializedFixtures);

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

test('cancel() SIGKILL fallback reaches a tool subprocess agy left behind', async () => {
  const tmp = await mkdtemp(join(tmpdir(), 'agy-tree-kill-'));
  const pidfile = join(tmp, 'child.pid');

  const session = new AgySession({
    binaryPath: fakeAgyPath,
    cwd: process.cwd(),
    env: { FAKE_AGY_IGNORE_SIGINT: '1', FAKE_AGY_CHILD_PIDFILE: pidfile, FAKE_AGY_STARTUP_MS: '50' },
  });

  try {
    await session.start();
    const promptPromise = session.prompt('SPAWN_CHILD please');

    // Wait for fake-agy to have actually spawned and recorded its grandchild.
    let childPid;
    for (let i = 0; i < 50; i++) {
      try {
        childPid = Number((await readFile(pidfile, 'utf8')).trim());
        break;
      } catch {
        await new Promise((r) => setTimeout(r, 20));
      }
    }
    assert.ok(childPid, 'fake-agy never recorded its spawned child pid');
    assert.equal(isAlive(childPid), true, 'spawned child should be alive before cancel');

    session.cancel();
    await assert.rejects(promptPromise, /Prompt was cancelled/);

    // Past the (shortened) grace period, both fake-agy (which ignored SIGINT)
    // and the grandchild it spawned must be gone.
    await new Promise((r) => setTimeout(r, 600));
    assert.equal(isAlive(childPid), false, 'process-tree kill should have reached the grandchild');
  } finally {
    session.close();
    await rm(tmp, { recursive: true, force: true });
  }
});
