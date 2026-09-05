# DWG 를 읽으려면 — ODA File Converter 설치

**이 문서는 `.dwg` 를 받았고 DXF 재수출을 못 받을 때만 읽는다.** DXF 만 다룬다면 필요 없다.

## 왜 변환이 필요한가

DWG 는 오토데스크 독점 **바이너리** 포맷이고 공개 규격이 없다. 텍스트인 DXF 와 달리 붙여넣기·
업로드로 모델에 넣을 방법이 없고, 파이썬 파서도 프로덕션에 쓸 만한 것이 없다.
업계 표준 경로는 하나다 — **ODA File Converter 로 DXF 변환 → ezdxf 로 파싱.**

오픈소스 LibreDWG 는 존재하지만 최신 DWG 버전 커버리지가 들쭉날쭉해 프로덕션 권고에 오르지 않는다.
조용히 일부 엔티티를 흘리는 실패가 가장 곤란하므로 기본 경로로 쓰지 않는다.

## 설치 (Linux)

1. https://www.opendesign.com/guestfiles/oda_file_converter 에서 배포판에 맞는 `.deb`/`.rpm` 을 받는다.
   (무료지만 이메일 등록이 필요하다. 자동 다운로드 URL 은 세션 토큰이 붙어 스크립트화되지 않는다.)
2. 설치 후 실행 파일 이름은 `ODAFileConverter` 다.

```bash
sudo apt-get install -y ./ODAFileConverter_QT6_lnxX64_8.3dll_25.*.deb
which ODAFileConverter            # PATH 에 잡히는지
```

`PATH` 에 없으면 스크립트에 위치를 알려 준다:

```bash
export ODAFC_PATH=/usr/bin/ODAFileConverter
```

## 헤드리스 박스에서의 함정 둘

**① GUI 를 띄우려 한다.** X 디스플레이가 없으면 실패하므로 가상 디스플레이로 감싼다.

```bash
sudo apt-get install -y xvfb
xvfb-run -a ODAFileConverter /tmp/in /tmp/out ACAD2018 DXF 0 1 도면.dwg
```

`cadread.py` 를 쓸 때도 같은 방식으로 전체를 감싸면 된다: `xvfb-run -a "$CAD" probe 도면.dwg`

**② 성공해도 종료코드가 0 이 아니다.** 리눅스판은 변환에 성공한 뒤에도 크래시하며 죽는다.
그래서 `cadread.py` 는 종료코드가 아니라 **출력 파일이 생겼는지**로 성공을 판정한다.
직접 호출할 때도 같은 기준을 쓴다 — 종료코드를 믿으면 멀쩡한 결과를 버리게 된다.

## 명령줄 규격

```
ODAFileConverter <입력폴더> <출력폴더> <버전> <타입> <재귀> <감사> [파일필터]
```

- 버전: `ACAD9` ~ `ACAD2018`
- 타입: `DWG` | `DXF` | `DXB`
- 재귀·감사: `0` | `1` (감사=1 이면 손상된 엔티티를 복구 시도)
- **폴더 단위로만 동작한다.** 파일 하나를 변환하려면 임시 폴더에 복사해 넣고 필터에 파일명을 준다.

## 안 되면

- 설계사무소에 **DXF 재수출**을 요청한다. 대개 5분이면 받는다.
- 그것도 안 되면 도면을 열 수 있는 사람에게 **PDF 출력**을 받는다 — 단 PDF 는 이 스킬 범위 밖이라
  (OCR/VLM 이 필요하다) 별도 도구를 논의해야 한다.

> 이 문서의 설치 절차는 **이 박스에서 실행해 검증하지 않았다** — ODA 배포판이 등록을 요구해
> 무인 설치가 불가능하다. 명령줄 규격과 종료코드 동작은 ezdxf 라이브러리의 odafc 애드온 구현을 읽어 대조했다.
