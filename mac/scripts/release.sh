#!/bin/zsh
# Jindesk 릴리즈 (UPDATES.md 의 릴리즈 절차). 관리자 맥에서 돈다.
#   확인 → 시험 → 빌드(Developer ID) → 공증과 스테이플 → Sparkle 서명 → appcast → GitHub 릴리즈
#
# 사용: mac/scripts/release.sh --notes <릴리즈 노트.md> [--check-backup <학생 백업 폴더나 zip>] [--dry-run]
#   --dry-run       빌드와 서명 확인까지만 한다. 공증, Sparkle 서명, 릴리즈 올리기는 하지 않는다.
#   --check-backup  학생의 실제 백업 사본으로 이번 판의 마이그레이션을 시험한다 (스키마가 바뀌었으면 꼭 필요하다).
#
# 미리 해 둘 것 (한 번):
#   1. 공증 자격 증명: xcrun notarytool store-credentials jindesk-notary --apple-id <id> --team-id 5NK357FRB5
#      (다른 이름을 쓰면 NOTARY_PROFILE 에 넣는다)
#   2. Sparkle EdDSA 키: <SourcePackages>/artifacts/sparkle/Sparkle/bin/generate_keys --account com.mintae.Jindesk
#      출력된 공개 키를 project.yml 의 SPARKLE_PUBLIC_KEY 에 넣는다. 비밀 키는 키체인에만 있다.
#      키를 잃으면 이미 설치된 앱에 업데이트를 보낼 수 없으므로 generate_keys -x 로 내보내 따로 보관한다.
#
# 릴리즈 노트에 적을 것: 바뀐 것, 스키마 버전(바뀌었으면 마이그레이션 종류), 바뀐 작업 지침과 그 버전,
# 필요한 claude 최소 버전. 바뀐 지침은 이미 있는 단위를 낡게 하지 않는다 (DECISIONS.md 45).
set -euo pipefail

here=${0:A:h}
mac=${here:h}
repo=${mac:h}
slug=ibare/jindesk
profile=${NOTARY_PROFILE:-jindesk-notary}
account=${SPARKLE_ACCOUNT:-com.mintae.Jindesk}
team=5NK357FRB5

notes=""
backup=""
dry=0
while (( $# )); do
  case $1 in
    --notes) notes=${2:A}; shift 2 ;;
    --check-backup) backup=${2:A}; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) print -u2 "모르는 인자: $1"; exit 2 ;;
  esac
done

fail() { print -u2 "✗ $*"; exit 1 }
step() { print "▸ $*" }

cd $mac
version=$(awk -F': *' '/^ *MARKETING_VERSION:/{print $2; exit}' project.yml)
build=$(awk -F': *' '/^ *CURRENT_PROJECT_VERSION:/{print $2; exit}' project.yml)
pubkey=$(awk -F': *' '/^ *SPARKLE_PUBLIC_KEY:/{gsub(/"/, "", $2); print $2; exit}' project.yml)
schema_of() { grep -E 'static let version = [0-9]+' | grep -oE '[0-9]+' | head -1 }
schema=$(schema_of < JindeskKit/Migration/SchemaFile.swift)
tag=v$version
out=$mac/release/$version

# 1. 확인
step "확인: Jindesk $version (빌드 $build, 스키마 $schema)"
(( dry )) || [[ -n $notes && -f $notes ]] || fail "--notes <릴리즈 노트 파일> 이 필요합니다"
if [[ -z $pubkey ]]; then
  (( dry )) && print "  ! SPARKLE_PUBLIC_KEY 가 비어 있습니다 (dry-run 이라 넘어갑니다)" || fail "project.yml 의 SPARKLE_PUBLIC_KEY 가 비어 있습니다 (이 파일 위의 '미리 해 둘 것' 2)"
fi
[[ -d $repo/schemas/$schema ]] || fail "schemas/$schema/ 가 없습니다"
if (( ! dry )); then
  [[ -z $(git -C $repo status --porcelain) ]] || fail "커밋하지 않은 변경이 있습니다. 지침과 코드를 모두 커밋한 뒤 릴리즈합니다"
  # 릴리즈는 main 에서, 원격 main 과 같은 커밋에서 낸다 (CLAUDE.md 의 브랜치와 PR)
  branch=$(git -C $repo branch --show-current)
  [[ $branch == main ]] || fail "릴리즈는 main 에서 냅니다 (지금 $branch). develop → main PR 을 머지한 뒤 main 으로 옮겨 냅니다"
  git -C $repo fetch -q origin main
  head=$(git -C $repo rev-parse HEAD)
  [[ $head == $(git -C $repo rev-parse origin/main) ]] || fail "로컬 main($head)이 원격 main 과 다릅니다. 받거나 PR 로 넣은 뒤 릴리즈합니다"
