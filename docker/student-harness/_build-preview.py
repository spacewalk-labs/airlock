#!/usr/bin/env python3
# 하네스 미리보기 빌더 — student-harness/ 안의 SoT(지침·설정·스킬)를 읽어
# 자기완결 HTML 한 장(하네스-미리보기.html)으로 렌더. 원본을 직접 읽으므로 드리프트 없음.
# 재생성: 이 폴더에서 `python3 _build-preview.py`
import re, json, html as _html, pathlib, markdown

SRC = pathlib.Path(__file__).resolve().parent

# zip 빌더(_build-download.py)가 담는 것과 같은 조건 — 미리보기가 "함께 들어 있다"고 적었는데
# zip 엔 없는(또는 그 반대인) 일이 없도록 양쪽을 같은 규칙으로 맞춘다.
def packed(f):
    return f.is_file() and '__pycache__' not in f.parts and f.suffix not in ('.pyc', '.zip')

# 표시 순서 '힌트'일 뿐이다 — 실제 목록은 skills/ 스캔이 정한다(아래 SKILLS).
# 예전엔 이 리스트가 곧 목록이라, 스킬을 추가해도 미리보기에서 조용히 빠졌다(에러도 경고도 없이).
SKILL_ORDER = ['task-discussion', 'task-doc', 'worklog', 'session-resume', 'session-handoff',
               'session-close', 'worktree', 'ship',
               'self-verify', 'code-review', 'pikes-filter',
               'subagent', 'codex', 'web-research', 'browser-session',
               'secret-manage', 'share-docs',
               'orbstack-provision', 'web-deploy',
               'repo-bootstrap', 'web-project-bootstrap', 'crawling-scraping',
               'hwpx-doc', 'excel-io', 'cad-read',
               'claude-md-gardener', 'harness-gardener']

# 실제 목록 = 디렉토리 스캔. 힌트에 있는 것 먼저, 나머지는 이름순으로 뒤에.
FOUND = sorted(p.parent.name for p in SRC.glob('skills/*/SKILL.md') if p.is_file())
# SKILL.md 없는 항목(폴더든 파일이든)은 이 스캔에서 통째로 빠지는데, zip 빌더의 rglob 은
# 그대로 담는다 = 미리보기에 없는 파일이 배포된다. 조용히 어긋나므로 멈춘다.
_stray = sorted(e.name for e in (SRC / 'skills').iterdir()
                if e.name not in FOUND and e.name != '__pycache__')
if _stray:
    raise SystemExit(f'skills/ 에 SKILL.md 가 없는 항목이 있습니다: {_stray} — '
                     '미리보기에서 통째로 빠지는데 zip 에는 담깁니다. '
                     'SKILL.md 를 넣거나 그 항목을 skills/ 밖으로 옮기세요')
_gone = [n for n in SKILL_ORDER if n not in FOUND]
if _gone:
    raise SystemExit(f'SKILL_ORDER 에 있는데 skills/ 에 없습니다: {_gone} — 이름을 고치거나 힌트에서 빼세요')
SKILLS = [n for n in SKILL_ORDER if n in FOUND] + [n for n in FOUND if n not in SKILL_ORDER]

def split_front(text):
    m = re.match(r'^---\n(.*?)\n---\n?(.*)\Z', text, re.S)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        if not line.strip():
            continue
        # 이 파서는 'key: value' 한 줄짜리만 읽는다. YAML 블록/접기(`| > >- |+ >2`)나 들여쓴
        # 연속줄은 조용히 잘리거나 '>' 한 글자로 렌더된다 — 못 읽는 형태면 넘기지 말고 멈춘다.
        # 블록 지시자는 '줄 끝까지 그것뿐'일 때만이다 — `description: >90% 자동화…` 처럼 값이
        # 그냥 '>'로 시작하는 정상 한 줄을 오탐하면 멀쩡한 SKILL.md 가 거부된다.
        if line[0].isspace() or re.match(r'^[\w.-]+:\s*[|>][-+]?[1-9]?\s*\Z', line):
            raise SystemExit(f'frontmatter 에 여러 줄 값이 있습니다: {line.strip()[:60]!r} — '
                             '이 빌더는 한 줄 "키: 값"만 읽습니다(연속줄·| ·> 미지원). 한 줄로 합치세요')
        if ':' in line:
            k, v = line.split(':', 1)
            meta[k.strip()] = v.strip().strip('"')
    return meta, m.group(2)

def md2html(text):
    html = markdown.Markdown(extensions=['pymdownx.superfences', 'tables', 'sane_lists']).convert(text)
    return fix_skill_links(html)


