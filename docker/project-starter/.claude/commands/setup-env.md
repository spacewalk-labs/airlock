환경변수 초기 설정을 가이드한다.

1. `.env.example` 파일 존재 여부 확인.
2. `.env.local` 파일이 없으면 `.env.example`을 복사하여 생성한다.
3. 사용자에게 어떤 환경변수가 필요한지 물어본다.
4. `.env.local`에 값을 채운다.
5. `.gitignore`에 `.env.local`이 포함되어 있는지 확인한다.
6. `.env.example`에 새 키가 추가되었으면 업데이트한다 (값은 비워둠).
