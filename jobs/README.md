# 작업 지침

작업 종류마다 `<종류>/INSTRUCTIONS.md` 하나가 그 작업 에이전트의 지침이다(`../docs/JOBS.md`). 러너가 시스템 프롬프트로 넣는다.

- 빌드할 때 앱 번들(`Contents/Resources/jobs`)에 들어간다. 그때 지침마다 마지막으로 바꾼 커밋과 미커밋 변경 여부가 `build.json`에 남는다(`../mac/project.yml`의 "작업 지침과 스키마 넣기").
- 파일 위쪽에 `지침 버전: \`0.1\`` 줄을 둔다. 내용을 바꾸면 이 값을 올리고 릴리즈 노트에 적는다.
- 지침이 있어야 하는 종류는 `JobKind.withInstructions`에 더한다. 환경 점검이 앱 번들에 지침이 있는지 본다.

0단계에는 지침이 없다. 1단계에서 `syllabus-build`, `source-reading`, `concept-curation`, `page-build`, `translation`부터 더한다.
