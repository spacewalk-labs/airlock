---
name: hwpx-doc
description: 한글 HWPX 공문/기안문 양식을 채워 완성한다. 서식·테두리·레이아웃은 보존하고 본문만 자동 작성. 시작 전 분량·문체·중점을 3단계로 물어 확정한다.
---

# HWPX 공문 채우기 (hwpx-doc)

한글 **HWPX 양식**(빈 공문/기안문)을 받아 **서식·표·테두리·레이아웃은 그대로 두고 본문만 채워** 완성본을
만듭니다. HWPX는 사실 **zip 안의 XML**이라, 텍스트를 XML 수준에서 정밀 교체합니다.

> 이 스킬은 실전에서 깨지며 얻은 규칙의 집합입니다. **아래 "치명 규칙"을 어기면 문서가 깨집니다.**

## 0단계: 시작 전 3단계 질문 (★ 반드시 먼저, 하나씩 ①→②→③)

본문 작성 전에 아래를 **한 번에 하나씩** 물어 확정합니다. 사용자가 이미 답한 항목은 건너뜁니다.

1. **분량** — "총 몇 페이지로?(1p 요약 / 3p 보고 / 5p 상세 / 10p 계획서)"
2. **문체** — "개조식(명사형 종결 ~함/~추진, 공공 표준) vs 서술식(~합니다, 대외 공문)?"
3. **중점** — "어디에 중점?(배경·필요성 / 실행방안 / 기대효과 / 예산·일정 등)"

확정되면 선언합니다: **"목표 N페이지 · ○○식 · 중점 ○○ 기준으로 본문 약 M문단 설계"**.

**분량 환산**(A4·휴먼명조 15pt 기준): **1페이지 ≈ 본문 10~13문단**, 목표 문단 = (페이지−표지/목차)×11 (±10%).
개조식이면 +10~20% 가산. **중점 섹션에 전체 본문의 35~45% 배분**하고, 섹션별 문단 배분표를 먼저 짠 뒤 작성합니다.

> 분량을 늘릴 땐 **같은 말 반복 금지**: □ 소제목 세분화 · ○마다 ― 세부근거 2~3개 · ※ 참고/기대효과 추가 ·
> 원문의 수치·사례·고유명사 살리기.

---

## 1단계: 해제

```bash
mkdir -p hwpx_work && cd hwpx_work
cp 원본.hwpx 원본.zip && unzip -o 원본.zip -d original
```
수정 대상은 `Contents/section0.xml` 뿐. `mimetype·META-INF·BinData·Preview`는 건드리지 않습니다.

## 2단계: 구조 분석 (★ 인덱스 맵)

텍스트만 순회하지 말고 **문단의 부모 구조**를 파악합니다. 본문 단락(□○―※)은 보통 **하나의 `sec` 요소의
직계 자식**으로 죽 이어집니다. 이 구조를 무시하면 섹션 경계 탐색이 틀려 **본문이 통째로 삭제**됩니다.

```python
from lxml import etree
def ln(e): return etree.QName(e.tag).localname

tree = etree.parse('original/Contents/section0.xml'); root = tree.getroot()
sec_elem = next(e for e in root.iter() if ln(e) == 'sec')
sec_children = list(sec_elem)
for i, c in enumerate(sec_children):
    if ln(c) == 'p':
        txt = ''.join(t.text or '' for t in c.iter() if ln(t)=='t').strip()
        print(f"[{i}] p: {txt[:70]}")
    else:
        print(f"[{i}] {ln(c)}")
```

## 3단계: 치명 규칙

- **`linesegarray`(줄배치 캐시)는 "텍스트를 실제로 수정한 최소 단위 `p`의 직계만" 삭제.** 수정 문단의
  캐시를 안 지우면 글자가 겹치고, 반대로 하위 전체를 재귀 삭제하면 **미수정 셀의 spacing 캐시(예 -240)**까지
  지워져 빨간 줄 양식이 깨집니다.
- **XML을 문자열로 조합 금지**(f-string·concat·`.replace()`·`re.sub()` 전부 금지) — 오직 lxml.
- **XML 선언 수동 추가 금지 · section0.xml 전체 재작성 금지.**
- **섹션 경계를 텍스트로 탐색 금지** → 2단계 인덱스 맵을 씁니다.