# SKILL.md 안의 상대 링크(skills/<이름>/SKILL.md · ../<이름>/SKILL.md)는 이 단일 파일
# 스냅샷에선 열 수 없는 경로다(실측 404). 같은 페이지에 그 스킬 본문이 이미 있으니
# 페이지 내 앵커(#skill-<이름>)로 돌린다. 대응 앵커가 없으면 링크를 걷어내고 텍스트만 남긴다.
def fix_skill_links(html):
    def repl(m):
        name = m.group('name')
        if name in SKILLS:
            return f'href="#skill-{name}"'
        return 'href="#"'
    html = re.sub(r'href="(?:\.\./|skills/)(?P<name>[a-z0-9-]+)/SKILL\.md"', repl, html)
    # 남은 .md 직링크(문서 밖 파일)는 링크를 없애고 코드 표기로
    html = re.sub(r'<a href="(?!#|https?:|/)[^"]*\.md">(.*?)</a>', r'<code>\1</code>', html, flags=re.S)
    return html

CSS = """
:root{--bg:#eef1f6;--card:#fff;--ink:#1a2230;--mut:#5b6472;--sub:#8a93a3;--acc:#1a5fd0;--bd:#e2e7ef;--code:#0d1220;--codetx:#dfe7f5;--chip:#eaf1ff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Pretendard","Noto Sans KR",Segoe UI,Roboto,sans-serif;line-height:1.72;font-size:16px}
.topbar{background:#0a0d14;color:#dbe4f3;padding:11px 20px;font-size:13px;font-weight:700}
.topbar b{color:#5aa0ff}
.topbar a{color:#8fc0ff;text-decoration:none;border-bottom:1px solid rgba(143,192,255,.35)}
.topbar a:hover{color:#cfe2ff;border-bottom-color:#cfe2ff}
.topbar a.back{display:inline-block;padding:3px 12px;border-radius:999px;font-weight:800;border:1px solid rgba(143,192,255,.5);background:rgba(90,160,255,.15);color:#cfe2ff}
.topbar a.back:hover{background:rgba(90,160,255,.3);border-color:#8fc0ff;color:#fff}
.topbar .sep{opacity:.45;margin:0 7px}
.wrap{max-width:860px;margin:26px auto;padding:0 18px}
.hero{background:linear-gradient(135deg,#12203a,#1a3f8f);color:#eaf1ff;border-radius:16px;padding:28px 30px;margin-bottom:22px}
.hero h1{margin:0 0 8px;font-size:25px}
.hero p{margin:0;color:#cfe0ff;font-size:14.5px}
.toc{background:var(--card);border:1px solid var(--bd);border-radius:14px;padding:16px 20px;margin-bottom:22px}
.toc b{display:block;margin-bottom:8px;color:var(--acc)}
.toc a{display:inline-block;margin:3px 10px 3px 0;font-size:13.5px;color:var(--acc);text-decoration:none}
.file{background:var(--card);border:1px solid var(--bd);border-radius:14px;padding:22px 26px;margin-bottom:18px;box-shadow:0 6px 22px rgba(20,40,80,.05)}
.file>.path{font-family:"SFMono-Regular",Menlo,Consolas,monospace;font-size:13px;color:#1a6b3f;background:#eafaf0;border:1px solid #cdeeda;border-radius:6px;padding:3px 9px;display:inline-block;margin-bottom:6px}
.file h2{font-size:19px;margin:6px 0 4px}
.desc{color:var(--mut);font-size:14px;margin:0 0 12px;padding-bottom:12px;border-bottom:1px solid var(--bd)}
h3{font-size:16px;margin:18px 0 6px}
a{color:var(--acc)}
code{background:#eef2f8;border:1px solid var(--bd);border-radius:6px;padding:1px 6px;font-size:13px;font-family:"SFMono-Regular",Menlo,Consolas,monospace}
pre{background:var(--code);color:var(--codetx);border-radius:12px;padding:15px 17px;overflow:auto;font-size:13px;line-height:1.6}
pre code{background:none;border:0;padding:0;color:inherit}
blockquote{margin:12px 0;padding:10px 15px;background:var(--chip);border-left:4px solid var(--acc);border-radius:0 10px 10px 0;color:#22385f}
blockquote p{margin:4px 0}
ul,ol{margin:8px 0;padding-left:22px}li{margin:4px 0}
table{border-collapse:collapse;width:100%;margin:10px 0}
th,td{border:1px solid var(--bd);padding:6px 9px;text-align:left}th{background:#f2f6fc}
hr{border:0;border-top:1px solid var(--bd);margin:18px 0}
.foot{max-width:860px;margin:14px auto 40px;padding:0 20px;color:var(--sub);font-size:12.5px}
"""

