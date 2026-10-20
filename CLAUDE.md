# Jindesk

IB 학생 한 명을 위한 Mac 학습 앱이다. 학교 자료를 격리된 headless Claude Code(`claude -p`)로 읽어 정리하고 학습 페이지로 펼친다. 데이터 폴더는 비공개 GitHub 리포로 올라가고, 폰 앱(`ios/`)이 받아 읽기만 한다. 설계는 `docs/`에 있고, `docs/README.md`부터 읽는다. 문서와 코드가 다르면 문서가 맞다(문서를 먼저 고친다).

이 파일은 **유지보수 세션용**이다. 작업은 앱(러너)이 격리된 에이전트로 실행하며, 작업 에이전트는 이 파일을 보지 않는다. 작업 에이전트가 따르는 지침은 작업 종류마다 `jobs/<종류>/INSTRUCTIONS.md` 하나뿐이다.

## 구조

```
docs/                       설계 문서. 결정은 DECISIONS.md 에 날짜와 함께 덧붙인다(지우지 않는다)
jobs/<종류>/INSTRUCTIONS.md 작업 지침. 빌드할 때 앱 번들에 들어간다. 바꾸면 위쪽의 "지침 버전"을 올린다
schemas/<스키마 버전>/       데이터 파일의 JSON Schema. 빌드할 때 앱 번들에 들어간다
renderer/                   학습 페이지 렌더러(page.html·js·css), 그림 블록의 공통 부품(parts/), KaTeX 0.16.22. 빌드할 때 맥과 폰 앱 번들에 들어간다
mac/
  project.yml               XcodeGen 정의 (Jindesk.xcodeproj 는 생성물이라 커밋하지 않는다)
  JindeskKit/               엔진. 화면 코드에 의존하지 않는다
    Agent/ Guard/ Process/  claude -p 실행, 판정(학생 독자 시험·격리 검증), 외부 호출 검사, 자식 프로세스 (Assayer 에서 옮겨 와 고친 것)
    Config/                 데이터 폴더, 앱 지원 폴더, 키체인
    Engine/                 작업 종류와 대기열, 작업 관리자, 설정, 지침, 사용량, 환경 점검
    Sources/                자료: 꼬리표, 자료 폴더(meta.yaml, labels.yaml), 자료 묶음(bundles/, 읽기와 정리의 단위), 자료 목록, 바꾸기, 쪽 나누기, 자료 넣기 작업
    Library/                엔트리, 개념(concept.yaml), 학습 페이지(page.yaml), 곁 층(layers.yaml), 용어 어휘, 목차, 개념 지도(선수 관계 그래프, 배치, 앞뒤 개념), 관점·레퍼런스, 옮기기(개념, 과목), 뜻 해시, 단원 개요(UnitDigest), IB command terms 정의, A–Z 묶기
    Learner/                코멘트(comments.jsonl), 요구(directives.jsonl)
    Index/                  SQLite 색인과 검색
    Checks/                 러너 검사: 한글·한자 섞임, 원래 자료가 있어야 통하는 말, 글 속 TeX, KaTeX 파싱, 풀이 계산(Expr)
    Jobs/                   에이전트 작업: 목차 만들기, 자료 읽기(묶음 하나), 개념 정리(묶음 하나, 보류된 엔트리 다시 받기), 학습 페이지 만들기, 번역, 관점 붙이기, 물어보기, 부분 다시 만들기, 남은 일(Pipeline)
    Pages/                  렌더러에 넘길 페이지 조합, 그림 블록 틀(FigureFrame), 바깥 라이브러리 사본(VendorStore)
    Migration/ Backup/      스키마 버전과 마이그레이션 실행기, 백업
    Sync/                   데이터 리포: 앱 설정의 리포 연결(클론, init), 커밋과 올리기, 뺄 파일 적기. 자료 버킷: 원본 자료와 쪽 이미지를 GCS 에 올리고 받기
    Util/                   YAML(DATA.md 의 쓰기 규칙), JSON, 파일(원자적 쓰기, JSONL), 해시
  JindeskGuard/             외부 호출 검사 훅 실행 파일 (앱 번들 Contents/MacOS/jindesk-guard)
  Jindesk/                  앱(화면, 학습 페이지 웹 보기, 그림 검사기(화면 밖 WKWebView), 메뉴 막대, Sparkle 업데이트, 명령줄 모드, 화면 찍기)
  JindeskKitTests/          엔진 시험 (Swift Testing)
  scripts/release.sh        릴리즈 (docs/UPDATES.md)
  scripts/make-icon.sh      앱 아이콘 그림(1024 PNG)을 크기별로 나눠 Jindesk/Assets.xcassets 와 폰 앱의 Assets.xcassets 에 넣는다
ios/
  project.yml               XcodeGen 정의 (JindeskMobile.xcodeproj 는 생성물). mac/JindeskKit 의 일부 파일을 함께 빌드한다
  JindeskMobile/            폰 앱: 데이터 리포 받기(GitHub API), 과목·개념 목록, 과목 개념 지도, 학습 페이지 웹 보기(읽기 전용), 출처의 쪽 이미지
  JindeskMobileTests/       받기 시험 (가짜 GitHub)
```