```python
def remove_own_lineseg(p):
    for c in list(p):
        if ln(c) == 'linesegarray': p.remove(c)
```

## 4단계: 참조 단락 자동 탐지 + 섹션 본문 교체

**하드코딩 인덱스 대신, 기호로 참조 단락을 자동으로 찾습니다.** (양식이 바뀌어도 덜 깨짐)

```python
import copy
SYMS = {'box':'□', 'circle':'○', 'dash':'―', 'note':'※'}

def first_para_starting(sec_children, symbol):
    """본문 기호로 시작하는 첫 문단을 참조용으로 반환(deepcopy)."""
    for c in sec_children:
        if ln(c) != 'p': continue
        txt = ''.join(t.text or '' for t in c.iter() if ln(t)=='t').strip()
        if txt.startswith(symbol):
            return copy.deepcopy(c)
    return None

def find_refs(sec_children):
    refs = {k: first_para_starting(sec_children, s) for k, s in SYMS.items()}
    # ○를 못 찾으면 ―로, ※를 못 찾으면 ○/―로 대체 (양식마다 없는 기호 대비)
    refs['circle'] = refs['circle'] or refs['dash'] or refs['box']
    refs['note']   = refs['note']   or refs['circle']
    assert refs['box'], "□ 참조 단락을 못 찾음 — 2단계 출력에서 본문 기호 확인"
    return refs

def clone_para(ref_p, run_texts):
    new_p = copy.deepcopy(ref_p); remove_own_lineseg(new_p)
    runs = [c for c in new_p if ln(c) == 'run']
    for i, txt in enumerate(run_texts):
        if i < len(runs):
            for t in runs[i].iter():
                if ln(t) == 't': t.text = txt; break
    for r in runs[len(run_texts):]: new_p.remove(r)
    return new_p

def replace_section_body(sec_elem, start, end, refs, content_list):
    """content_list: [("box"|"circle"|"dash"|"note", "텍스트"), ...]"""
    for child in list(sec_elem)[start:end]: sec_elem.remove(child)
    sym_pad = {'box':' □  ', 'circle':'  ○ ', 'dash':'   ― ', 'note':'     ※ '}
    pos = start
    for typ, text in content_list:
        two = (typ == 'box')          # □는 기호 run + 텍스트 run 2개 구조가 흔함
        new_p = clone_para(refs[typ], [sym_pad[typ], text] if two else [sym_pad[typ] + text])
        sec_elem.insert(pos, new_p); pos += 1
```

> **★ 섹션은 반드시 역순(Ⅳ→Ⅲ→Ⅱ→Ⅰ)으로 교체.** 앞에서부터 하면 삽입/삭제로 뒤 인덱스가 틀어집니다.
> 순서 처리가 불가피하면 각 호출 후 `delta = len(content) - (end-start)`를 이후 인덱스에 누적하세요.

```python
refs = find_refs(sec_children)   # ← 자동 탐지 (하드코딩 인덱스 불필요)
replace_section_body(sec_elem, sec4_start, sec4_end, refs, sec4_content)
replace_section_body(sec_elem, sec3_start, sec3_end, refs, sec3_content)
replace_section_body(sec_elem, sec2_start, sec2_end, refs, sec2_content)
replace_section_body(sec_elem, sec1_start, sec1_end, refs, sec1_content)
```

## 5단계: 제목·날짜·기관명 교체 (★ run 삭제 금지)

제목 문단(보통 `sec_children[0]`)은 **페이지설정(secPr)·쪽번호(pageNum)·붉은 테두리 표(tbl)** 가 run에 섞여
있습니다. **제목 문단에서 run을 삭제하면 테두리 표가 통째로 사라집니다**(실제 치명 오류). 그래서 제목은
**표 내부 `t` 텍스트만** 교체합니다.

