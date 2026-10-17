# Jindesk

IB 학생 한 명을 위한 Mac 학습 앱이다. 학교 자료를 격리된 headless Claude Code(`claude -p`)로 읽어 정리하고 학습 페이지로 펼친다. 설계는 `docs/`에 있고, `docs/README.md`부터 읽는다. 문서와 코드가 다르면 문서가 맞다(문서를 먼저 고친다).

이 파일은 **유지보수 세션용**이다. 작업은 앱(러너)이 격리된 에이전트로 실행하며, 작업 에이전트는 이 파일을 보지 않는다. 작업 에이전트가 따르는 지침은 작업 종류마다 `jobs/<종류>/INSTRUCTIONS.md` 하나뿐이다.

## 구조

```
docs/                       설계 문서. 결정은 DECISIONS.md 에 날짜와 함께 덧붙인다(지우지 않는다)
jobs/<종류>/INSTRUCTIONS.md 작업 지침. 빌드할 때 앱 번들에 들어간다. 바꾸면 위쪽의 "지침 버전"을 올린다
schemas/<스키마 버전>/       데이터 파일의 JSON Schema. 빌드할 때 앱 번들에 들어간다
renderer/                   학습 페이지 렌더러(page.html·js·css)와 KaTeX 0.16.22. 빌드할 때 앱 번들에 들어간다
mac/
  project.yml               XcodeGen 정의 (Jindesk.xcodeproj 는 생성물이라 커밋하지 않는다)
  JindeskKit/               엔진. 화면 코드에 의존하지 않는다
    Agent/ Guard/ Process/  claude -p 실행, 외부 호출 검사, 자식 프로세스 (Assayer 에서 옮겨 와 고친 것)
    Config/                 데이터 폴더, 앱 지원 폴더, 키체인, 웹 금지어
    Engine/                 작업 종류와 대기열, 작업 관리자, 설정, 지침, 사용량, 환경 점검
    Sources/                자료: 꼬리표, 자료 폴더(meta.yaml, labels.yaml), 자료 목록, 바꾸기, 쪽 나누기, 자료 넣기 작업
    Library/                엔트리, 개념(concept.yaml), 학습 페이지(page.yaml), 곁 층(layers.yaml), 용어 어휘, 목차, 뜻 해시
    Checks/                 러너 검사: 한글·한자 섞임, 금지어, 원래 자료가 있어야 통하는 말, 글 속 TeX, KaTeX 파싱
    Jobs/                   에이전트 작업: 자료 읽기, 개념 정리, 학습 페이지 만들기, 번역, 남은 일(Pipeline)
    Pages/                  렌더러에 넘길 페이지 조합
    Migration/ Backup/      스키마 버전과 마이그레이션 실행기, 백업
    Util/                   YAML(DATA.md 의 쓰기 규칙), JSON, 파일(원자적 쓰기, JSONL), 해시
  JindeskGuard/             외부 호출 검사 훅 실행 파일 (앱 번들 Contents/MacOS/jindesk-guard)
  Jindesk/                  앱(화면, 메뉴 막대, Sparkle 업데이트, 명령줄 모드, 화면 찍기)
  JindeskKitTests/          엔진 시험 (Swift Testing)
  scripts/release.sh        릴리즈 (docs/UPDATES.md)
```

## 빌드와 시험

`mac/`에서:

```sh
xcodegen generate
xcodebuild -project Jindesk.xcodeproj -scheme Jindesk -configuration Debug -derivedDataPath build/dd build
xcodebuild -project Jindesk.xcodeproj -scheme Jindesk -configuration Debug -derivedDataPath build/dd test
```

- 명령줄 모드: `build/dd/Build/Products/Debug/Jindesk.app/Contents/MacOS/Jindesk doctor | intake --data <폴더> --subject … [--follow] <파일>… | continue --data <폴더> [--list] [--only <종류>] | migrate --check <폴더나 zip> | backup --out <폴더> | version`. `--follow`와 `continue`는 키체인의 토큰으로 실제 에이전트를 돌린다.
- 에이전트 작업의 흐름 시험(`PipelineRunTests`)은 가짜 claude(파이썬 스크립트)로 자료 넣기부터 번역까지 돌린다. 지침의 출력 모양을 바꾸면 가짜도 함께 고친다.
- 실제 학교 자료로 시험할 때는 임시 데이터 폴더(`--data`)에 넣고, 끝나면 `~/Library/Caches/com.mintae.Jindesk/pages/` 에 남은 쪽 이미지를 지운다. 학교 자료는 리포에 넣지 않는다. 시험 자료는 `SampleFiles`(JindeskKitTests)로 만든다.
- 화면 확인: `Jindesk.app/Contents/MacOS/Jindesk -snapshotDir <폴더> [-snapshotOnly <이름,…>]` (디버그 빌드). 실제 데이터 폴더와 앱 지원 폴더 대신 `<폴더>` 아래를 쓰고, 정해 둔 화면을 PNG 로 찍은 뒤 끝난다. 관리자 설정 창은 화면 밖에서 그려지지 않아 화면 위에서 잠깐 보였다 닫힌다.
- 디버그 빌드도 Developer ID 로 서명한다. 키체인의 토큰 항목에 대한 접근 허용이 서명에 묶이기 때문이다.

## 지킬 것

- 코드 주석, 커밋 메시지, 화면 글은 한국어로 쓴다. 학습 내용(학습 페이지의 글)만 영어다.
- 이 리포는 공개다. 학생의 자료, 기록, 이름, 학교 이름을 넣지 않는다. 시험 데이터도 지어낸 것만 쓴다.
- 데이터 모양을 바꾸면 `CurrentSchema.version`을 올리고, `schemas/<새 버전>/`, `MigrationPlan.steps`의 단계, 시험을 함께 더한다(`docs/MIGRATION.md`).
- 데이터 폴더의 YAML 은 `YAML.stringify`로만 쓰고 `FileOps.writeAtomic`으로 저장한다. JSONL 은 `FileOps.appendLine`으로 덧붙이기만 한다.
- 작업을 더하면 `JobKind.withInstructions`와 `jobs/<종류>/INSTRUCTIONS.md`를 함께 더한다.
