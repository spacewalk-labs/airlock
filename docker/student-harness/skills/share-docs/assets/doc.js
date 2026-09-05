// doc.js — 발행 문서 공용 스크립트.
//   테마 토글 · mermaid · 코드 복사 버튼 · 상단바 · hero · 우측 플로팅 목차 · 메모지 · 결정 회신.
// 사용: 문서 HTML 과 같은 폴더에 doc.js 를 두고
//       <script type="module" src="doc.js"></script>
//       (발행 전에는 문서 안으로 인라인 — templates/README.md)
const MERMAID_CDN='https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs';

const THEME_KEY='doc-theme';
const saved=()=>{try{return localStorage.getItem(THEME_KEY)||'auto'}catch{return 'auto'}};
const applyTheme=t=>{const r=document.documentElement;t==='auto'?r.removeAttribute('data-theme'):r.setAttribute('data-theme',t)};
const effDark=()=>{const t=saved();return t==='dark'||(t==='auto'&&matchMedia('(prefers-color-scheme:dark)').matches)};
applyTheme(saved());

/* ---------- 본문 글자 크기 (opt-in) ----------
   페이지가 `<meta name="doc-fontsize" content="on">` 을 선언할 때만 상단바에 A−/A+ 가
   생깁니다. opt-in 인 이유: 이 자산은 모든 발행본이 공유하므로, 켤지 말지는 문서가 정합니다.
   배율은 localStorage 라 **그 브라우저에만** 남고(디바이스별), 문서 사이에는 공통입니다 —
   테마 토글과 같은 결입니다. 🔴 적용을 topbar 생성까지 미루지 않습니다: 그러면 기본 크기로
   한 번 그렸다가 커지는 깜빡임이 보입니다. */
const FS_KEY='doc-fontscale', FS_MIN=0.85, FS_MAX=1.6, FS_STEP=0.1;
const fsEnabled=()=>(document.querySelector('meta[name="doc-fontsize"]')?.content||'').trim()==='on';
const fsClamp=v=>Math.min(FS_MAX,Math.max(FS_MIN,Math.round(v*100)/100));
const fsRead=()=>{try{const v=parseFloat(localStorage.getItem(FS_KEY));return Number.isFinite(v)?fsClamp(v):1}catch{return 1}};
const fsApply=v=>document.documentElement.style.setProperty('--doc-fs-scale',String(v));
if(fsEnabled())fsApply(fsRead());

// 🔴 mermaid 는 CDN 이라 오프라인·차단·CDN 장애에서 import 가 실패합니다. 정적 `import` 로 두면
// 그 실패가 **모듈 전체**를 죽여 퀴즈·테마·TOC·복사까지 같이 멎습니다(다이어그램 하나 때문에
// 페이지 전체가 죽습니다). 그래서 다이어그램이 실제로 있을 때만, 늦게, 실패를 삼키며 부릅니다.
if(document.querySelector('.mermaid')){
  import(MERMAID_CDN).then(m=>{
    m.default.initialize({startOnLoad:false,theme:effDark()?'dark':'neutral',securityLevel:'loose',flowchart:{useMaxWidth:true,htmlLabels:true}});
    return m.default.run();
  }).catch(e=>console.warn('[doc.js] mermaid 로드 실패 — 다이어그램만 렌더되지 않습니다',e));
}

const svg=(i,w=22)=>`<svg viewBox="0 0 24 24" width="${w}" height="${w}" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${i}</svg>`;
const IC={
  note:svg('<path d="M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4Z"/>'),
  copy:svg('<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',15),
  trash:svg('<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',15),
  sun:svg('<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',18),
  moon:svg('<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"/>',18),
  auto:svg('<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 0 0 18Z" fill="currentColor" stroke="none"/>',18),
};