## 빌드와 시험

`mac/`에서:

```sh
xcodegen generate
xcodebuild -project Jindesk.xcodeproj -scheme Jindesk -configuration Debug -derivedDataPath build/dd build
xcodebuild -project Jindesk.xcodeproj -scheme Jindesk -configuration Debug -derivedDataPath build/dd test
```

- 명령줄 모드: `build/dd/Build/Products/Debug/Jindesk.app/Contents/MacOS/Jindesk doctor | intake --data <폴더> --subject … [--follow] <파일>… | continue --data <폴더> [--list] [--only <종류>] | rebuild-pages --data <폴더> [--unit <과목 id>/<단원 키>] [--list] [<개념 id>…] | recurate --data <폴더> (<개념 id>… \| --pending \| --apply <작업 id> \| --discard <작업 id>) | check-figure --vendor <폴더> <조각.html> | migrate --check <폴더나 zip> | backup --out <폴더> | version`. `--follow`, `continue`, `rebuild-pages`, `recurate`는 키체인의 토큰으로 실제 에이전트를 돌린다.
- 에이전트 작업의 흐름 시험(`PipelineRunTests`)은 가짜 claude(파이썬 스크립트)로 자료 넣기부터 번역까지 돌린다. 지침의 출력 모양을 바꾸면 가짜도 함께 고친다.
- 실제 학교 자료로 시험할 때는 임시 데이터 폴더(`--data`)에 넣고, 끝나면 `~/Library/Caches/com.mintae.Jindesk/pages/` 에 남은 쪽 이미지를 지운다. 학교 자료는 리포에 넣지 않는다. 시험 자료는 `SampleFiles`(JindeskKitTests)로 만든다.
- 화면 확인: `Jindesk.app/Contents/MacOS/Jindesk -snapshotDir <폴더> [-snapshotOnly <이름,…>]` (디버그 빌드). 과목 목록의 과목 단계는 `subjects-units`, 단원 단계는 `subjects-list-dark`다. 단원 개요는 `unit-overview`이고 `-snapshotUnitSection <summary|formulas|words|mistakes|references|ib>`로 그 절까지 내려 찍는다. 개념 다시 정리 후보의 대응표는 `recuration-review`, 묶음 보기는 `bundle`, 파일을 채운 자료 넣기는 `intake-groups`이고 `-snapshotIntakeFiles "<경로>,<경로>|<경로>"`(| 로 묶음을 나눈다)로 채운다. 실제 데이터 폴더와 앱 지원 폴더 대신 `<폴더>` 아래를 쓰고, 정해 둔 화면을 PNG 로 찍은 뒤 끝난다. 설정 창은 화면 밖에서 그려지지 않아 화면 위에서 잠깐 보였다 닫힌다.
- 디버그 빌드도 Developer ID 로 서명한다. 키체인의 토큰 항목에 대한 접근 허용이 서명에 묶이기 때문이다.
- 데이터 리포: `Jindesk sync`가 바로 커밋하고 올린다. 앱 설정에서 연결한 리포와 폴더만 올린다. 개발 맥은 시험 리포에 연결한다(학생의 실제 리포에 연결하지 않는다).