fi
if gh release view $tag -R $slug >/dev/null 2>&1; then fail "$tag 릴리즈가 이미 있습니다. MARKETING_VERSION 을 올리세요"; fi
last_tag=$(gh release view -R $slug --json tagName -q .tagName 2>/dev/null || true)
# 릴리즈 태그는 GitHub 에서 만들어지므로, 지난 판의 스키마를 읽기 전에 받아 온다
[[ -n $last_tag ]] && git -C $repo fetch -q origin "refs/tags/${last_tag}:refs/tags/${last_tag}"
if [[ -n $last_tag ]]; then
  last_build=$(curl -fsSL https://github.com/$slug/releases/download/$last_tag/appcast.xml | grep -oE '<sparkle:version>[0-9]+' | grep -oE '[0-9]+' | head -1)
  (( build > last_build )) || fail "빌드 번호 $build 가 지난 릴리즈($last_tag 의 $last_build)보다 커야 합니다 (CURRENT_PROJECT_VERSION)"
  last_schema=$(git -C $repo show $last_tag:mac/JindeskKit/Migration/SchemaFile.swift | schema_of)
  if (( schema != last_schema )) && [[ -z $backup ]]; then
    fail "스키마가 $last_schema → $schema 로 바뀌었습니다. --check-backup <학생 백업> 으로 마이그레이션을 시험해야 합니다"
  fi
  print "  지난 릴리즈: $last_tag (빌드 $last_build, 스키마 $last_schema)"
else
  print "  첫 릴리즈입니다"
fi

# 2. 시험
step "시험"
xcodegen generate --quiet
xcodebuild -project Jindesk.xcodeproj -scheme Jindesk -configuration Debug -derivedDataPath build/dd test -quiet >$mac/build/release-test.log 2>&1 \
  || { tail -30 $mac/build/release-test.log; fail "시험이 실패했습니다 (build/release-test.log)"; }

# 3. 빌드
step "빌드: Release archive, Developer ID 로 내보내기"
rm -rf $out
mkdir -p $out
xcodebuild -project Jindesk.xcodeproj -scheme Jindesk -configuration Release -derivedDataPath build/release \
  -archivePath $out/Jindesk.xcarchive archive -quiet
cat >$out/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath $out/Jindesk.xcarchive -exportPath $out/export -exportOptionsPlist $out/ExportOptions.plist -quiet
app=$out/export/Jindesk.app
codesign --verify --deep --strict $app || fail "서명 확인 실패"
plist=$app/Contents/Info.plist
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $plist) == $version ]] || fail "앱 판이 $version 이 아닙니다"
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $plist) == $build ]] || fail "빌드 번호가 $build 가 아닙니다"
[[ $(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" $plist) == $pubkey ]] || fail "Info.plist 의 SUPublicEDKey 가 맞지 않습니다"
if grep -q '"dirty":true' $app/Contents/Resources/jobs/build.json; then
  (( dry )) && print "  ! 미커밋 지침을 담아 빌드했습니다 (dry-run 이라 넘어갑니다)" || fail "미커밋 지침을 담아 빌드했습니다"
fi
codesign -dvv $app 2>&1 | grep -E "^(Authority=Developer ID Application|TeamIdentifier|Runtime Version)" | sed 's/^/  /'
"$app/Contents/MacOS/Jindesk" version | sed 's/^/  /'
if [[ -n $backup ]]; then
  step "학생 백업으로 마이그레이션 시험: $backup"
  "$app/Contents/MacOS/Jindesk" migrate --check $backup || fail "마이그레이션 시험이 실패했습니다"
fi

if (( dry )); then
  print "✓ dry-run: 빌드와 서명 확인까지 했습니다 ($app). 공증과 올리기는 하지 않았습니다"
  exit 0
fi

# 4. 공증과 스테이플
# zip 에는 확장 속성(com.apple.provenance 등)을 담지 않는다. 담으면 번들 안에 ._ 파일로 들어가,
# 압축 해제 앱이 아닌 도구(unzip 등)로 풀 때 그 파일이 번들에 생겨 서명이 깨지고 Gatekeeper 가 막는다.
pack() { ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl $1 $2 }
step "공증 (notarytool, 프로필 $profile)"
pack $app $out/notarize.zip
xcrun notarytool submit $out/notarize.zip --keychain-profile $profile --wait
xcrun stapler staple $app
spctl --assess --type execute -vv $app 2>&1 | sed 's/^/  /'
zip=$out/Jindesk-$version.zip
pack $app $zip
# 받는 쪽처럼 unzip 으로 풀어 서명과 공증을 다시 본다
rm -rf $out/check && mkdir -p $out/check && unzip -q $zip -d $out/check
spctl --assess --type execute -vv $out/check/Jindesk.app 2>&1 | sed 's/^/  /'
spctl --assess --type execute $out/check/Jindesk.app 2>/dev/null || fail "풀어 낸 앱이 Gatekeeper 를 통과하지 못합니다"
rm -rf $out/check

# 5. Sparkle 서명
step "Sparkle 서명"
sign_update=$mac/build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
signature=$($sign_update --account $account $zip)
[[ $signature == *edSignature* ]] || fail "sign_update 가 서명을 내지 못했습니다: $signature"

# 6. appcast (이 릴리즈 하나만 담는다. 피드 주소가 늘 최신 릴리즈의 appcast.xml 을 가리킨다)
step "appcast.xml"
cat >$out/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Jindesk</title>
    <item>
      <title>$version</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$slug/releases/tag/$tag</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<pre>$(cat $notes)</pre>]]></description>
      <enclosure url="https://github.com/$slug/releases/download/$tag/Jindesk-$version.zip" $signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

# 7. 릴리즈 (이 단계에서만 관리자 계정의 gh 를 쓴다)
step "GitHub 릴리즈 $tag"
gh release create $tag $zip $out/appcast.xml -R $slug --target $head --title "Jindesk $version" --notes-file $notes
print "✓ 릴리즈했습니다: https://github.com/$slug/releases/tag/$tag"
