# 자동 업데이트와 릴리즈

관리자가 새 판을 만들어 이 리포(`ibare/jindesk`, 공개)의 GitHub Releases 에 올린다. 학생 맥의 앱은 그것을 찾아 스스로 업데이트한다. 학생이 할 일은 없다.

## 구성

- **Sparkle 2** (Swift Package)를 쓴다. 패키지는 `exactVersion`으로 고정한다(구현할 때의 최신 안정판).
- **피드 주소.** `https://github.com/ibare/jindesk/releases/latest/download/appcast.xml`이다. 최신 릴리즈의 `appcast.xml` 첨부 파일로 가는 고정 주소다. 릴리즈마다 `appcast.xml`을 함께 올린다.
- **업데이트 파일 서명.** 업데이트 파일(`Jindesk-<판>.zip`)은 Sparkle 의 EdDSA 키로 서명한다. 공개 키는 `Info.plist`의 `SUPublicEDKey`에 둔다. 비밀 키는 관리자 맥의 키체인에만 있다(Sparkle 의 `generate_keys`가 만든다). 리포나 릴리즈가 바꿔치기돼도 서명이 맞지 않으면 설치하지 않는다.
- **앱 서명.** Developer ID Application 인증서(팀 `5NK357FRB5`)로 서명하고 hardened runtime 을 켠다.
  - 번들 안의 실행 파일(`jindesk-guard`)과 Sparkle 의 도우미도 같은 인증서와 `--timestamp`로 서명한다.
  - 공증(`notarytool`)을 받고 스테이플한다. 다른 맥에서 내려받은 앱이 Gatekeeper 에 막히지 않게 하려는 것이다.
  - Assayer 는 Apple Development 서명이라 그 맥에서만 쓴다. Jindesk 는 처음부터 Developer ID 로 간다.
- **번들 id 와 팀 id 를 바꾸지 않는다.** `com.mintae.Jindesk`, `5NK357FRB5`. 키체인 항목의 접근 허용은 서명의 지정 요구사항에 묶인다. 같은 Developer ID 로 서명한 새 판은 승인 창 없이 토큰을 읽는다.
- **판 번호.** `MARKETING_VERSION`은 사람이 읽는 판(0.4.0)이다. `CURRENT_PROJECT_VERSION`은 릴리즈마다 1씩 오르는 빌드 번호다. Sparkle 은 빌드 번호(`CFBundleVersion`)로 새것을 가린다.

`Info.plist` 값:

