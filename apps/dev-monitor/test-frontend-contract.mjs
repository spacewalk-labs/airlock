// Execute the shipped renderer against cards from the actual HTTP backend.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
const fixture = spawnSync('python3', [fileURLToPath(new URL('./test-message-contract.py', import.meta.url)), '--json'], {encoding:'utf8'});
assert.equal(fixture.status,0,fixture.stderr+fixture.stdout);
const data = JSON.parse(fixture.stdout);
const html = readFileSync(new URL('./frontend/dev-monitor.html',import.meta.url),'utf8');
class Element {
  constructor(tag) { this.tagName=tag;this.children=[];this.dataset={};this.events={};this._text=''; }
  appendChild(child) { this.children.push(child);return child; }
  setAttribute(name,value) { this[name]=value; }
  addEventListener(name,callback) { this.events[name]=callback; }
  set textContent(text) {this._text=String(text);this.children=[];}
  get textContent() {return this._text+this.children.map(c=>c.textContent).join('');}
}
const state={key:'active',cards:data.feed.messages,selected:{},expanded:{}};
const nodes=new Map();
const requests=[];
const context=vm.createContext({
  document:{createElement:tag=>new Element(tag),getElementById:id=>{if(!nodes.has(id))nodes.set(id,new Element('div'));return nodes.get(id);}},
  msgState:state,API:'/api',j:async()=>data.health,timeAgo:x=>x,
  ownerFetch:async(path,opts)=>{requests.push({path,opts});return {status:200,ok:true,data:{ok:true,ran_at:'now'}};},
  ownerResponse:x=>x,msgToast:()=>{},loadMessages:async()=>{},
});
function source(name) {
  const start=html.indexOf('  function '+name+'(');
  assert.ok(start>=0,name);
  const next=html.indexOf('\n  function ',start+1);
  return html.slice(start,next);
}
for (const name of ['isHttpUrl','msgEl','filteredMessages','buildMessageCard','runMessage','cardAction']) {
  let code=source(name);
  // isHttpUrl is one line; its following declarations are state owned above.
  if(name==='isHttpUrl') code=code.split('\n')[0];
  vm.runInContext(code,context);
}
vm.runInContext(source('loadLanes').split('  showTab(')[0],context);
const rendered=data.feed.messages.map(card=>context.buildMessageCard(card));
assert.deepEqual(rendered.map(x=>x.dataset.cardId).sort(),data.ids.slice().sort());
for(let i=0;i<rendered.length;i++) {
  const card=data.feed.messages[i],node=rendered[i];
  assert.ok(node.textContent.includes(card.title));
  assert.ok(node.textContent.includes(card.body));
  assert.ok(node.textContent.includes('Urgent'));
  assert.ok(!node.textContent.includes('To do'));
  assert.ok(!node.textContent.includes('Complete'));
  assert.ok(node.textContent.includes('Archive'));
  for(const gone of ['Pin','Unpin','Dismiss','Undo']) assert.ok(!node.textContent.includes(gone));
}
const runnable=rendered.find(n=>data.feed.messages.find(c=>c.card_id===n.dataset.cardId).run);
function descendants(n){return [n,...n.children.flatMap(descendants)];}
const button=descendants(runnable).find(n=>n.tagName==='button'&&n.textContent==='Run');
assert.ok(button);await button.events.click();
assert.equal(requests.length,1);assert.equal(requests[0].path,'/run');
assert.equal(requests[0].opts.method,'POST');
assert.equal(JSON.parse(requests[0].opts.body).card_id,runnable.dataset.cardId);
assert.equal(button.disabled,false);
const archiveButton=descendants(runnable).find(n=>n.tagName==='button'&&n.textContent==='Archive');
archiveButton.events.click();await new Promise(resolve=>setImmediate(resolve));
assert.equal(requests[1].path,'/messages/'+encodeURIComponent(runnable.dataset.cardId)+'/archive');
const openLink=descendants(runnable).find(n=>n.tagName==='a');
openLink.events.click();await new Promise(resolve=>setImmediate(resolve));
assert.equal(requests[2].path,'/messages/'+encodeURIComponent(runnable.dataset.cardId)+'/read');
assert.ok(context.buildMessageCard(data.failed).textContent.includes('Delivery failed'));
state.key='unread';assert.equal(context.filteredMessages().length,2);
state.key='urgent';assert.equal(context.filteredMessages().length,2);
state.cards[0].read_at='now';state.key='unread';assert.equal(context.filteredMessages().length,1);
await context.loadLanes();
assert.ok(nodes.get('delivery-status').textContent.includes('0 waiting'));
assert.ok(nodes.get('delivery-status').textContent.includes('Last sent'));
console.log('FRONTEND: actual HTTP v1 urgency/new level cards rendered=2; body/title/urgent/link/read/archive/run/failed-badge/filters/health PASS; webhook POSTs=2');