```python
def nearest_p(e):
    cur = e.getparent()
    while cur is not None and ln(cur) != 'p': cur = cur.getparent()
    return cur

def replace_text_anywhere(p_elem, old, new):
    """하위(표 포함)에서 old==t 텍스트만 교체. lineseg는 그 t가 속한 최소 p의 직계만 삭제."""
    n = 0
    for t in p_elem.iter():
        if ln(t) == 't' and t.text and old in t.text:
            t.text = t.text.replace(old, new); n += 1
            host = nearest_p(t)
            if host is not None: remove_own_lineseg(host)
    assert n > 0, f"'{old}' 못 찾음 — 자리표시 텍스트 재확인"
    return n

def set_run_text(p_elem, run_idx, new_text, remove_extra=False):
    """직계 run 텍스트 교체(제목 아닌 단순 항목용)."""
    runs = [c for c in p_elem if ln(c) == 'run']
    if run_idx < len(runs):
        for t in runs[run_idx].iter():
            if ln(t) == 't': t.text = new_text; break
    if remove_extra:
        for r in runs[run_idx+1:]: p_elem.remove(r)
    remove_own_lineseg(p_elem)
```

- **제목은 15자 내외**로 압축(20자 초과 금지).
- 교체 대상 **누락 금지**: 표지 제목·날짜·기관명, **본문 1p 상단 "제 목" 박스(누락 빈발)**, 섹션 헤더, 목차.
- 목차는 표 내부가 많음 → 번호(Ⅰ,Ⅱ…) 기준 순차 매핑, 치환 패턴 겹침 주의.

**교체 후 잔존 스캔(필수):**
```python
PLACEHOLDERS = ["보고서 양식(제목)", "제 목", "기관명", "세부내용"]
leftover = [(ph, t.text[:40]) for t in sec_elem.iter() if ln(t)=='t' and t.text
            for ph in PLACEHOLDERS if ph in t.text]
assert not leftover, f"자리표시 잔존: {leftover}"
```

## 6~7단계: 저장 + 재패키징

```python
tree.write('original/Contents/section0.xml', xml_declaration=True,
           encoding=tree.docinfo.encoding or 'UTF-8', standalone=tree.docinfo.standalone)
```
```python
import zipfile, os
with zipfile.ZipFile('결과물.hwpx', 'w') as zf:
    if os.path.exists('original/mimetype'):                       # mimetype 먼저, 비압축
        zf.write('original/mimetype', 'mimetype', compress_type=zipfile.ZIP_STORED)
    for dp, _, fs in os.walk('original'):
        for f in fs:
            arc = os.path.relpath(os.path.join(dp, f), 'original')
            if arc == 'mimetype': continue
            zf.write(os.path.join(dp, f), arc, compress_type=zipfile.ZIP_DEFLATED)
```

## 8단계: 검증 (무결성 + 분량)

```python
with zipfile.ZipFile('결과물.hwpx') as zf:
    assert zf.testzip() is None
    sec = next(e for e in etree.parse(zf.open('Contents/section0.xml')).getroot().iter() if ln(e)=='sec')
body = sum(1 for p in sec if (s:=''.join(t.text or '' for t in p.iter() if ln(t)=='t').strip()) and s[0] in '□○ㅇ―-※*')
TARGET = 55   # 0단계 확정값
assert body/TARGET >= 0.85, f"분량 미달({body}/{TARGET}) — 0단계 배분표로 보강 후 재패키징. 미달본 전달 금지"
```
결과물은 한컴 없이 열람 검증이 불가하므로 **구조 assert로 대신**합니다. 실패 시 원본 문단을
`sec_elem.replace(손상p, 원본p_deepcopy)`로 되돌리고 텍스트만 다시 교체합니다.

## 작성 원칙 (9단계)

- 문체는 0단계 확정값(개조식/서술식). 두괄식(결론→배경→세부). 순서: 목적/배경 → 세부 → 요청/협조 → 붙임.
- 관용: "~와 관련하여", "아래와 같이", "~하여 주시기 바랍니다".

## 체크리스트

⓪ 3단계 질문 확정·배분표 → ① 인덱스 맵 → ② `find_refs`로 참조 자동 탐지 → ③ **역순** 교체 →
④ 수정 문단 lineseg 삭제(직계만) → ⑤ 제목은 **run 삭제 없이** 표 내부만 교체·잔존 스캔 →
⑥ mimetype 비압축 첫 삽입 → ⑦ 무결성 + **분량 85%** 통과.
