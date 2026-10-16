# 설치 (학생 맥)

관리자가 학생 맥에서 한 번 한다. 그 뒤의 판은 자동 업데이트로 간다.

## 필요한 것

- 배포 대상 이상의 macOS. 버전은 정하지 않았다(`DECISIONS.md`).
- Claude Code 2.1.295 이상. 외부 호출 검사 훅의 `"onFailure": "block"` 때문이다.
- 토큰을 낼 Claude 구독 계정.
- Keynote. PPT 를 PDF 로 바꾼다. 없으면 LibreOffice 를 쓴다.
- 자료에 따라 수 GB 의 디스크.

## 1. Claude Code 설치

학생 맥의 터미널에서:

```sh
curl -fsSL https://claude.ai/install.sh | bash
claude --version
```

- 네이티브 설치는 claude 가 스스로 업데이트한다.
- 앱은 PATH 에 없어도 흔한 위치(`~/.local/bin/claude` 등)에서 claude 를 찾는다. 관리자 설정에서 경로를 직접 줄 수도 있다.
- 학생 맥에서 claude 에 로그인할 필요는 없다. 앱은 키체인의 토큰만 쓴다.

## 2. Jindesk 설치

1. `https://github.com/ibare/jindesk/releases/latest`에서 `Jindesk-<판>.zip`을 받아 푼다.
2. `Jindesk.app`을 `/Applications`로 옮긴다. 공증된 앱이라 바로 열린다.
3. 그 뒤로는 앱이 스스로 업데이트한다(`UPDATES.md`).

다음 단계에서 터미널로 토큰을 넣으면서 `-T`를 쓰려면, 앱이 먼저 `/Applications`에 있어야 한다.

## 3. Claude 토큰을 키체인에 넣기

토큰은 로그인 키체인의 일반 암호 항목 하나에 둔다. 앱이 찾는 이름은 정해져 있으니 바꾸지 않는다.

| | 값 |
|---|---|
| 서비스 (`-s`) | `com.mintae.Jindesk` |
| 계정 (`-a`) | `claude-oauth-token` |
| 이름표 (`-l`) | `Jindesk Claude 토큰` (아무것이나 된다) |

### 토큰 만들기

토큰을 낼 계정으로, 아무 맥의 터미널에서:

```sh
claude setup-token
```

- 브라우저에서 그 계정으로 인증하면 긴 수명의 OAuth 토큰이 터미널에 한 번 보인다. 보통 `sk-ant-oat01-`로 시작한다.
- 이 토큰은 그 계정의 구독 사용량을 쓴다.
- 파일이나 메모에 남기지 말고 바로 다음 단계로 넣는다.

### 넣기: 방법 1 — 앱에서

1. 메뉴에서 ⌥ 키를 누른 채 "관리자 설정…"을 연다. 학생 화면에서는 감춰져 있다.
2. "Claude 토큰"에 붙여 넣고 저장한다. 앱이 키체인에 넣는다.

앱이 만든 항목이라 앱이 읽을 때 승인 창이 뜨지 않는다.

### 넣기: 방법 2 — 터미널에서

학생 맥에서, 학생이 쓰는 사용자 계정으로 로그인한 터미널에서:

```sh
security add-generic-password -U \
  -s com.mintae.Jindesk \
  -a claude-oauth-token \
  -l "Jindesk Claude 토큰" \
  -T /Applications/Jindesk.app \
  -w
```

- **`-w`를 맨 끝에 값 없이 둔다.** 그러면 토큰을 입력으로 묻는다(확인까지 두 번). 토큰이 셸 기록에 남지 않는다.
- **`-U`** 는 같은 항목이 있으면 바꾼다.
- **`-T /Applications/Jindesk.app`** 는 Jindesk 가 승인 창 없이 읽도록 허용한다.
  - 같은 Developer ID 와 번들 id 로 서명한 새 판도 그대로 읽는다.
  - `-T` 없이 넣었으면 앱이 처음 읽을 때 "Jindesk이(가) 키체인의 기밀 정보를 사용하려고 합니다" 창이 뜬다. 그 사용자 계정의 암호를 넣고 "항상 허용"을 누른다.

### 확인

```sh
security find-generic-password -s com.mintae.Jindesk -a claude-oauth-token
```

- 항목의 속성만 보이고 값은 보이지 않는다. `-w`나 `-g`를 붙이면 값이 보이므로 붙이지 않는다.
- 앱의 환경 점검(화면의 "환경 점검" 또는 명령줄의 `doctor`)은 "토큰: 키체인"만 보이고 값은 읽지 않는다.

### 바꾸기와 지우기

- **바꾸기.** 새 토큰을 만들어 방법 1 이나 2 를 다시 한다. 방법 2 는 `-U`가 덮어쓴다.
- **지우기.**

  ```sh
  security delete-generic-password -s com.mintae.Jindesk -a claude-oauth-token
  ```

- 토큰이 샜다고 의심되면 새 토큰으로 바꾸고, 계정 쪽에서 이전 토큰을 끊을 수 있으면 끊는다.

### 앱이 토큰을 다루는 방식

- 작업을 띄울 때 자식 프로세스에만 `CLAUDE_CODE_OAUTH_TOKEN`으로 넘긴다. 자식 환경의 다른 `CLAUDE*`, `ANTHROPIC*` 변수는 지운다.
- 화면, 로그, 기록, 백업에 남지 않는다. `.env`는 쓰지 않는다.
- 학생 사용자 계정의 로그인 키체인에 있으므로, 그 계정 암호를 아는 사람은 키체인 접근으로 꺼낼 수 있다.

## 4. 처음 켜기

1. **데이터 폴더를 고른다.** 기본은 `~/Jindesk`다. iCloud 로 동기화되는 폴더를 고르면 경고가 보인다(`DATA.md`).
2. **관리자 설정을 채운다.**
   - 웹 금지어: 학생 이름, 학교 이름, 선생님 이름. `meta/privacy.yaml`에 들어가고 밖으로 나가지 않는다.
   - 모델, 상한, 사용량 미루기 기준. 기본값 그대로 둬도 된다.
3. **환경 점검.** claude 위치와 버전, 토큰이 키체인에 있는지, Keynote, 데이터 폴더, 캐시를 본다.
4. **과목을 넣는다.** DP 과목과 SL/HL, MYP 10 과목이 `meta/subjects.yaml`에 들어간다.
5. **목차를 만든다.**
   1. 과목마다 근거 문서(과목 가이드, 공개 과목 요약, 선생님의 과정 안내)를 자료 넣기에서 "목차의 근거"로 표시해 넣는다.
   2. 목차 만들기가 돌면 관리자가 화면에서 목차를 확인한다.
6. 학생이 자료를 넣기 시작한다.

## 5. 백업

- **만들기.** 파일 메뉴의 "백업 만들기"로 zip 을 만든다. 외장 디스크 같은 다른 곳에 둔다. 앱이 잠금을 잡고 만들어서, 작업 중이어도 어긋난 사본이 되지 않는다.
- **Time Machine.** 켜져 있으면 데이터 폴더가 함께 백업된다. 캐시는 빠진다.
- **되살리기.** zip 을 풀고, 그 폴더를 데이터 폴더로 고른다. 필요하면 마이그레이션이 돌고, 색인은 다시 만든다.

## 6. 문제가 생기면

관리자가 학생 맥에서 직접 본다.
- 환경 점검: `/Applications/Jindesk.app/Contents/MacOS/Jindesk doctor`
- 코멘트와 기록은 데이터 폴더에, 작업 공간과 이벤트 기록은 앱 지원 폴더의 `work/`에 있다(`DATA.md`).
