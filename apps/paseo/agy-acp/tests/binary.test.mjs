// Unit tests for src/binary.ts's download path: a release manifest entry with
// no digest at all must fail closed, not install an unverified binary.
import assert from 'node:assert/strict';
import { appendFile, copyFile, mkdir, mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { execFile, spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { downloadAgy, getPlatformKey } from '../dist/binary.js';

const realFetch = globalThis.fetch;
let tmp;

beforeEach(async () => {
  tmp = await mkdtemp(join(tmpdir(), 'agy-binary-test-'));
});

afterEach(async () => {
  globalThis.fetch = realFetch;
  await rm(tmp, { recursive: true, force: true });
});

async function serveArchive(body, run) {
  globalThis.fetch = realFetch;
  let baseUrl;
  const sha256 = createHash('sha256').update(body).digest('hex');
  const server = createServer((req, res) => {
    if (req.url === '/latest') {
      res.end('9.9.9');
    } else if (req.url === '/9.9.9/manifest.json') {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ version: '9.9.9', platforms: {
        [getPlatformKey()]: { url: `${baseUrl}/release.tar.gz`, sha256 },
      } }));
    } else if (req.url === '/release.tar.gz') {
      res.end(body);
    } else {
      res.writeHead(404).end();
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
  try {
    await run(baseUrl);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

describe('downloadAgy', () => {
  it('refuses to install a binary whose manifest entry carries neither sha256 nor sha512', async () => {
    globalThis.fetch = async (url) => {
      const href = String(url);
      if (href.includes('/manifests/')) {
        return { ok: true, json: async () => ({ version: '9.9.9', platforms: { [getPlatformKey()]: { url: 'https://example.invalid/agy-nohash' } } }) };
      }
      if (href === 'https://example.invalid/agy-nohash') {
        return { ok: true, arrayBuffer: async () => new TextEncoder().encode('not-a-real-binary').buffer };
      }
      return { ok: false, status: 404 };
    };

    const target = join(tmp, 'agy');
    await assert.rejects(
      downloadAgy(target, 'https://example.invalid/antigravity-cli'),
      /neither sha256 nor sha512/
    );
  });

  it('installs when the manifest carries a matching sha256', async () => {
    const body = 'a-fake-agy-binary';
    const { createHash } = await import('node:crypto');
    const sha256 = createHash('sha256').update(body).digest('hex');

    globalThis.fetch = async (url) => {
      const href = String(url);
      if (href.includes('/manifests/')) {
        return {
          ok: true,
          json: async () => ({
            version: '9.9.9',
            platforms: { [getPlatformKey()]: { url: 'https://example.invalid/agy-ok', sha256 } },
          }),
        };
      }
      if (href === 'https://example.invalid/agy-ok') {
        return { ok: true, arrayBuffer: async () => new TextEncoder().encode(body).buffer };
      }
      return { ok: false, status: 404 };
    };

    const target = join(tmp, 'agy');
    const result = await downloadAgy(target, 'https://example.invalid/antigravity-cli');
    assert.equal(result, target);
  });

  it('refuses to install when the sha256 does not match', async () => {
    globalThis.fetch = async (url) => {
      const href = String(url);
      if (href.includes('/manifests/')) {
        return {
          ok: true,
          json: async () => ({
            version: '9.9.9',
            platforms: { [getPlatformKey()]: { url: 'https://example.invalid/agy-bad', sha256: 'f'.repeat(64) } },
          }),
        };
      }
      if (href === 'https://example.invalid/agy-bad') {
        return { ok: true, arrayBuffer: async () => new TextEncoder().encode('mismatched body').buffer };
      }
      return { ok: false, status: 404 };
    };

    const target = join(tmp, 'agy');
    await assert.rejects(downloadAgy(target, 'https://example.invalid/antigravity-cli'), /checksum mismatch/);
  });
  it('publishes a complete tar executable while the old executable keeps running', {
    skip: process.platform !== 'linux',
    timeout: 30000,
  }, async () => {
    const installDir = join(tmp, 'install');
    const payloadDir = join(tmp, 'payload');
    await mkdir(installDir);
    await mkdir(payloadDir);
    const target = join(installDir, 'agy');
    const payload = join(payloadDir, 'agy');
    await copyFile('/bin/sleep', target);
    await copyFile('/bin/echo', payload);
    // Incompressible ELF padding makes extraction long enough to observe publication.
    await appendFile(payload, randomBytes(64 * 1024 * 1024));
    const archive = join(tmp, 'release.tar.gz');
    await execFileAsync('tar', ['-czf', archive, '-C', payloadDir, 'agy']);
    const oldInode = (await stat(target)).ino;
    const child = spawn(target, ['60']);
    await new Promise((resolve, reject) => {
      child.once('spawn', resolve);
      child.once('error', reject);
    });
    let finished = false;
    let monitor;
    const failures = [];
    let attempts = 0;
    try {
      await serveArchive(await readFile(archive), async (baseUrl) => {
        monitor = (async () => {
          while (!finished) {
            attempts++;
            try {
              await execFileAsync(target, ['0.001']);
            } catch (error) {
              failures.push(error.code);
            }
          }
        })();
        try {
          assert.equal(await downloadAgy(target, baseUrl), target);
        } finally {
          finished = true;
          await monitor;
        }
      });
      assert.ok(attempts > 0);
      assert.deepEqual(failures, []);
      assert.equal(child.exitCode, null);
      assert.equal((await stat(`/proc/${child.pid}/exe`)).ino, oldInode);
      assert.notEqual((await stat(target)).ino, oldInode);
      assert.deepEqual(await readFile(target), await readFile(payload));
      assert.equal((await execFileAsync(target, ['installed'])).stdout.trim(), 'installed');
      assert.deepEqual(await readdir(installDir), ['agy']);
    } finally {
      finished = true;
      await monitor;
      child.kill();
      await new Promise((resolve) => child.once('exit', resolve));
    }
  });

  it('keeps the old target and removes staging when the archive has no executable', async () => {
    const target = join(tmp, 'agy');
    await writeFile(target, 'existing executable');
    const payloadDir = join(tmp, 'payload');
    await mkdir(payloadDir);
    await writeFile(join(payloadDir, 'readme'), 'no executable');
    const archive = join(tmp, 'release.tar.gz');
    await execFileAsync('tar', ['-czf', archive, '-C', payloadDir, 'readme']);
    const before = await readdir(tmp);
    await serveArchive(await readFile(archive), async (baseUrl) => {
      await assert.rejects(downloadAgy(target, baseUrl), /could not locate agy executable/);
    });
    assert.equal(await readFile(target, 'utf8'), 'existing executable');
    assert.deepEqual(await readdir(tmp), before);
  });

  it('publishes the regular file behind an archive alias inside staging', async () => {
    const payloadDir = join(tmp, 'payload');
    await mkdir(join(payloadDir, 'bin'), { recursive: true });
    await writeFile(join(payloadDir, 'bin', 'agy'), '#!/bin/sh\necho installed-alias\n');
    await symlink('bin/agy', join(payloadDir, 'agy'));
    const archive = join(tmp, 'release.tar.gz');
    await execFileAsync('tar', ['-czf', archive, '-C', payloadDir, 'agy', 'bin']);
    const target = join(tmp, 'agy');
    const before = await readdir(tmp);
    await serveArchive(await readFile(archive), async (baseUrl) => {
      assert.equal(await downloadAgy(target, baseUrl), target);
    });
    assert.equal((await execFileAsync(target)).stdout.trim(), 'installed-alias');
    assert.deepEqual(await readdir(tmp), [...before, 'agy'].sort());
  });

  for (const candidateType of ['outside alias', 'directory']) {
    it(`rejects an archive executable that is an ${candidateType}`, async () => {
      const payloadDir = join(tmp, 'payload');
      await mkdir(payloadDir);
      const outside = join(tmp, 'outside');
      await writeFile(outside, 'outside must remain untouched', { mode: 0o600 });
      if (candidateType === 'outside alias') {
        await symlink(outside, join(payloadDir, 'agy'));
      } else {
        await mkdir(join(payloadDir, 'agy'));
      }
      const archive = join(tmp, 'release.tar.gz');
      await execFileAsync('tar', ['-czf', archive, '-C', payloadDir, 'agy']);
      const target = join(tmp, 'agy');
      await writeFile(target, 'existing executable');
      const before = await readdir(tmp);
      const outsideMode = (await stat(outside)).mode;
      await serveArchive(await readFile(archive), async (baseUrl) => {
        await assert.rejects(downloadAgy(target, baseUrl), /must be a regular file within its staging directory/);
      });
      assert.equal(await readFile(target, 'utf8'), 'existing executable');
      assert.equal(await readFile(outside, 'utf8'), 'outside must remain untouched');
      assert.equal((await stat(outside)).mode, outsideMode);
      assert.deepEqual(await readdir(tmp), before);
    });
  }

});
