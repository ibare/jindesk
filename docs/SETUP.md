# 설치 (학생 맥과 폰)

관리자가 학생 맥과 폰에서 한 번 한다. 맥 앱의 다음 판은 자동 업데이트로 간다. 폰 앱은 관리자가 Xcode 로 다시 설치한다(8).

## 필요한 것

- macOS 26 이상(배포 대상 26.0). 학생 맥은 26.5.1 이다.
- Claude Code 2.1.295 이상. 외부 호출 검사 훅의 `"onFailure": "block"` 때문이다.
- 토큰을 낼 Claude 구독 계정.
- Keynote. PPT 를 PDF 로 바꾼다. 없으면 LibreOffice 를 쓴다.
- 자료에 따라 수 GB 의 디스크.
- git. 없으면 `xcode-select --install`로 Command Line Tools 를 넣는다.
- 데이터 리포를 둘 GitHub 계정. 비공개 리포 하나를 쓴다.
- 폰 앱을 설치할 관리자 맥의 Xcode 와 유료 개발자 계정.

## 1. Claude Code 설치

학생 맥의 터미널에서:

```sh
curl -fsSL https://claude.ai/install.sh | bash
claude --version
```

- 네이티브 설치는 claude 가 스스로 업데이트한다.
- 앱은 PATH 에 없어도 흔한 위치(`~/.local/bin/claude` 등)에서 claude 를 찾는다. 설정에서 경로를 직접 줄 수도 있다.
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

1. 앱 메뉴에서 "설정…"(⌘,)을 연다.
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

1. **데이터 리포를 연결한다.** 리포와 토큰을 만드는 법과 연결은 5 에 있다. 로컬 위치의 기본은 `~/Jindesk`다. iCloud 로 동기화되는 위치를 고르면 경고가 보인다(`DATA.md`).
2. **설정을 채운다.**
   - 모델, 상한, 사용량 미루기 기준. 기본값 그대로 둬도 된다.
3. **환경 점검.** claude 위치와 버전, 토큰이 키체인에 있는지, Keynote, 데이터 폴더, 캐시를 본다.
4. **학생이 자료를 넣기 시작한다.** 과목을 따로 등록하지 않는다. 자료를 넣을 때 학년·과목·수준 꼬리표를 붙이면 과목이 생긴다(`DECISIONS.md` 21).
5. **목차를 만든다.** 과목 가이드, 공개 과목 요약, 선생님의 과정·단원 안내를 받으면 자료 넣기에서 "목차의 근거"로 표시해 넣는다. 목차 만들기가 돌면 화면에서 목차를 확인한다.

## 5. 데이터 리포

데이터 폴더는 GitHub 비공개 리포의 클론이다(`DATA.md`의 데이터 리포). 리포와 토큰은 관리자가 만들고, 연결은 앱 설정에서 한다. 그 뒤의 커밋과 올리기는 앱이 한다.

1. **리포를 만든다.** 빈 비공개 리포다. 학생 맥이 쓸 실제 리포와 개발 맥이 쓸 시험 리포를 따로 둔다.

   ```sh
   gh repo create <주인>/jindesk-data --private
   gh repo create <주인>/jindesk-data-dev --private
   ```

2. **쓰기 토큰을 만든다.** GitHub 설정 → Developer settings → Fine-grained personal access tokens 에서 만든다.
   - Repository access: Only select repositories → 그 맥이 쓸 리포 하나
   - Permissions: Contents → Read and write (Metadata 는 저절로 읽기가 된다)
   - 만료는 관리자가 정한다. 만료되면 앱이 올리지 못한다고 알린다.
   - 학생 맥의 토큰은 실제 리포만, 개발 맥의 토큰은 시험 리포만 고른다.
3. **앱에서 연결한다.** 처음 켤 때의 화면이나 설정의 "데이터와 업데이트" 탭에서 한다.
   - 리포 주소, 토큰, 로컬 위치(기본 `~/Jindesk`)를 넣고 "연결"을 누른다.
   - 리포의 마지막 상태가 비어 있으면(파일을 모두 지운 리포, `README` 같은 리포 기본 파일만 있는 리포 포함) 앱이 데이터 폴더를 새로 만들어 커밋을 올린다. Jindesk 데이터가 있는 리포면 받아서 연다.
   - 데이터를 처음부터 다시 만들려면 리포의 파일을 모두 지우고 올린다. 다음에 켤 때 앱이 새 데이터 폴더를 만든다.
   - 리포를 바꿀 때도 같다. 새 리포와 새 로컬 위치를 넣고 연결한다. 이전 리포와 폴더는 그대로 남는다.
4. **확인.** 같은 탭에 연결한 리포, 마지막으로 올린 때와 커밋, 오류가 보인다. 환경 점검에도 "데이터 리포" 줄이 있다.

- 토큰은 키체인에만 있다. `.git/config`에도 백업 zip 에도 들어가지 않는다.
- 연결은 그 맥의 앱 설정에 있다. 다른 맥의 데이터 폴더나 백업을 열어도 그 폴더의 원격이 연결한 리포와 다르면 올리지 않는다.

## 6. 자료 버킷

원본 자료와 쪽 이미지는 리포가 아니라 GCS 버킷에 둔다(`DATA.md`의 자료 버킷, `DECISIONS.md` 31). 관리자의 개인 Google 계정 프로젝트에 만든다. 이 맥의 gcloud 가 다른 계정으로 잡혀 있을 수 있으므로, 명령마다 계정과 프로젝트를 준다.

버킷, 서비스 계정, 키를 개발 맥용과 학생 맥용으로 따로 만든다. 개발 맥의 키로 학생의 버킷에 닿지 않게 하려는 것이다. 아래는 하나를 만드는 순서이고, `<이름>`을 바꿔 두 번 한다(예: `jindesk-files`, `jindesk-files-dev`).

