#!/usr/bin/env bash
set -euo pipefail

die() { echo "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Usage: tool/publish_android_release.sh \
  --apk=/absolute/path/to/accepted.apk --accepted-sha256=<sha256> \
  --source=<reviewed-release-commit> [--publish]
Without --publish this runs read-only checks. Use the exact APK built from --source
and accepted on the phone. --publish fast-forwards fork/main, creates the release
tag and GitHub Release, and then updates the OTA site.
USAGE
}

apk= accepted= source_commit= publish=0
for arg in "$@"; do
  case "$arg" in
    --apk=/*) apk="${arg#--apk=}" ;;
    --accepted-sha256=*) accepted="${arg#--accepted-sha256=}" ;;
    --source=*) source_commit="${arg#--source=}" ;;
    --publish) publish=1 ;;
    --help) usage; exit 0 ;;
    *) usage >&2; die "Unsupported argument: $arg" ;;
  esac
done
[[ -f "$apk" && "$accepted" =~ ^[0-9a-f]{64}$ && "$source_commit" =~ ^[0-9a-f]{40}$ ]] ||
  { usage >&2; die 'Provide the accepted APK, its SHA-256, and the full commit ID.'; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo=xixilys/ota_counter
remote_url="https://github.com/$repo.git"
base_url=https://ota-counter.huangxuanqi.top/ota-counter
[[ "$(git remote get-url fork)" == "$remote_url" && "$(git remote get-url --push fork)" == "$remote_url" ]] ||
  die "Both fork URLs must be $remote_url."

tmp="$(mktemp -d)"
# Only remove the named temporary files created by this run.
cleanup() {
  for file in "$tmp"/*; do
    [[ ! -f "$file" ]] || unlink "$file"
  done
  rmdir "$tmp"
}
trap cleanup EXIT

git show "$source_commit:release/update_site/latest.json" > "$tmp/latest.json"
git show "$source_commit:release/update_site/index.html" > "$tmp/index.html"
version="$(jq -er '.versionName | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$tmp/latest.json")"
code="$(jq -er '.versionCode | select(type == "number" and floor == . and . > 0)' "$tmp/latest.json")"
tag="v$version"
title="OTA Counter $tag"
apk_name="OTA-Counter-$tag.apk"
backup_url="https://github.com/$repo/releases/download/$tag/$apk_name"
git show "$source_commit:release/notes-$tag.md" > "$tmp/notes.md"
version_line="version: $version+$code"
git show "$source_commit:pubspec.yaml" | grep -Fx "$version_line" >/dev/null ||
  die 'The source commit pubspec does not match its release manifest.'
grep -Fx "$version_line" pubspec.yaml >/dev/null ||
  die 'This workspace pubspec does not match the source commit.'
jq -e --arg tag "$tag" --arg title "$title" --arg url "$base_url/$apk_name" --arg backup "$backup_url" '
  .versionLabel == $tag and .title == $title and .force == false and .primaryUrl == $url and
  .backupUrl == $backup and .platforms.android.primaryUrl == $url and .platforms.android.backupUrl == $backup
' "$tmp/latest.json" >/dev/null || die 'The release manifest points to the wrong assets.'

# The release owner records the digest from the file used for the successful adb install.
digest() { shasum -a 256 "$1" | awk '{print $1}'; }
cp "$apk" "$tmp/$apk_name"
[[ "$(digest "$tmp/$apk_name")" == "$accepted" ]] || die 'APK differs from the phone-accepted artifact.'
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
sdk="$ANDROID_HOME/build-tools/36.0.0"
tool/verify_android_release_signature.sh "$tmp/$apk_name"
"$sdk/aapt" dump badging "$tmp/$apk_name" > "$tmp/badging"
grep -F "package: name='top.huangxuanqi.otacounter' versionCode='$code' versionName='$version'" "$tmp/badging" >/dev/null &&
  grep -Fx "native-code: 'arm64-v8a'" "$tmp/badging" >/dev/null ||
  die "Expected top.huangxuanqi.otacounter $version+$code, Android arm64-v8a only."

read -r commit parent extra <<< "$(git rev-list --parents -n 1 "$source_commit")"
[[ "$commit" == "$source_commit" && -n "$parent" && -z "$extra" ]] ||
  die 'Release source must be one reviewed commit based directly on fork/main.'
# Catch accidental evidence/assets even if a path was explicitly staged.
if git diff --numstat --no-renames "$parent" "$commit" | awk '$1 == "-" || $2 == "-" { found=1 } END { exit !found }'; then
  die 'A binary changed in the release diff. Do not publish preview, fixture or user data.'
fi
refs="$(git ls-remote fork refs/heads/main "refs/tags/$tag" "refs/tags/$tag^{}")"
remote_main="$(awk '$2=="refs/heads/main"{print $1}' <<< "$refs")"
remote_tag="$(awk -v ref="refs/tags/$tag" '$2==ref{print $1}' <<< "$refs")"
peeled="$(awk -v ref="refs/tags/$tag^{}" '$2==ref{print $1}' <<< "$refs")"
[[ "$remote_main" == "$parent" || "$remote_main" == "$commit" ]] ||
  die 'fork/main moved or the source was assembled on the dirty-tree history. Review and rebuild.'
[[ -z "$remote_tag" || ("${peeled:-$remote_tag}" == "$commit" && "$remote_main" == "$commit") ]] ||
  die "$tag already exists for a different source; do not move the tag."

gh api "repos/$repo" | jq -e '.permissions.push and .default_branch == "main"' >/dev/null ||
  die 'The existing gh login cannot publish to the official repository.'
gh api "repos/$repo/releases/latest" > "$tmp/gh-latest"
jq -e --arg version "$version" '(.tag_name | ltrimstr("v") | split(".") | map(tonumber)) <= ($version | split(".") | map(tonumber))' "$tmp/gh-latest" >/dev/null ||
  die 'GitHub already has a newer release.'

fetch() { curl -fsSL --max-time 180 -H 'Cache-Control: no-cache' "$@"; }
fetch "$base_url/latest.json?release_check=$(date +%s)" -o "$tmp/previous.json"
jq -e --argjson code "$code" --arg version "$version" '
  (.versionName | split(".") | map(tonumber)) as $live |
  ($version | split(".") | map(tonumber)) as $next |
  (.versionCode < $code and $live < $next) or (.versionCode == $code and $live == $next)
' "$tmp/previous.json" >/dev/null || die 'OTA version is newer or collides with this release.'
live_code="$(jq -er '.versionCode' "$tmp/previous.json")"

verify_download() {
  fetch "$1" -o "$tmp/check.apk" &&
    [[ "$(digest "$tmp/check.apk")" == "$accepted" ]] ||
    die "Public download is missing or differs from the accepted APK: $1"
  tool/verify_android_release_signature.sh "$tmp/check.apk"
  printf 'Verified public APK (v1 + v2, production certificate, SHA-256 %s): %s\n' "$accepted" "$1"
}
if [[ "$live_code" == "$code" ]]; then
  [[ -n "$remote_tag" ]] || die 'OTA version is already live but its GitHub tag is missing.'
  verify_download "$base_url/$apk_name"
fi
ssh -o BatchMode=yes -o ConnectTimeout=8 root@bgvps   'test -w /var/www/ota-counter && cat /var/www/ota-counter/latest.json' > "$tmp/previous-remote.json" ||
  die 'The configured OTA SSH account cannot access the release directory.'
jq -e --slurpfile remote "$tmp/previous-remote.json" '. == $remote[0]' "$tmp/previous.json" >/dev/null ||
  die 'The OTA origin and public manifest disagree. Confirm the live OTA state before retrying.'
mv "$tmp/previous-remote.json" "$tmp/previous.json"

# A prior partial run may have pushed the tag but not made the release public.
have_release=0
if [[ -n "$remote_tag" ]]; then
  if gh api "repos/$repo/releases/tags/$tag" > "$tmp/release.json" 2> "$tmp/release-api-error"; then
    jq -e --arg apk "$apk_name" '
      (.draft | not) and (.prerelease | not) and ([.assets[].name] == [$apk])
    ' "$tmp/release.json" >/dev/null ||
      die "Inspect the existing $tag release before retrying; it has a draft, prerelease or unexpected assets."
    verify_download "$backup_url"
    have_release=1
  elif ! grep -q 'HTTP 404' "$tmp/release-api-error"; then
    cat "$tmp/release-api-error" >&2
    die "Could not verify the GitHub release state for $tag."
  fi
fi

printf 'Validated %s+%s APK and release commit %s\n' "$version" "$code" "$commit"
git diff --stat --no-renames "$parent" "$commit"
if [[ "$publish" == 0 ]]; then
  echo 'Read-only check complete. --publish updates fork/main, the GitHub Release and the OTA site.'
  exit 0
fi

if [[ "$live_code" != "$code" ]]; then
  backup="$(mktemp -d "$HOME/.ota-counter/before-$tag.XXXXXXXX")"
  cp "$tmp/previous.json" "$backup/latest.json"
  fetch "$base_url/" -o "$backup/index.html"
  echo "Previous OTA manifest and page: $backup"
fi

if [[ -z "$remote_tag" ]]; then
  git push --atomic fork "$commit:refs/heads/main" "$commit:refs/tags/$tag"
fi
if [[ "$have_release" == 0 ]]; then
  gh release create "$tag" "$tmp/$apk_name" --repo "$repo" --verify-tag --latest \
    --title "$title" --notes-file "$tmp/notes.md"
  verify_download "$backup_url"
fi

if [[ "$live_code" != "$code" ]]; then
  published_at="$(gh release view "$tag" --repo "$repo" --json publishedAt --jq '.publishedAt')"
  [[ "$published_at" == *Z ]] || die 'The public GitHub release has no publication timestamp.'
  jq --arg publishedAt "$published_at" '.publishedAt = $publishedAt' "$tmp/latest.json" > "$tmp/stamped.json"
  mv "$tmp/stamped.json" "$tmp/latest.json"
  OTA_UPDATE_SSH_USER=root OTA_UPDATE_SSH_HOST=bgvps OTA_UPDATE_REMOTE_DIR=/var/www/ota-counter \
    OTA_UPDATE_PUBLIC_BASE_URL="$base_url" tool/deploy_update_site.sh \
      --apk="$tmp/$apk_name" --site-dir="$tmp" --previous-manifest="$tmp/previous.json"
  verify_download "$base_url/$apk_name"
fi

fetch "$base_url/latest.json?release_check=$(date +%s)" -o "$tmp/live.json"
jq -e --slurpfile expected "$tmp/latest.json" '
  .publishedAt != null and (del(.publishedAt) == ($expected[0] | del(.publishedAt)))
' "$tmp/live.json" >/dev/null || die 'The live manifest differs from the reviewed release.'
fetch "$base_url/?release_check=$(date +%s)" -o "$tmp/live.html"
cmp -s "$tmp/live.html" "$tmp/index.html" || die 'The live download page differs from the reviewed release.'
echo "Published and verified: $base_url/ and https://github.com/$repo/releases/tag/$tag"
