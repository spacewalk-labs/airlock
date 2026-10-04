# 옛 설치본을 최신으로 올리기

`airlock-update`는 지정한 배포본을 받아 운영자의 Git 이력과 편집을 유지하면서 파일을 갱신하고,
새 checkout의 `install/airlock-install.sh`를 인자 없이 실행합니다. 설치기의 종료 코드가 업데이트
결과입니다. 설치 실패를 고친 뒤 같은 명령으로 다시 실행할 수 있습니다.

```bash
bash bin/airlock-update --dry-run
bash bin/airlock-update
bash bin/airlock-update --dry-run --json
```

checkout에 업데이터가 없으면 최신 공개 스크립트를 실행합니다.

```bash
curl -fsSL https://raw.githubusercontent.com/spacewalk-labs/airlock/main/bin/airlock-update | bash
```

다른 checkout이나 특정 배포본은 환경변수로 지정합니다.

```bash
AIRLOCK_DIR=/path/to/airlock AIRLOCK_RELEASE_REF=main bash bin/airlock-update
```

`AIRLOCK_RELEASE_URL`로 배포 저장소를 바꿀 수 있습니다. `--no-install`은 파일만 갱신합니다.
macOS의 `--machine NAME`은 OrbStack 설치 대상 이름을 전달합니다.

배포 파일과 충돌하는 운영자 편집은 갱신 직후에도 실제 작업 파일에 남습니다. 커밋된 편집,
스테이징과 작업 파일의 서로 다른 내용, 삭제, 링크, 배포 파일과 이름이 겹치는 미추적 파일을
보존합니다. 운영자가 추가한 파일과 `airlock.toml`도 유지합니다. Git 이력이 없는 설치본에서는
기존 파일의 원래 내용과 편집을 구별할 수 없어 충돌하는 기존 파일을 그대로 유지합니다.

이전 업데이트 커밋에 기록된 배포본에서 사라진 소스는 제거합니다. 해당 소스의 운영자 편집은
작업 파일로 유지하며, 출처를 기록한 이전 업데이트가 없는 파일은 지우지 않습니다. 미리보기는
파일과 원본 Git 메타데이터를 변경하지 않고 현재 바이트와 선택한 배포본의 차이를 보여 줍니다.
배포 시점의 앞뒤를 추정하지 않습니다.

업데이트가 끝나면 실제 앱과 상태를 확인합니다.

```bash
python3 bin/airlock-status
```

업데이터는 박스 상태의 복구 스냅샷을 만들지 않습니다. 박스 전체를 되돌려야 할 작업은 운영자가
보유한 VM·컨테이너 백업으로 복원합니다. checkout 변경 이력은 운영자의 Git 저장소에 남습니다.