```sh
A=<관리자 개인 계정>
P=<GCP 프로젝트>
B=<이름>
gcloud storage buckets create gs://$B --account=$A --project=$P --location=me-central1 --uniform-bucket-level-access --public-access-prevention
# 맥이 쓰는 서비스 계정과 폰이 읽는 서비스 계정
gcloud iam service-accounts create $B-mac --account=$A --project=$P
gcloud iam service-accounts create $B-phone --account=$A --project=$P
gcloud storage buckets add-iam-policy-binding gs://$B --account=$A \
  --member=serviceAccount:$B-mac@$P.iam.gserviceaccount.com --role=roles/storage.objectAdmin
gcloud storage buckets add-iam-policy-binding gs://$B --account=$A \
  --member=serviceAccount:$B-phone@$P.iam.gserviceaccount.com --role=roles/storage.objectViewer
# HMAC 키. 비밀은 만들 때 한 번만 보인다
gcloud storage hmac create $B-mac@$P.iam.gserviceaccount.com --account=$A --project=$P
gcloud storage hmac create $B-phone@$P.iam.gserviceaccount.com --account=$A --project=$P
```

- 프로젝트에 결제 계정이 이어져 있어야 버킷을 만들 수 있다.
- 맥: 설정의 "데이터와 업데이트" 탭에서 버킷 이름과 맥용 키(접근 id, 비밀)를 넣는다. 키는 키체인에 들어간다. 넣으면 이미 넣은 자료의 원본과 쪽 이미지를 올린다.
- 폰: 설정에 같은 버킷 이름과 폰용 키를 넣는다(8).
- 키가 샜다고 의심되면 `gcloud storage hmac update <접근 id> --deactivate` 로 끊고 새로 만든다.
- 키를 만들 때 비밀을 화면에 내지 않고 관리자 맥의 키체인에 넣어 두면 옮기기 쉽다(서비스 `com.mintae.Jindesk.handoff`, 이름표 "Jindesk 자료 버킷 키 · 학생 맥" 등). 키체인 접근에서 꺼내 학생 맥과 폰의 설정에 넣는다.
- 실제 버킷으로 해 보는 시험(`FileBucketLiveTests`)은 개발 버킷의 키를 `TEST_RUNNER_JINDESK_GCS_LIVE_*` 환경 변수로 줄 때만 돈다. 끝나면 올린 시험 객체를 지운다.

## 7. 백업

- **만들기.** 파일 메뉴의 "백업 만들기"로 zip 을 만든다. 외장 디스크 같은 다른 곳에 둔다. 앱이 잠금을 잡고 만들어서, 작업 중이어도 어긋난 사본이 되지 않는다.
- **Time Machine.** 켜져 있으면 데이터 폴더가 함께 백업된다. 캐시는 빠진다.
- **되살리기.** 새 맥이나 다시 깐 앱에서 같은 리포를 연결하면 클론으로 되살아난다. zip 으로 되살릴 때는 풀어 둔 폴더를 로컬 위치로 두고 같은 리포를 연결한다. 필요하면 마이그레이션이 돌고, 색인은 다시 만든다.

## 8. 폰 앱

폰 앱은 데이터 리포를 받아 읽기만 한다(`MOBILE.md`). App Store 에 올리지 않고 관리자가 Xcode 로 설치한다.

1. **읽기 토큰을 만든다.** GitHub 설정 → Developer settings → Fine-grained personal access tokens.
   - Repository access: Only select repositories → `<주인>/jindesk-data`
   - Permissions: Contents → Read-only (Metadata 는 저절로 읽기가 된다)
   - 만료는 관리자가 정한다. 만료되면 폰 앱이 "받지 못했습니다 · 토큰"을 보인다.
2. **설치한다.** 관리자 맥에서:

   ```sh
   cd ios
   xcodegen generate
   open JindeskMobile.xcodeproj
   ```

   학생 폰을 이어 대상으로 고르고 실행한다. 처음에는 폰의 설정 → 개인정보 보호 및 보안 → 개발자 모드를 켜야 한다. 유료 개발자 계정의 개발 서명은 1년 동안 간다. 그 전에 다시 설치한다.
3. **차린다.** 폰 앱의 설정(톱니)에 리포 주인, 이름, 가지(`main`), 토큰, 자료 버킷 이름과 폰용 키(6)를 넣고 "지금 받기"를 누른다. 토큰과 키는 폰의 키체인에 들어간다.
4. **다시 설치할 때.** 맥 앱을 릴리즈할 때마다 폰 앱도 그 릴리즈의 `main` 커밋(태그 `v<판>`)으로 다시 설치한다(`UPDATES.md`의 릴리즈 절차 5). 폰 앱의 판과 빌드 번호는 맥 앱과 같고, 폰 앱 설정의 "앱"에서 본다. 스키마 버전이 오른 릴리즈라면, 다시 설치하기 전까지 폰 앱은 앱을 업데이트하라는 안내를 띄우고 마지막으로 받은 판을 보인다(`MIGRATION.md`).

## 9. 문제가 생기면

관리자가 학생 맥에서 직접 본다.
- 환경 점검: `/Applications/Jindesk.app/Contents/MacOS/Jindesk doctor`
- 코멘트와 기록은 데이터 폴더(데이터 리포에도 올라간다)에, 작업 공간과 이벤트 기록은 앱 지원 폴더의 `work/`에 있다(`DATA.md`).
- 데이터 리포에 올라가지 않으면: 설정의 오류를 보고, 데이터 폴더에서 `git status`, `git log origin/main..HEAD`로 남은 커밋을 본다. 인증 오류면 토큰을 다시 넣는다.