/* ---------- clipboard: 평문 HTTP(로컬 미리보기)엔 navigator.clipboard 없음(https 전용) → execCommand fallback ---------- */
async function copyText(text){
  try{ if(navigator.clipboard&&window.isSecureContext){ await navigator.clipboard.writeText(text); return true; } }catch{}
  try{
    const t=document.createElement('textarea');t.value=text;t.setAttribute('readonly','');
    t.style.cssText='position:fixed;top:-9999px;left:0;opacity:0';
    document.body.appendChild(t);t.focus();t.select();try{t.setSelectionRange(0,text.length)}catch{}
    const ok=document.execCommand('copy');t.remove();return ok;
  }catch{ return false; }
}

/* ---------- copy buttons ---------- */
for(const pre of document.querySelectorAll('pre')){
  if(pre.classList.contains('mermaid'))continue;
  const b=document.createElement('button');b.className='copy-btn';b.type='button';b.textContent='copy';
  b.onclick=async()=>{const ok=await copyText(pre.querySelector('code')?.innerText||pre.innerText);b.textContent=ok?'copied!':'failed';b.classList.toggle('copied',ok);setTimeout(()=>{b.textContent='copy';b.classList.remove('copied')},1400)};
  pre.appendChild(b);
}

/* ---------- topbar ---------- */
(function(){
  const label=(document.querySelector('meta[name="doc-label"]')?.content||'문서').trim();
  const bar=document.createElement('div');bar.className='doc-topbar';
  bar.innerHTML=`<span class="crumb"></span><span class="sp"></span><button class="theme-btn" type="button" title="테마 (auto/light/dark)"></button>`;
  bar.querySelector('.crumb').textContent=label;
  document.body.prepend(bar);
  const btn=bar.querySelector('.theme-btn');const order=['auto','light','dark'];
  const paint=()=>{const t=saved();btn.innerHTML=t==='dark'?IC.moon:t==='light'?IC.sun:IC.auto;};paint();
  btn.onclick=()=>{const n=order[(order.indexOf(saved())+1)%3];try{localStorage.setItem(THEME_KEY,n)}catch{}applyTheme(n);paint();};
  if(fsEnabled()){
    const group=document.createElement('span');group.className='doc-fs';
    group.innerHTML=`<button class="fs-btn" type="button" title="글자 작게">A−</button>`
      +`<button class="fs-val" type="button" title="기본 크기로">100%</button>`
      +`<button class="fs-btn" type="button" title="글자 크게">A+</button>`;
    bar.insertBefore(group,btn);
    const [minus,val,plus]=group.children;
    const show=v=>{val.textContent=Math.round(v*100)+'%';minus.disabled=v<=FS_MIN;plus.disabled=v>=FS_MAX;};
    const set=v=>{const n=fsClamp(v);fsApply(n);try{localStorage.setItem(FS_KEY,String(n))}catch{}show(n);};
    show(fsRead());
    minus.onclick=()=>set(fsRead()-FS_STEP);
    plus.onclick=()=>set(fsRead()+FS_STEP);
    val.onclick=()=>set(1);
  }
})();

/* ---------- hero-wrap: .doc 의 h1 + doc-meta + lead 를 hero band 로 ---------- */
(function(){
  const doc=document.querySelector('main.doc, .doc');
  if(!doc)return;
  const h1=doc.querySelector('h1');
  if(!h1||h1.closest('.doc-hero'))return;
  const hero=document.createElement('header');hero.className='doc-hero';
  const inner=document.createElement('div');inner.className='doc-hero-inner';
  hero.appendChild(inner);
  // hero eyebrow 미표시 — sticky topbar 크럼(meta 라벨)과 중복이라 제거
  // h1 + 이어지는 doc-meta / lead 이동 (순서 보존)
  const move=[h1];let n=h1.nextElementSibling;
  while(n&&(n.classList.contains('doc-meta')||n.classList.contains('lead'))){move.push(n);n=n.nextElementSibling;}
  move.forEach(el=>inner.appendChild(el));
  doc.parentNode.insertBefore(hero,doc);
})();