| 키 | 값 |
|---|---|
| `SUFeedURL` | `https://github.com/ibare/jindesk/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | 관리자의 EdDSA 공개 키 |
| `SUEnableAutomaticChecks` | `YES` |
| `SUAutomaticallyUpdate` | `YES` (내려받기와 설치를 묻지 않는다) |
| `SUScheduledCheckInterval` | `21600` (6시간) |

## 앱의 업데이트 규칙

- 켤 때와 6시간마다 확인하고, 새 판이 있으면 뒤에서 내려받는다.
- **작업이 돌고 있으면 설치하지 않는다.** Sparkle 위임(`SPUUpdaterDelegate`)에서 설치·다시 켜기를 미루고, 돌던 작업과 시작하려던 작업이 모두 끝나면 이어서 설치한다. 훅 실행 파일이 번들 안에 있어서, 작업 중에 번들이 바뀌면 훅이 뜨지 못하고 웹 호출이 막힌다. Assayer 와 같은 까닭이다.
- 미루는 동안 새 작업은 시작하지 않는다. 앱 창에는 "업데이트 대기 중 · 지금 작업이 끝나면 설치"가 보인다.
- **다시 켜면 이 차례를 따른다.**
  1. 환경 점검: claude 위치와 최소 버전, 토큰이 키체인에 있는지
  2. 스키마 확인과 마이그레이션 (`MIGRATION.md`)
  3. 색인 갱신
  4. 대기열 열기
  - 마이그레이션이 필요하면 다시 켜기 전에 "업데이트 후 데이터를 새 모양으로 바꾼다 · 그 전에 자동 백업"을 알린다.
- **claude CLI 는 앱이 올려 주지 않는다.** 새 판이 더 높은 claude 버전을 요구하면 작업을 시작하지 않고 `claude update`를 안내한다. 네이티브 설치는 claude 가 스스로 업데이트한다.
- **되돌리기.** 이전 판 앱은 릴리즈 페이지에서 받을 수 있다. 이전 판 앱은 자기보다 새 스키마의 데이터 폴더를 열지 않고 알린다. 되돌리려면 마이그레이션 전 자동 백업으로 데이터도 함께 되돌린다.

## 릴리즈 절차 (`mac/scripts/release.sh`)

관리자 맥에서 돈다. 실행 중인 Jindesk 작업과 상관없다(학생 맥이 아니다).

브랜치는 `CLAUDE.md`의 브랜치와 PR 을 따른다.

1. 판 번호(`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`)를 올리는 PR 을 `develop`에 넣는다.
2. `develop`에서 `release.sh --dry-run`(스키마가 바뀌었으면 `--check-backup`도)을 돌린다. 지난 릴리즈, 빌드 번호, 스키마와 마이그레이션, 시험, 빌드와 서명 확인이 모두 여기서 돈다(git 확인만 건너뛴다). 그래서 실패를 `main`에 넣기 전에 잡는다. 실패한 채 `main`에 넣으면 `main`에 릴리즈되지 않은 커밋이 남는다.
3. `develop` → `main` PR 을 머지 커밋으로 머지한다.
4. `main`을 받아 그 커밋에서 스크립트를 돌린다.

```sh
mac/scripts/release.sh --notes <릴리즈 노트.md> [--check-backup <학생 백업 폴더나 zip>]
mac/scripts/release.sh --dry-run    # 빌드와 서명 확인까지만
```

**처음 한 번 해 둘 것.**
- 공증 자격 증명을 키체인 프로필로 둔다: `xcrun notarytool store-credentials jindesk-notary --apple-id <Apple ID> --team-id 5NK357FRB5`. 다른 이름이면 `NOTARY_PROFILE`에 넣는다.
- Sparkle EdDSA 키를 만든다: Swift 패키지의 `artifacts/sparkle/Sparkle/bin/generate_keys --account com.mintae.Jindesk`. 출력된 공개 키를 `mac/project.yml`의 `SPARKLE_PUBLIC_KEY`에 넣는다. 비밀 키를 잃으면 설치된 앱에 업데이트를 보낼 수 없으므로 `generate_keys --account com.mintae.Jindesk -x <파일>`로 내보내 따로 보관한다.

1. **확인.**
   - 작업 지침과 코드가 모두 커밋됐다(`jobs/build.json`의 `dirty`가 없다).
   - 시험이 통과한다.
   - `MARKETING_VERSION`을 올렸고, 빌드 번호는 지난 릴리즈보다 크다.
   - 스키마를 바꿨으면 `schemas/<새 버전>/`과 마이그레이션이 있다.
   - 학생 백업 사본으로 `jindesk migrate --check`가 통과했다(`MIGRATION.md`). 지난 릴리즈보다 스키마가 바뀌었으면 `--check-backup` 없이는 멈춘다.
   - `main`에서 낸다. 로컬 `main`이 원격 `main`과 같은 커밋이다. 릴리즈 태그가 그 커밋을 가리킨다.
2. **빌드.** `xcodegen generate` 후 `xcodebuild archive`와 Developer ID 내보내기를 한다.
3. **공증.** `ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl`로 압축하고 `xcrun notarytool submit … --keychain-profile <프로필> --wait`, `xcrun stapler staple Jindesk.app`을 한다. 스테이플한 앱을 같은 방법으로 다시 압축해 `Jindesk-<판>.zip`을 만든다. 그 zip 을 `unzip`으로 풀어 Gatekeeper 를 통과하는지 다시 본다.
   - zip 에 확장 속성(macOS 가 붙이는 `com.apple.provenance` 등)을 담지 않는다. 담으면 번들 안에 `._` 파일로 들어가, 압축 해제 앱이 아닌 도구로 풀 때 그 파일이 번들에 생겨 서명이 깨진다. 그러면 받는 맥이 "Apple could not verify"로 막는다(0.1.0 에서 겪었다).
4. **Sparkle 서명.** `sign_update Jindesk-<판>.zip`으로 EdDSA 서명과 길이를 얻는다.
5. **appcast.** `appcast.xml`에 이번 판 항목 하나를 쓴다. 피드 주소가 늘 최신 릴리즈의 `appcast.xml`을 가리키므로 지난 판 항목은 넣지 않는다. 담는 것은 다음과 같다.
   - `sparkle:version`(빌드 번호), `sparkle:shortVersionString`
   - `sparkle:minimumSystemVersion`
   - 내려받기 주소: 그 릴리즈의 zip 첨부 주소 `https://github.com/ibare/jindesk/releases/download/v<판>/Jindesk-<판>.zip`
   - `sparkle:edSignature`, `length`
   - 릴리즈 노트
6. **릴리즈.** `gh release create v<판> Jindesk-<판>.zip appcast.xml --target <main 커밋> --notes-file <노트>`. 이 단계에서만 관리자 계정의 `gh`를 쓴다.

**릴리즈 노트에 적는 것.** 바뀐 것, 스키마 버전(바뀌었으면 마이그레이션 종류), 바뀐 작업 지침과 그 버전, 필요한 claude 최소 버전. 바뀐 지침 때문에 낡은 것이 되는 단위가 있으면 그것도 적는다. 이것들은 업데이트 뒤 천천히 다시 만들어진다.

## 비밀과 공개

- 이 리포는 공개다. EdDSA 비밀 키, 공증 자격 증명(`notarytool` 키체인 프로필), Claude 토큰은 리포에 넣지 않는다.
- 릴리즈에는 앱만 들어간다. 학생의 자료와 기록은 들어가지 않는다.
- 비공개 리포였다면 앱이 내려받으려고 GitHub 토큰을 들고 있어야 했다. 공개 리포라 그럴 필요가 없다.
