// Test fixtures (fixtures/fake-agy.mjs, fixtures/mock-agy.mjs) stand in for a
// real `agy` binary and are spawned directly by path (AgySession.start()
// spawns `binaryPath` itself, exactly as it would spawn the real native
// binary — no interpreter prefix). That means the fixture file has to carry
// the OS executable bit to run at all.
//
// The fixtures are checked into git at 0644, not 0755: this repo's cutline
// policy only allows a NEW file under apps/ to land as a plain 000000->100644
// blob (an existing file may stay 100755->100755, but nothing may newly
// introduce an executable bit). So the executable copy a test actually spawns
// is materialized at test run time, in a tmpdir, never committed.
import { chmod, copyFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const materialized = [];

export async function materializeFixture(sourcePath) {
  const dir = await mkdtemp(join(tmpdir(), 'agy-acp-fixture-'));
  const target = join(dir, 'agy');
  await copyFile(sourcePath, target);
  await chmod(target, 0o700);
  materialized.push(dir);
  return target;
}

export async function cleanupMaterializedFixtures() {
  const dirs = materialized.splice(0, materialized.length);
  await Promise.all(dirs.map((dir) => rm(dir, { recursive: true, force: true })));
}