/* ---------- 우측 플로팅 TOC (기존 커스텀 목차 있으면 skip) ---------- */
(function(){
  const doc=document.querySelector('main.doc, .doc');
  if(!doc)return;
  if(document.querySelector('.cat-toc, .toc-rail, .toc, #doc-toc')||document.body.hasAttribute('data-no-toc'))return;
  const hs=[...doc.querySelectorAll('h2, h3')];
  if(hs.length<3)return;
  const TKEY='doc-toc-collapsed';
  const aside=document.createElement('aside');aside.id='doc-toc';
  // 기본 접힘 opt-in: `<meta name="doc-toc-default" content="collapsed">`. 플로팅 목차는 본문 위에
  // 떠 있어 글자를 키우면 본문을 가립니다 — 길게 읽는 문서는 접힌 채로 시작하는 편이 낫습니다.
  // 독자가 한 번이라도 접거나 펴면 그 선택이 이깁니다(저장값 우선).
  const tocDefaultCollapsed=(document.querySelector('meta[name="doc-toc-default"]')?.content||'').trim()==='collapsed';
  let col=tocDefaultCollapsed;try{const v=localStorage.getItem(TKEY);if(v!==null)col=v==='1'}catch{}
  if(col)aside.classList.add('collapsed');
  const ICtoc=svg('<path d="M4 6h16M4 12h16M4 18h16"/>',18),ICx=svg('<path d="M18 6 6 18M6 6l12 12"/>',15);
  const tg=document.createElement('button');tg.className='doc-toc-toggle';tg.type='button';tg.title='목차 접기/펴기';tg.setAttribute('aria-label','목차 접기/펴기');tg.innerHTML=col?ICtoc:ICx;
  tg.onclick=()=>{const c=aside.classList.toggle('collapsed');tg.innerHTML=c?ICtoc:ICx;try{localStorage.setItem(TKEY,c?'1':'0')}catch{}};
  const head=document.createElement('div');head.className='doc-toc-head';head.textContent='On this page';
  const nav=document.createElement('nav');
  aside.append(tg,head,nav);
  const used=new Set();const links=[];
  for(const h of hs){
    if(!h.id){let s=(h.textContent||'sec').toLowerCase().replace(/[#]/g,'').replace(/[^\w가-힣\s-]/g,'').trim().replace(/\s+/g,'-').replace(/-+/g,'-')||'sec';let id=s,k=1;while(used.has(id)||document.getElementById(id))id=s+'-'+(++k);used.add(id);h.id=id;}else used.add(h.id);
    const a=document.createElement('a');a.href='#'+h.id;const txt=(h.textContent||'').replace(/#$/,'').trim();a.textContent=txt;a.title=txt;
    if(h.tagName==='H3')a.className='lvl3';
    nav.appendChild(a);links.push({a,h});
  }
  document.body.appendChild(aside);
  const byId=new Map(links.map(l=>[l.h.id,l.a]));let act=null;
  const io=new IntersectionObserver(es=>{for(const e of es){if(e.isIntersecting){act&&act.classList.remove('active');act=byId.get(e.target.id);act&&act.classList.add('active');}}},{rootMargin:'0px 0px -78% 0px'});
  links.forEach(l=>io.observe(l.h));
})();

/* ---------- 메모지 (크게·크기조정·크기기억) ---------- */
(function(){
  const KEY='doc-notepad:'+location.pathname;
  const pad=document.createElement('div');pad.className='doc-notepad';
  pad.innerHTML=`<div class="doc-notepad-head"><span class="t">${svg('<path d="M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4Z"/>',16)}메모지</span><span class="doc-saved"></span></div>`+
    `<textarea placeholder="문서 읽으며 메모… (이 페이지에 자동 저장 · 복사해서 세션에 붙여넣기 · 좌상단 모서리로 크기조정)"></textarea>`+
    `<div class="doc-notepad-foot"><button class="doc-note-copy" type="button">${IC.copy}복사</button><button class="doc-note-clear" type="button">${IC.trash}지우기</button></div>`;
  document.body.appendChild(pad);
  const ta=pad.querySelector('textarea'),sv=pad.querySelector('.doc-saved');
  try{ta.value=localStorage.getItem(KEY)||''}catch{}
  const mark=()=>{const d=new Date();sv.textContent='저장됨 '+String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0');};
  let t;ta.addEventListener('input',()=>{clearTimeout(t);t=setTimeout(()=>{try{localStorage.setItem(KEY,ta.value);mark()}catch{}},300)});
  if(ta.value)mark();
  try{const sz=JSON.parse(localStorage.getItem(KEY+':size')||'null');if(sz){pad.style.width=sz.w+'px';pad.style.height=sz.h+'px';}}catch{}
  new ResizeObserver(()=>{if(pad.classList.contains('open'))try{localStorage.setItem(KEY+':size',JSON.stringify({w:pad.offsetWidth,h:pad.offsetHeight}))}catch{}}).observe(pad);
  // 좌상단 커스텀 리사이즈 핸들 (우하단 고정이라 네이티브 우하단 핸들은 화면 모서리에 묶임 → 좌상단 드래그로 확대)
  const rz=document.createElement('div');rz.className='doc-notepad-resize';rz.title='크기 조절 (좌상단 드래그)';pad.appendChild(rz);
  let rzs=null;
  rz.addEventListener('pointerdown',e=>{e.preventDefault();rzs={x:e.clientX,y:e.clientY,w:pad.offsetWidth,h:pad.offsetHeight};try{rz.setPointerCapture(e.pointerId)}catch{}});
  rz.addEventListener('pointermove',e=>{if(!rzs)return;const maxW=window.innerWidth-32,maxH=window.innerHeight-140;pad.style.width=Math.max(300,Math.min(rzs.w+(rzs.x-e.clientX),maxW))+'px';pad.style.height=Math.max(300,Math.min(rzs.h+(rzs.y-e.clientY),maxH))+'px';});
  const rzEnd=e=>{if(rzs){rzs=null;try{rz.releasePointerCapture(e.pointerId)}catch{}}};
  rz.addEventListener('pointerup',rzEnd);rz.addEventListener('pointercancel',rzEnd);
  const cp=pad.querySelector('.doc-note-copy');cp.onclick=async()=>{const ok=await copyText(ta.value);cp.innerHTML=IC.copy+(ok?'복사됨!':'Ctrl+C 로');setTimeout(()=>cp.innerHTML=IC.copy+'복사',1400);ta.focus()};
  const cl=pad.querySelector('.doc-note-clear');let armed=false;
  cl.onclick=()=>{if(!armed){armed=true;cl.innerHTML=IC.trash+'확인?';setTimeout(()=>{armed=false;cl.innerHTML=IC.trash+'지우기'},2500);return}ta.value='';try{localStorage.removeItem(KEY)}catch{}sv.textContent='';armed=false;cl.innerHTML=IC.trash+'지우기';ta.focus();};

  const fab=document.createElement('div');fab.className='doc-fab';
  const nb=document.createElement('button');nb.className='doc-note-btn';nb.type='button';nb.title='메모지';nb.setAttribute('aria-label','메모지 열기');nb.innerHTML=IC.note;
  const toggle=f=>{const o=f??!pad.classList.contains('open');pad.classList.toggle('open',o);nb.classList.toggle('open',o);if(o)ta.focus();};
  nb.onclick=()=>toggle();
  document.addEventListener('keydown',e=>{if(e.key==='Escape'&&pad.classList.contains('open'))toggle(false)});
  fab.appendChild(nb);document.body.appendChild(fab);
})();

/* ---------- decision-form 런타임 (사람에게 답을 받는 문서 — 결정·미결·피드백) ----------
   폼의 CSS(.dec/.opt/.rec/.commit-bar/#toast/#md-output)는 doc.css 에 있고, 동작은 여기에
   한 번만 둡니다. 페이지마다 스크립트를 다시 쓰면 버튼 id 와 라벨이 문서마다 갈리고,
   회신 버튼이 아예 빠진 문서까지 생깁니다(독자가 고른 답을 돌려줄 방법이 없는 문서).

   🔴 opt-in: `.commit-bar[data-decisions]` 가 있을 때만 붙습니다.

   🔴 스코프. 항목 안의 radio·메모는 **그 섹션 안에서만** 찾습니다. 문서 전역으로 찾으면
   같은 name 을 쓰는 폼이 둘 있을 때 서로의 값을 읽습니다.

   마크업:
     <section class="dec" data-decision="키" data-title="짧은 제목">
       <h3>...</h3>
       <div class="decision-form">
         <label class="opt"><input type="radio" name="키" value="선택지 문구" checked>
           <strong>제목</strong> — 설명 <span class="rec">권고</span></label>
         <label class="fld"><span>메모</span><textarea name="키-note"></textarea></label>
       </div>
     </section>
     <div class="commit-bar" data-decisions>
       <button type="button" class="primary" data-act="copy-md">Markdown 복사</button>
       <button type="button" class="secondary" data-act="download-json">JSON</button>
       <button type="button" class="clear" data-act="reset">권고안으로</button>
     </div>
   → 저장·복원·상태문구·Markdown 생성·복사(평문 HTTP 폴백)·초기화는 전부 자동입니다. */
(function(){
  // 긴 문서는 회신 바를 위·아래 둘 이상 두기도 합니다. 전부 같은 결정 집합을 다루므로
  // 모두에 바인딩하고, 상태문구·출력칸은 첫 번째 바 기준으로 한 벌만 만듭니다.
  const bars=[...document.querySelectorAll('.commit-bar[data-decisions]')];
  const bar=bars[0];
  if(!bar)return;
  const nodes=[...document.querySelectorAll('.dec[data-decision]')];
  if(!nodes.length){
    console.warn('[doc.js] commit-bar[data-decisions] 는 있는데 결정 항목이 없습니다 — '
      +'.dec[data-decision] 섹션이 필요합니다');
    return;
  }
  const KEY='doc-decisions:'+location.pathname;
  // 🔴 hero-wrap 이 이 블록보다 먼저 돌며 h1 을 main.doc 밖(header.doc-hero)으로 옮깁니다.
  // `.doc-hero h1` 을 먼저 보지 않으면 항상 <title> 폴백으로 빠져 h1 과 다른 문구가 실립니다.
  const docTitle=(document.querySelector('.doc-hero h1, main.doc h1, .doc h1, title')?.textContent||'결정').trim();

  // 손으로 붙인 번호("01." · "3)")만 뗍니다. 구두점을 optional 로 두면 `2026-08-17` 의
  // 연도까지 먹습니다 — "## 1. -08-17" (2026-08-18 실측). 구두점을 필수로 둡니다.
  const titleOf=(s,n)=>(s.dataset.title||s.querySelector('h3,h4')?.textContent||n||'')
    .replace(/^\s*\d+[.)]\s*/,'').trim();
  const items=nodes.map(el=>{
    const n=el.dataset.decision;
    return {n,title:titleOf(el,n),el};
  });

  // 🔴 항상 항목 el 안에서만 찾습니다(전역 X). 메모는 name="<키>-note" 입니다.
  const radiosOf=it=>[...it.el.querySelectorAll('input[type="radio"]')];
  const pickedOf=it=>radiosOf(it).find(r=>r.checked)||null;
  const noteOf=it=>it.el.querySelector(`[name="${CSS.escape(it.n)}-note"]`);
  const collect=()=>items.map(it=>{
    const r=pickedOf(it);
    return {n:it.n,title:it.title,value:r?r.value:'',
            note:(noteOf(it)?.value||'').trim(),
            rec:!!r?.closest('.opt')?.querySelector('.rec')};
  });

  // 상태문구·출력칸·토스트는 없으면 만듭니다 (페이지가 직접 두면 그것을 씁니다)
  const need=(sel,make)=>document.querySelector(sel)||make();
  const status=need('.commit-bar .status',()=>{const s=document.createElement('span');s.className='status';s.setAttribute('aria-live','polite');bar.prepend(s);return s;});
  const out=need('#md-output',()=>{const t=document.createElement('textarea');t.id='md-output';t.setAttribute('aria-label','복사할 Markdown');bar.after(t);return t;});
  const toast=need('#toast',()=>{const d=document.createElement('div');d.id='toast';d.setAttribute('role','status');document.body.appendChild(d);return d;});
  const say=m=>{toast.textContent=m;toast.classList.add('show');setTimeout(()=>toast.classList.remove('show'),2600);};

  // 🔴 복원 규칙 — **저장된 문구가 그대로 있을 때만 복원합니다.**
  // 두 가지 실패가 서로 반대 방향이라 한쪽만 막으면 다른 쪽이 열립니다.
  //   ① 값만 키로 쓰면: 발행 뒤 선택지 문구를 한 글자 고쳐도 저장된 답이 조용히 사라집니다.
  //   ② 순번으로 폴백하면: 선택지 순서가 바뀌었을 때 **다른 뜻의 답으로 조용히 바뀝니다** — 더 나쁩니다.
  // 그래서 순번 복원은 하지 않고, 복원 못 한 항목을 상태문구로 **드러냅니다**(조용한 실패 금지).
  // 순번은 진단용으로만 저장합니다.
  let unrestored=[];
  const save=()=>{
    const f={_v:1};
    collect().forEach((d,i)=>{
      f[d.n]=d.value;
      f[d.n+'-note']=d.note;
      f[d.n+'-idx']=radiosOf(items[i]).findIndex(r=>r.checked);
    });
    try{localStorage.setItem(KEY,JSON.stringify(f))}catch{}
  };
  const restore=()=>{
    let s=null;try{s=JSON.parse(localStorage.getItem(KEY)||'null')}catch{}
    if(!s)return;
    unrestored=[];
    for(const it of items){
      const t=noteOf(it); if(t&&typeof s[it.n+'-note']==='string')t.value=s[it.n+'-note'];
      const saved=s[it.n];
      if(!saved)continue;
      const rs=radiosOf(it); if(!rs.length)continue;
      const byValue=rs.find(r=>r.value===saved);
      if(byValue)byValue.checked=true;
      else unrestored.push(it.title);   // 문구·순서가 바뀌었습니다 — 짐작해서 고르지 않습니다
    }
  };
  const refresh=()=>{
    const d=collect(),missing=d.filter(x=>!x.value),changed=d.filter(x=>x.value&&!x.rec);
    if(unrestored.length){
      status.textContent=`이전에 저장한 답 ${unrestored.length}건을 복원하지 못했습니다`
        +`(선택지 문구가 바뀜: ${unrestored.join(', ')}) — 다시 골라 주세요.`;
      return;
    }
    // `.rec`(권고) 표시가 문서에 하나도 없으면 "권고와 다름" 을 말할 근거가 없습니다.
    // 그때도 전건을 "권고와 다른 선택" 이라고 보고하면 거짓 경보입니다.
    const hasRec=!!document.querySelector('.opt .rec');
    status.textContent=missing.length
      ? `미선택 ${missing.length}건: ${missing.map(x=>x.title).join(', ')}`
      : !hasRec
        ? `${d.length}건 모두 선택됐습니다. 복사해서 붙여 주세요.`
        : changed.length
          ? `권고와 다른 선택 ${changed.length}건 — ${changed.map(x=>x.title).join(', ')}`
          : '전부 권고안 그대로입니다. 복사해서 붙여 주시면 그대로 진행합니다.';
  };
  const markdown=()=>{
    // 제목에 이미 "결정"이 있으면 덧붙이지 않습니다 ("… 결정 3건 — 결정" 이 되는 것을 막습니다)
    const head=/결정|decision/i.test(docTitle)?docTitle:`${docTitle} — 결정`;
    const L=[`# ${head}`,'',`> ${new Date().toISOString().slice(0,10)} · ${location.pathname}`,''];
    collect().forEach((d,i)=>{
      L.push(`## ${i+1}. ${d.title}`,`- **결정**: ${d.rec?'(권고대로) ':''}${d.value||'미선택'}`);
      if(d.note)L.push(`- **메모**: ${d.note}`);
      L.push('');
    });
    return L.join('\n');
  };

  // 독자가 손대는 순간 "복원 못 함" 경고는 역할을 다합니다 — 그대로 두면 상태문구가 굳습니다.
  document.addEventListener('input',e=>{if(e.target.closest('.decision-form')){unrestored=[];save();refresh();}});

  const onBarClick=async e=>{
    const act=e.target.closest('[data-act]')?.dataset.act;
    if(!act)return;
    if(act==='copy-md'){
      // 🔴 성공 판정을 execCommand 반환값에 맡기지 않습니다. 그 값은 true 인데 클립보드가 비는
      // 브라우저가 있고(평문 HTTP 에는 navigator.clipboard 자체가 없습니다), 그러면 "복사했습니다"
      // 토스트를 띄우고도 붙여넣을 게 없습니다 — 조용한 실패입니다. 그래서 결과와 무관하게 **본문을
      // 항상 눈앞에 펼치고 전체 선택**해 둡니다. 자동 복사가 안 돼도 Ctrl+C 한 번이면 끝납니다.
      const text=markdown();
      out.value=text;
      out.style.display='block';
      const ok=await copyText(text);
      out.focus();out.select();
      try{out.setSelectionRange(0,text.length)}catch{}
      out.scrollIntoView({block:'nearest',behavior:'smooth'});
      say(ok?'복사했습니다 — 채팅에 붙여넣어 주세요. (안 붙으면 아래 상자에서 Ctrl+C)'
             :'아래 상자가 전체 선택돼 있습니다 — Ctrl+C 로 복사해 주세요.');
    }else if(act==='download-json'){
      const blob=new Blob([JSON.stringify(collect().map(({n,title,value,note,rec})=>({n,title,value,note,rec})),null,2)],{type:'application/json'});
      // ⚠️ 점 표기(createObjectURL 앞에 점)로 부르면 스타일시트의 자산 참조 문법과 같은 모양이
      //    되어, 발행기가 없는 자산으로 오인합니다. 그래서 대괄호 호출로 그 모양을 피합니다.
      const objUrl=URL['createObjectURL'](blob);
      const a=document.createElement('a');a.href=objUrl;
      a.download=(location.pathname.split('/').pop()||'decisions').replace(/\.html?$/,'')+'-decisions.json';
      a.click();URL['revokeObjectURL'](objUrl);say('JSON 을 내려받았습니다.');
    }else if(act==='reset'){
      if(!confirm('입력을 모두 지우고 권고안으로 되돌릴까요?'))return;
      try{localStorage.removeItem(KEY)}catch{}
      document.querySelectorAll('.decision-form textarea').forEach(t=>t.value='');
      document.querySelectorAll('.decision-form .opt .rec').forEach(r=>{const i=r.closest('.opt').querySelector('input[type="radio"]');if(i)i.checked=true;});
      out.value='';out.style.display='none';refresh();say('권고안으로 되돌렸습니다.');
    }
  };
  bars.forEach(b=>b.addEventListener('click',onBarClick));

  restore();refresh();
})();

/* ---------- quiz (이해 점검 — 상세 기술/원리 설명용 공유 컴포넌트) ---------- */
/* 마크업: <section class="doc-quiz"><ol><li class="doc-q"><p class="doc-q-stem">..</p>
     <ul class="doc-q-opts"><li>오답</li><li data-correct>정답</li>..</ul>
     <p class="doc-q-explain">해설</p></li>..</ol></section>
   → 보기 셔플·클릭 채점(정답 blue/오답 red)·해설 표시·점수 aria-live 는 여기서 자동. */
for(const quiz of document.querySelectorAll('.doc-quiz')){
  const qs=[...quiz.querySelectorAll('.doc-q')];
  if(!qs.length)continue;
  let answered=0,correct=0;
  let score=quiz.querySelector('.doc-quiz-score');
  if(!score){score=document.createElement('p');score.className='doc-quiz-score';quiz.appendChild(score);}
  score.setAttribute('aria-live','polite');
  const paint=()=>{score.textContent=answered?`${correct} / ${qs.length} 정답${answered<qs.length?` · ${qs.length-answered}문항 남음`:''}`:'';};
  for(const q of qs){
    const ul=q.querySelector('.doc-q-opts'); if(!ul)continue;
    const opts=[...ul.querySelectorAll(':scope > li')];
    for(let i=opts.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[opts[i],opts[j]]=[opts[j],opts[i]];}
    opts.forEach(o=>ul.appendChild(o));
    opts.forEach(o=>{o.setAttribute('role','button');o.setAttribute('tabindex','0');
      const pick=()=>{
        if(q.classList.contains('answered'))return;
        q.classList.add('answered');
        const ok=o.hasAttribute('data-correct');
        o.classList.add(ok?'correct':'wrong');
        if(!ok){const c=ul.querySelector(':scope > li[data-correct]');c&&c.classList.add('correct');}
        answered++; if(ok)correct++; paint();
      };
      o.addEventListener('click',pick);
      o.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();pick();}});
    });
  }
  paint();
}

/* ---------------- tabs (.doc-tabs / .rca-tabs / .essay-tabs) ----------------
   버튼의 data-target 이 pane 의 id 를 가리킵니다. 활성 버튼은 aria-selected="true",
   활성 pane 은 data-active. 위임 핸들러라 나중에 붙는 마크업에도 동작합니다. */
(function tabs(){
  const NAV='.doc-tabs,.rca-tabs,.essay-tabs';
  const activate=(nav,btn)=>{
    const id=btn.dataset.target||btn.getAttribute('aria-controls');
    if(!id)return;
    nav.querySelectorAll('button,a').forEach(b=>b.setAttribute('aria-selected',b===btn?'true':'false'));
    nav.querySelectorAll('button,a').forEach(b=>{
      const t=b.dataset.target||b.getAttribute('aria-controls');
      const p=t&&document.getElementById(t);
      if(p)p.toggleAttribute('data-active',b===btn);
    });
    const pane=document.getElementById(id);
    if(pane)pane.setAttribute('data-active','');
  };
  document.addEventListener('click',e=>{
    const btn=e.target.closest(NAV+' > button,'+NAV.split(',').map(s=>s+' > a[data-target]').join(','));
    if(!btn)return;
    const nav=btn.closest(NAV);
    if(!nav)return;
    e.preventDefault();
    activate(nav,btn);
  });
  // 첫 화면: 아무 pane 도 data-active 가 아니면 첫 탭을 켭니다(빈 문서로 보이는 사고 방지).
  document.querySelectorAll(NAV).forEach(nav=>{
    const btns=[...nav.querySelectorAll('button,a')].filter(b=>b.dataset.target||b.getAttribute('aria-controls'));
    if(!btns.length)return;
    const cur=btns.find(b=>b.getAttribute('aria-selected')==='true')||btns[0];
    activate(nav,cur);
  });
})();