def anchor(s):
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')

blocks, toc = [], []

# 1) 지침 파일 CLAUDE.md (= AGENTS.md)
meta, body = split_front((SRC / 'CLAUDE.md').read_text(encoding='utf-8'))
aid = 'claude-md'
toc.append((aid, 'CLAUDE.md (= AGENTS.md)'))
blocks.append(f'<div class="file" id="{aid}"><span class="path">~/.claude/CLAUDE.md &nbsp;=&nbsp; ~/.codex/AGENTS.md</span>'
              f'<p class="desc">전역 기본 규칙 — Claude·Codex 공용(같은 내용, 이름만 다름)</p>{md2html(body)}</div>')

# 2) settings.json
sj = (SRC / 'settings.json').read_text(encoding='utf-8')
# 개수를 손으로 적으면 settings.json 을 고칠 때마다 조용히 어긋난다 — 바로 아래에 JSON 전문이
# 붙으므로 눈앞에서 틀린다. 실제로 센다. 깨진 settings.json 이 그대로 배포되는 게 더 나쁘니
# 파싱 실패는 넘기지 않고 멈춘다.
try:
    _perm = json.loads(sj)['permissions']
    _deny, _ask = _perm['deny'], _perm['ask']
    # 배열인지까지 봐야 한다 — 문자열·객체도 len() 이 되므로 글자수·키수를 개수인 양 렌더한다.
    if not isinstance(_deny, list) or not isinstance(_ask, list):
        raise TypeError('permissions.deny / permissions.ask 가 배열이 아닙니다')
    n_deny, n_ask = len(_deny), len(_ask)
except (ValueError, KeyError, TypeError) as e:
    raise SystemExit(f'settings.json 을 읽을 수 없습니다 ({type(e).__name__}: {e}) — '
                     'JSON 문법과 permissions.deny / permissions.ask 를 확인하세요')
toc.append(('settings', 'settings.json'))
blocks.append(f'<div class="file" id="settings"><span class="path">~/.claude/settings.json</span>'
              f'<p class="desc">기본 권한 — 되돌릴 수 있는 일은 다 허용, 되돌릴 수 없는 일'
              f'(deny {n_deny} · ask {n_ask})에만 멈춤</p>'
              f'<pre><code>{_html.escape(sj)}</code></pre></div>')

# 3) 스킬들
# SKILL.md 옆 딸림 파일(템플릿·스타일·스크립트)도 함께 배포된다.
# 그중 '실행되는 것'(스크립트)은 파일명만 봐선 무슨 일을 하는지 알 수 없다 — 워크트리를
# 지우는 스크립트를 읽어 보지도 못한 채 돌리게 된다. 그래서 스크립트는 본문까지 편다.
# 나머지(템플릿·CSS·JS)는 doc.css 59KB·doc.js 26KB 처럼 커서 다 펴면 '한눈에 보기'가
# 깨진다 — 이름·크기·'내용 생략'을 적어 빠졌다는 사실만은 보이게 한다.
def is_script(f):
    return f.suffix in ('.sh', '.py') or bool(f.stat().st_mode & 0o111)

def size_of(f):
    n = f.stat().st_size
    return f'{n:,} B' if n < 1024 else f'{round(n / 1024):,} KB'

def read_script(f):
    try:
        return f.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        raise SystemExit(f'{f.relative_to(SRC).as_posix()} 는 UTF-8 텍스트가 아닙니다 '
                         '(바이너리 실행 파일?) — 미리보기에 펼 수 없습니다. skills/ 밖으로 옮기세요')

