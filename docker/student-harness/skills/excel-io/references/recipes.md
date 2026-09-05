# openpyxl 레시피

`xlsx.py` 의 probe/dump/check/recalc 로 안 되는 것을 직접 코드로 짤 때 편다.
아래 조각은 전부 실행해 확인한 것이다.

| 원하는 것 | § |
|---|---|
| 표를 보기 좋게 (글꼴·테두리·너비·숫자서식·틀고정) | 1 |
| 수식 — 합계·시트 간 참조·VLOOKUP | 2 |
| 차트 | 3 |
| 조건부 서식 | 4 |
| 병합셀을 데이터로 펴기 | 5 |
| 문자로 저장된 숫자 고치기 | 6 |
| 수만 행 — 스트리밍 읽기·쓰기 | 7 |
| pandas 로 집계하고 돌아오기 | 8 |

```bash
uv run --quiet --with openpyxl python3 - <<'PY'
...조각...
PY
```

## 1. 표 서식

```python
from openpyxl.styles import Font, Alignment, Border, Side, PatternFill
from openpyxl.utils import get_column_letter

for c in ws[1]:                                    # 머리행
    c.font = Font(bold=True, color="FFFFFF")
    c.fill = PatternFill("solid", start_color="4472C4")
    c.alignment = Alignment(horizontal="center")

thin = Side(style="thin")
for row in ws["A1:D4"]:
    for c in row:
        c.border = Border(left=thin, right=thin, top=thin, bottom=thin)

for col in range(1, 5):
    ws.column_dimensions[get_column_letter(col)].width = 14   # 열 너비는 글자 수 기준
for row in ws["B2:D4"]:
    for c in row:
        c.number_format = "#,##0"                  # 천단위 · "#,##0.0" · "0.0%" · "yyyy-mm-dd"
ws.freeze_panes = "A2"                             # 이 칸 위/왼쪽이 고정된다
```

열 너비는 자동 계산이 없다. 내용 길이로 정하려면 직접 잰다: `max(len(str(v)) for v in 열값) + 2`.

## 2. 수식

```python
ws.cell(row=i, column=4, value=f"=SUM(B{i}:C{i})")
ws["D9"] = "=SUM(D2:D8)"
ws["E2"] = "=VLOOKUP(A2,단가!$A$2:$B$4,2,FALSE)"   # 시트 이름은 그대로, 절대참조에 $
ws["F2"] = "=IFERROR(D2/E2,0)"                     # 0 나눗셈을 미리 막는다
```

시트 이름에 공백·특수문자가 있으면 작은따옴표로 감싼다: `='매출 요약'!A1`.

**수식을 넣은 뒤에는 반드시 `xlsx.py recalc` 를 돌린다** — openpyxl 은 계산을 하지 않으므로
그 전까지 값 칸은 비어 있다.

## 3. 차트

```python
from openpyxl.chart import BarChart, LineChart, PieChart, Reference

ch = BarChart(); ch.title = "분기 실적"; ch.y_axis.title = "백만원"
ch.add_data(Reference(ws, min_col=2, max_col=3, min_row=1, max_row=4), titles_from_data=True)
ch.set_categories(Reference(ws, min_col=1, min_row=2, max_row=4))
ws.add_chart(ch, "F2")                              # 좌상단이 놓일 칸
```

`titles_from_data=True` 면 데이터 범위의 **첫 행이 계열 이름**이므로 `min_row` 에 머리행을 포함한다.
`set_categories` 범위에는 머리행을 넣지 않는다 — 넣으면 축에 "제품"이 한 칸 끼어든다.

## 4. 조건부 서식

```python
from openpyxl.formatting.rule import CellIsRule, ColorScaleRule
from openpyxl.styles import PatternFill

ws.conditional_formatting.add("B2:C4",
    CellIsRule(operator="lessThan", formula=["100"],
               fill=PatternFill("solid", start_color="FFC7CE")))
ws.conditional_formatting.add("D2:D4",
    ColorScaleRule(start_type="min", start_color="FFFFFF",
                   end_type="max", end_color="63BE7B"))
```

`formula` 는 **리스트**이고 원소는 문자열이다 — 숫자를 그냥 넣으면 조용히 무시된다.

## 5. 병합셀을 데이터로 펴기

세로 병합된 분류 칸은 좌상단에만 값이 있어 그대로 읽으면 대부분의 행에서 분류가 사라진다.
원본을 건드리지 않으려면 **읽기용 사본에서만** 편다.

```python
for rng in list(ws.merged_cells.ranges):
    v = ws.cell(row=rng.min_row, column=rng.min_col).value
    ws.unmerge_cells(str(rng))
    for row in range(rng.min_row, rng.max_row + 1):
        for col in range(rng.min_col, rng.max_col + 1):
            ws.cell(row=row, column=col, value=v)
```

## 6. 문자로 저장된 숫자 고치기

`probe` 가 `number-as-text` 로 세어 주는 것들이다. 합계에서 조용히 빠지므로 집계 전에 편다.

```python
def to_num(v):
    """probe 의 number-as-text 판정과 같은 규칙으로 되돌린다."""
    if not isinstance(v, str):
        return v
    s = v.strip()
    if s.startswith("(") and s.endswith(")"):
        s = "-" + s[1:-1]                     # (1,200) = 회계식 음수
    for junk in (",", " ", "%", "\u20a9", "$", "\u20ac", "\u00a5", "\u00a3", "\xa0"):
        s = s.replace(junk, "")
    try:
        return float(s) if "." in s else int(s)
    except ValueError:
        return v                              # 진짜 문자는 그대로 둔다
```

`%` 가 붙은 값은 `/100` 이 필요한지 원본 서식을 보고 판단한다 — 자동으로 나누지 않는다.

## 7. 수만 행

```python
wb = openpyxl.Workbook(write_only=True)          # 쓰기: append 만 가능, 메모리 상주 없음
ws = wb.create_sheet("big")
for i in range(100000):
    ws.append([i, i * 2])
wb.save("big.xlsx")

wb = openpyxl.load_workbook("big.xlsx", read_only=True)   # 읽기: 순차 반복만 가능
for row in wb["big"].iter_rows(values_only=True):
    ...
wb.close()                                        # read_only 는 반드시 닫는다 (파일 핸들이 남는다)
```

`read_only` 모드에서는 `ws.cell()` 임의 접근과 `ws.max_row` 정확도를 기대하지 않는다.

## 8. pandas 로 집계하고 돌아오기

수치 집계만 필요할 때. **결과 워크북은 서식이 전부 사라지므로** 원본을 고쳐 돌려주는 일에는 쓰지 않는다.

```python
import pandas as pd
df = pd.read_excel("파일.xlsx", sheet_name="실적")        # header=2 로 머리행 지정 가능
agg = df.groupby("제품")["총액"].sum().reset_index()
with pd.ExcelWriter("결과.xlsx", engine="openpyxl") as w:
    agg.to_excel(w, sheet_name="집계", index=False)
```

`pd.read_excel` 은 **수식이 아니라 캐시된 값**을 읽는다 — 캐시가 없는 파일이면 `NaN` 이 나오니
먼저 `xlsx.py recalc` 를 돌린다. pandas 는 기본 설치가 아니므로 `uv run --with pandas` 로 부른다.
