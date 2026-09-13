#!/usr/bin/env node
/* Frontend half of phase-4: DevTerm has no account UI, but keeps secret delivery. */
import fs from 'node:fs';

const root = new URL('../..', import.meta.url);
const read = (path) => fs.readFileSync(new URL(path, root), 'utf8');
const app = read('apps/devterm/web/app.js');
const index = read('apps/devterm/web/index.html');
const install = read('apps/devterm/install.sh');
const render = read('apps/devterm/render.sh');
const popup = read('apps/devterm/web/popup.css');
const failures = [];
const check = (name, condition) => {
  console.log(`${condition ? 'PASS' : 'FAIL'} ${name}`);
  if (!condition) failures.push(name);
};

check('devterm loads no account control or accounts.js',
  !index.includes('platform-account-control.js') && !index.includes('src="accounts.js"')
  && !app.includes('initPlatformAccountControl') && !app.includes('initAccounts'));
check('devterm renders no account icon or account popup CSS',
  !app.includes('openAcctMenu') && !app.includes('FEAT.accounts') && !app.includes('FEAT.xai')
  && !popup.includes('.tab-pop.acct'));
check('devterm installs no account control and exposes no panel aliases',
  !install.includes('"$HERE/web/platform-account-control.js"')
  && !install.includes('AIRLOCK_DEVTERM_ACCOUNTS')
  && !install.includes('AIRLOCK_DEVTERM_XAI')
  && !install.includes('AIRLOCK_DEVTERM_CLAUDE_SWITCH')
  && !install.includes('AIRLOCK_DEVTERM_CLAUDE_STATUS')
  && !render.includes('location = /panel.html') && !render.includes('location = /accounts.js'));
check('devterm keeps the platform secret adapter',
  index.includes('<script src="secretdrop.js"></script>') && app.includes('window.initSecretDrop')
  && render.includes('location = /secretdrop.js'));

if (failures.length) {
  console.error(`FAILED: ${failures.join(', ')}`);
  process.exit(1);
}
console.log('all devterm frontend retirement checks passed');
