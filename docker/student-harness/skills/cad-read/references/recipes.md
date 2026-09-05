# ezdxf 레시피 — cadread.py 가 안 해 주는 것

`cadread.py` 의 probe/text/geom 으로 안 되는 요구가 나왔을 때만 편다. 아래 조각은 전부 합성 도면(레이어·블록·치수·거울상 폴리라인)으로 실행해 확인한 것이다.

| 원하는 것 | §  |
|---|---|
| 조건으로 엔티티 고르기 | 1 |
| 블록 안을 실제 위치·크기로 펼치기 | 2 |
| 해치(빗금) 경계 | 3 |
| 스플라인·원호를 점열로 | 4 |
| 어떤 글자가 어느 방 안에 있나 | 5 |
| 도면을 그림으로 봐서 확인하기 | 6 |
| 깨진 파일 · 큰 파일 | 7 |

실행은 인라인 의존성으로 감싸면 설치가 필요 없다:

```bash
uv run --quiet --with ezdxf python3 - <<'PY'
...조각...
PY
```

## 1. 조건으로 엔티티 고르기

ezdxf 는 자체 질의 문법을 가진다. 파이썬 반복문으로 거르기 전에 이걸 쓴다.

```python
msp.query('LWPOLYLINE[layer=="A-WALL"]')          # 레이어 지정
msp.query('LINE CIRCLE ARC')                       # 여러 타입
msp.query('*[layer ? "A-.*"]')                     # 정규식 (? 연산자)
msp.query('TEXT[height>200]')                      # 숫자 비교
```

## 2. 블록 안을 실제 위치·크기로 펼치기

`INSERT` 는 블록을 **참조**만 한다. 블록 정의 좌표는 원점 기준이라 그대로 쓰면 전부 겹친다.
`virtual_entities()` 가 삽입점·축척·회전을 반영한 사본을 만들어 준다.

```python
for ins in msp.query("INSERT"):
    for e in ins.virtual_entities():        # 위치·스케일·회전이 적용된 임시 엔티티
        print(ins.dxf.name, e.dxftype(), e.dxf.get("insert", None))
```

중첩 블록은 한 겹씩만 풀린다 — 안쪽 `INSERT` 에 대해 다시 호출한다.

## 3. 해치(빗금) 경계

면적·영역 표시는 해치로 들어 있는 경우가 많다. 경계는 여러 종류(`PolylinePath` / `EdgePath`)라
타입을 확인하고 다뤄야 한다.

```python
for hatch in msp.query("HATCH"):
    for path in hatch.paths:
        if type(path).__name__ == "PolylinePath":         # PATH_TYPE 속성은 없다
            pts = [(v[0], v[1]) for v in path.vertices]   # 정점은 (x, y, bulge)
        else:
            pts = []          # EdgePath: LineEdge/ArcEdge/SplineEdge 를 개별 처리
        print(hatch.dxf.layer, type(path).__name__, len(pts))
```

## 4. 스플라인·원호를 점열로

면적·길이 계산은 직선 근사가 있어야 한다. `flattening(distance)` 는 원곡선과의 최대 오차를
`distance` 이하로 유지하며 점을 뽑는다 — 도면 단위이므로 mm 도면이면 `1.0` 이 1mm 오차다.

```python
for s in msp.query("SPLINE"):
    pts = [(p.x, p.y) for p in s.flattening(distance=1.0)]
for a in msp.query("ARC"):
    pts = [(p.x, p.y) for p in a.flattening(distance=1.0)]
```

**폴리라인에는 `flattening` 이 없다** — `LWPOLYLINE.flattening` 은 `AttributeError` 다.
호(bulge)를 품은 폴리라인은 `ezdxf.path.make_path(e).flattening(distance)` 로 편다
(`cadread.py geom` 이 쓰는 방법이고, OCS→WCS 변환까지 함께 해 준다).

## 5. 어떤 글자가 어느 방 안에 있나

실명(室名) 텍스트를 방 외곽선에 붙이는 표준 방법이다.

```python
from ezdxf.math import Vec2, is_point_in_polygon_2d

room = [Vec2(0,0), Vec2(5000,0), Vec2(5000,4000), Vec2(0,4000)]
r = is_point_in_polygon_2d(Vec2(2000,2000), room)
# 반환값은 bool 이 아니라 int: 1=내부, 0=경계 위, -1=외부.
# `if r:` 로 쓰면 경계 위(0)가 외부로 떨어지고 -1 이 참이 된다 — 반드시 `r >= 0` 처럼 비교한다.
```

## 6. 도면을 그림으로 봐서 확인하기

숫자가 이상할 때 눈으로 보는 것이 가장 빠르다. **`qsave` 헬퍼를 쓴다.**

```python
import ezdxf
from ezdxf.addons.drawing import matplotlib

doc = ezdxf.readfile("도면.dxf")
matplotlib.qsave(doc.modelspace(), "/tmp/preview.png",
                 bg="#FFFFFF", dpi=100, size_inches=(12, 9))
```

🔴 **`RenderContext` + `Frontend` 를 직접 배선하면 백지 PNG 가 나온다.** DXF 색상 7 은
"배경 반대색"이라 배경을 알려 주지 않으면 흰 바탕에 흰 선으로 그려진다. `qsave` 가 이 매핑을
대신 해 준다 — 수동 배선은 하지 않는다.

**한글은 그림에서 깨지거나 안 보인다** (matplotlib 기본 폰트에 CJK 가 없다). 그림은 형상 확인용이고,
글자는 `cadread.py text` 로 읽는다.

## 7. 깨진 파일 · 큰 파일

**깨진 파일** — `ezdxf.readfile` 이 실패하면 복구 모드로 다시 연다. 무엇을 고쳤는지 감사 로그가 남는다.

```python
from ezdxf import recover
doc, auditor = recover.readfile("도면.dxf")
if auditor.errors:
    print(f"복구 불가 오류 {len(auditor.errors)}건 — 결과를 신뢰하기 전에 확인")
```

**큰 파일** — 수십만 엔티티짜리는 통째로 메모리에 올리지 않는다.

```python
from ezdxf.addons import iterdxf
for e in iterdxf.opendxf("대형.dxf").modelspace():   # 스트리밍, 한 번에 하나씩
    if e.dxftype() == "TEXT":
        print(e.dxf.text)
```

`iterdxf` 는 읽기 전용이고 지원 엔티티가 제한적이다 — 안 되면 레이어를 좁혀 일반 경로로 돌아간다.