폰 앱은 `ios/`에서:

```sh
xcodegen generate
xcodebuild -project JindeskMobile.xcodeproj -scheme JindeskMobile -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd build
xcodebuild -project JindeskMobile.xcodeproj -scheme JindeskMobile -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd test
```

- 화면 확인(디버그 빌드): `-mirrorFrom <데이터 폴더>`로 띄우면 GitHub 대신 그 폴더를 받아 둔 사본으로 쓴다. 지어낸 데이터만 쓴다.

## 브랜치와 PR

- `main`은 릴리즈한 판, `develop`은 다음 판을 모으는 곳이다(기본 브랜치). 둘 다 PR 로만 넣는다. GitHub 규칙이 직접 올리기, 강제 푸시, 삭제를 막는다.
- 세션을 시작하면 `develop`을 받고(`git switch develop && git pull`) 거기서 `feature/<짧은-영어-이름>`을 딴다. 고치기도 같다.
- 열린 PR 을 고칠 때(리뷰를 반영할 때)는 새 브랜치나 새 PR 을 만들지 않고, 그 PR 의 브랜치를 받아(`gh pr checkout <번호>`) 이어서 커밋하고 올린다.
- 커밋을 올리고 `develop`으로 PR 을 연다(`gh pr create --base develop`). PR 설명은 한국어로, 무엇을 왜 바꿨는지와 시험 결과를 적는다.
- 리뷰는 관리자가 한다. 관리자가 머지하라고 하기 전에는 머지하지 않는다. 머지한 기능 브랜치는 지운다.
- 릴리즈는 먼저 `develop`에서 `mac/scripts/release.sh --dry-run`을 돌려 통과를 본다. 그다음 `develop` → `main` PR 을 머지 커밋으로 머지하고(스쿼시하지 않는다. 그래야 다음 릴리즈 PR 이 갈라지지 않는다), `main`에서 `mac/scripts/release.sh`로 낸다. 태그 `v<판>`은 그 `main` 커밋에 달린다(`docs/UPDATES.md`의 릴리즈 절차). 판 번호를 올리는 커밋도 기능 브랜치에서 PR 로 `develop`에 넣는다.

## 지킬 것

- 코드 주석, 커밋 메시지, 화면 글은 한국어로 쓴다. 학습 내용(학습 페이지의 글)만 영어다.
- 이 리포는 공개다. 학생의 자료, 기록, 이름, 학교 이름을 넣지 않는다. 시험 데이터도 지어낸 것만 쓴다.
- 0.1.1 로 출시했다(`docs/DECISIONS.md` 42). 데이터 스펙(파일과 필드의 추가, 삭제, 모양)을 바꾸면 무조건 `CurrentSchema.version`을 올리고, `schemas/<새 버전>/`, `MigrationPlan.steps`의 단계, 시험을 함께 더한다(`docs/MIGRATION.md`). 판을 올리면 폰 앱도 다시 설치해야 하니 관리자에게 알린다. 스펙은 그대로 두고 앱이 언제 무엇을 읽고 쓰는지만 바꾸면 판을 올리지 않는다.
- 데이터를 열 수 있는지는 스키마 버전으로만 정한다. 앱 판이나 빌드 번호로 막지 않는다. 열 때마다 맥마다 다른 값을 데이터 폴더에 고쳐 적지 않는다. 열기만 해도 커밋이 생겨 쓰는 맥과 기록이 갈라진다.
- 데이터 폴더의 YAML 은 `YAML.stringify`로만 쓰고 `FileOps.writeAtomic`으로 저장한다. JSONL 은 `FileOps.appendLine`으로 덧붙이기만 한다.
- 작업을 더하면 `JobKind.withInstructions`와 `jobs/<종류>/INSTRUCTIONS.md`를 함께 더한다.
- `ios/project.yml`이 함께 빌드하는 `mac/JindeskKit/` 파일을 고치면 iOS 빌드도 확인한다. 학습 페이지가 새 파일을 읽게 되면 폰 앱이 받는 경로(`MOBILE.md`의 표)도 고친다.