for name in SKILLS:
    sdir = SRC / 'skills' / name
    meta, body = split_front((sdir / 'SKILL.md').read_text(encoding='utf-8'))
    aid = 'skill-' + name
    toc.append((aid, f'/{name}'))
    # description 이 없으면 설명이 빈 채로 렌더되고 빌드는 정상 종료한다 — 조용하니 멈춘다.
    if not meta.get('description', '').strip():
        raise SystemExit(f'skills/{name}/SKILL.md frontmatter 에 description 이 없습니다 — '
                         '빈 설명으로 렌더됩니다. description 을 넣으세요')
    desc = _html.escape(meta['description'].strip())
    # 제외 대상은 '이 스킬의' SKILL.md 하나뿐이다 — 이름으로 거르면 하위 폴더의 동명 파일
    # (skills/x/examples/SKILL.md)까지 목록에서 빠지는데 zip 에는 담긴다.
    extras = sorted((f for f in sdir.rglob('*') if packed(f) and f != sdir / 'SKILL.md'),
                    key=lambda f: f.relative_to(sdir).as_posix())
    extra_html = ('<p class="desc" style="border:0;padding:0;margin:-8px 0 12px">📎 함께 들어 있는 파일: '
                  + ' · '.join(f'<code>{_html.escape(f.relative_to(sdir).as_posix())}</code>'
                               f' ({size_of(f)} · {"아래 전문" if is_script(f) else "내용 생략"})'
                               for f in extras) + '</p>') if extras else ''
    script_html = ''.join(
        f'<h3>📎 {_html.escape(f.relative_to(sdir).as_posix())}</h3>'
        f'<pre><code>{_html.escape(read_script(f))}</code></pre>'
        for f in extras if is_script(f))
    blocks.append(f'<div class="file" id="{aid}"><span class="path">~/.claude/skills/{name}/SKILL.md</span>'
                  f'<p class="desc"><strong>스킬: {name}</strong> — {desc}</p>{extra_html}'
                  f'{md2html(body)}{script_html}</div>')

# 4) 훅 (자동으로 도는 안전장치)
HOOK_ORDER = [
    ('secret-guard.sh', 'PreToolUse — 파일에 키·토큰 값이 들어가려 하면 차단'),
    ('session-close-reminder.sh', 'Stop/PreCompact — worklog·정리 안 하고 끝나면 상기'),
    ('session-start-restore.sh', 'SessionStart — 최근 작업 로그를 불러와 이어받게'),
]
# 훅은 설명 문구가 필요해 손으로 적지만, 폴더와 어긋나면 빌드를 멈춘다(조용한 누락 방지).
# 확장자 무관 + 하위 폴더까지 훑는다 — 'hooks/*.sh' 로 훑으면 .py 훅이나 hooks/lib/x.sh 가
# 미리보기·"훅 N종"에서 조용히 빠지고 zip 에만 들어간다.
_h_found = sorted(p.relative_to(SRC / 'hooks').as_posix()
                  for p in (SRC / 'hooks').rglob('*') if packed(p))
_h_listed = sorted(f for f, _ in HOOK_ORDER)
if _h_found != _h_listed:
    raise SystemExit(f'HOOK_ORDER 와 hooks/ 가 다릅니다 — 목록 {_h_listed} / 실제 {_h_found}')

for fname, hdesc in HOOK_ORDER:
    p = SRC / 'hooks' / fname
    aid = 'hook-' + fname.replace('.', '-')
    toc.append((aid, f'hooks/{fname}'))
    code = _html.escape(p.read_text(encoding='utf-8'))
    blocks.append(f'<div class="file" id="{aid}"><span class="path">~/.claude/hooks/{fname}</span>'
                  f'<p class="desc"><strong>훅: {fname}</strong> — {_html.escape(hdesc)}</p>'
                  f'<pre><code>{code}</code></pre></div>')

toc_html = '<div class="toc"><b>이 하네스에 들어 있는 것</b>' + ''.join(
    f'<a href="#{i}">{_html.escape(t)}</a>' for i, t in toc) + '</div>'

TPL = f"""<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>수강생 하네스 — 안에 무엇이 있나 · K-AI PRO Day 1</title>
<style>{CSS}</style></head><body>
<div class="topbar"><a href="/k-ai-pro.html"><b>[K-AI PRO]</b></a><span class="sep">›</span><a class="back" href="/k-ai-pro-airlock.html">← Day 1</a><span class="sep">›</span>하네스 미리보기</div>
<div class="wrap">
<div class="hero"><h1>🧰 수강생 하네스 — 안에 무엇이 있나</h1>
<p>에이전트가 내 방식대로·안전하게 일하도록 <code>~/.claude</code>에 까는 기본 세팅 한 벌.
아래는 실제 배포되는 파일들의 내용입니다 — 지침·설정·스킬·훅과 <strong>스크립트(<code>.sh</code>·<code>.py</code>·실행 파일)는 전문 그대로</strong>,
템플릿·스타일 같은 딸림 자료는 파일명과 크기만 적었습니다.</p></div>
{toc_html}
{''.join(blocks)}
</div>
<div class="foot">Airlock · 설치본에 고정된 하네스 스타터 내용</div>
</body></html>"""

out = SRC / '하네스-미리보기.html'
out.write_text(TPL, encoding='utf-8')
print(out.name, '·', len(toc), 'files ·', len(SKILLS), 'skills ·', len(HOOK_ORDER), 'hooks')
