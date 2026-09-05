/* The viewer addresses nothing above home — the client half.

   fileview's scope is enforced by the server (filebrowser --root %h), and
   install/test-fileview-home-scope.sh measures that against the real binary. This
   is the OTHER half: the client translates absolute UI paths into the root-relative
   paths the API speaks, and that translation is the only place a path can be
   declared out of scope. If it silently passed an out-of-home path through, the app
   would ask for the wrong file instead of saying "outside home" — the server would
   still refuse, but nobody would be told why.

   The functions are extracted and RUN, not grepped: a grep for "toApiPath is called
   inside apiUrl" passes for the wrong reasons and fails on a rename.

   Run: node install/test-fileview-scope.mjs */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const src = fs.readFileSync(
  new URL('../apps/fileview/static/app.js', import.meta.url), 'utf8');

function region(marker) {
  const start = src.indexOf('/* TESTABLE:' + marker);
  const end = src.indexOf('/* :TESTABLE */', start);
  assert.ok(start >= 0 && end > start,
    marker + ' markers missing from apps/fileview/static/app.js');
  return src.slice(start, end);
}

// ROOT is a variable in the app; here it is the fixture. Everything else the two
// regions touch is standard.
function load(root) {
  const context = { ROOT: root };
  vm.runInNewContext(
    region('scope') + region('url') +
    '\nthis.api = { underRoot, toApiPath, apiUrl, encPath };', context);
  return context.api;
}

const HOME = '/home/example';
const { underRoot, toApiPath, apiUrl } = load(HOME);

// --- positive control: the check is alive and says yes to the ordinary case ---
assert.equal(underRoot(HOME), true, 'home itself is in scope');
assert.equal(underRoot(HOME + '/notes/a.md'), true, 'a file under home is in scope');
assert.equal(toApiPath(HOME), '/', 'home is the API root');
assert.equal(toApiPath(HOME + '/notes/a.md'), '/notes/a.md', 'paths are relative to home');
assert.equal(apiUrl('resources', HOME + '/notes/a.md'),
  '/fileview/api/resources/notes/a.md', 'the URL carries the relative path');
assert.equal(apiUrl('raw', HOME + '/name with space #1.md', 'algo=none'),
  '/fileview/api/raw/name%20with%20space%20%231.md?algo=none',
  'awkward names still round-trip through the encoder');

// --- the refusals ---
const outside = [
  '/etc/passwd',                       // an absolute path above home
  '/',                                 // the filesystem root
  '/home',                             // the directory holding home
  '/home/example2/secret',             // a sibling account
  '/home/exampleX',                    // a prefix that only LOOKS like home
  '/root/.ssh/id_ed25519',
  '/var/log/syslog',
];
for (const p of outside) {
  assert.equal(underRoot(p), false, 'must be out of scope: ' + p);
  assert.throws(() => toApiPath(p), /outside/, 'toApiPath must refuse: ' + p);
  assert.throws(() => apiUrl('raw', p), /outside/, 'apiUrl must refuse: ' + p);
}

// `..` never becomes a URL: out of home it is refused as out of scope, and inside
// home encPath refuses the segment itself. Either way no request is built.
for (const p of [HOME + '/../../etc/passwd', HOME + '/..', '/etc/../etc/passwd']) {
  assert.throws(() => apiUrl('raw', p), /outside|unsafe path segment/,
    'a .. chain must not become a URL: ' + p);
}

// --- control: break the boundary and the assertions above must go red ---
// A version of toApiPath that trims the prefix without checking it — the exact
// mistake this file exists to catch.
{
  const lax = (p) => (p.indexOf(HOME) === 0 ? p.slice(HOME.length) || '/' : p);
  assert.equal(lax('/etc/passwd'), '/etc/passwd',
    'control: a check-free translation passes an outside path straight through');
  let caught = false;
  try { assert.throws(() => lax('/etc/passwd'), /outside/); } catch (_) { caught = true; }
  assert.ok(caught, 'control: the assertion used above does fail on a lax translation');
}

// --- unstamped page: no home meta -> ROOT '/', the pre-scope behaviour ---
{
  const root = load('/');
  assert.equal(root.underRoot('/etc/passwd'), true, 'unstamped: everything absolute is in scope');
  assert.equal(root.toApiPath('/etc/passwd'), '/etc/passwd', 'unstamped: paths pass through');
}

console.log('ok fileview scope: home is the only namespace the client can address');
