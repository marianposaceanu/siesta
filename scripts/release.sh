#!/bin/sh
# Derive the next version from conventional commits since the last tag, then release it.
#
#   scripts/release.sh next      print the next version and the bump that justifies it
#   scripts/release.sh           bump the version constant, prepend CHANGELOG.md, commit, tag
#
# Rules, for a 0.x project: a breaking change (`type!:` or a BREAKING CHANGE footer) or a `feat`
# bumps the minor version, `fix` and `perf` bump the patch version, every other type does not
# release. The first release is 0.1.0.
set -eu

cd "$(dirname "$0")/.."
constant=Sources/siesta/Commands.swift

last_tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
range=${last_tag:+$last_tag..}HEAD
subjects=$(git log --format='%s' "$range")
bodies=$(git log --format='%b' "$range")

bump=none
if printf '%s\n' "$subjects" | grep -Eq '^[a-z]+(\([^)]*\))?!:' || printf '%s\n' "$bodies" | grep -q '^BREAKING CHANGE'; then
  bump=minor
elif printf '%s\n' "$subjects" | grep -Eq '^feat(\([^)]*\))?:'; then
  bump=minor
elif printf '%s\n' "$subjects" | grep -Eq '^(fix|perf)(\([^)]*\))?:'; then
  bump=patch
fi

if [ -z "$last_tag" ]; then
  next=0.1.0
  [ "$bump" = none ] && bump=initial
else
  current=${last_tag#v}
  major=${current%%.*}; rest=${current#*.}; minor=${rest%%.*}; patch=${rest#*.}
  case $bump in
    minor) next=$major.$((minor + 1)).0 ;;
    patch) next=$major.$minor.$((patch + 1)) ;;
    none)  echo "nothing to release since $last_tag: no feat, fix or breaking change" >&2; exit 1 ;;
  esac
fi

if [ "${1:-}" = next ]; then
  echo "$next ($bump, since ${last_tag:-the beginning})"
  exit 0
fi

[ -z "$(git status --porcelain)" ] || { echo "working tree not clean" >&2; exit 1; }

scratch=$(mktemp)
trap 'rm -f "$scratch"' EXIT

section() {
  pattern=$1; title=$2
  lines=$(git log --format='%s' "$range" | grep -E "^$pattern(\([^)]*\))?!?:" | sed -E 's/^[a-z]+(\(([^)]*)\))?!?: */- /' || true)
  if [ -n "$lines" ]; then printf '### %s\n\n%s\n\n' "$title" "$lines"; fi
}
{
  printf '## v%s (%s)\n\n' "$next" "$(date +%Y-%m-%d)"
  section 'feat' 'Features'
  section '(fix|perf)' 'Fixes'
  section '(refactor|build|docs|chore|test|ci)' 'Other'
  if [ -f CHANGELOG.md ]; then sed '1{/^# Changelog$/d;}' CHANGELOG.md | sed '/./,$!d'; fi
} > "$scratch"
{ printf '# Changelog\n\n'; cat "$scratch"; } > CHANGELOG.md
rm -f "$scratch"

sed -i '' "s/^let siestaVersion = \"[0-9.]*\"/let siestaVersion = \"$next\"/" "$constant"
grep -q "\"$next\"" "$constant"
git add CHANGELOG.md "$constant"
git commit -q -m "chore(release): v$next"
git tag -a "v$next" -m "siesta $next"
echo "released v$next ($bump); push with: git push origin main v$next"
