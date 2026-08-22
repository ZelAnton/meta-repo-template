#!/usr/bin/env bash
#
# META(%%): this is the GENERATED template's init script (POSIX counterpart of
# init.ps1). It substitutes the PROJECT tokens (__ProjectName__ etc.) — leave those
# literal strings intact. Fill the meta-token slots (the "Next steps" echo) and adapt the
# marked language-specific blocks for %%LangName%%. The engine is neutral — keep it.
# See META-AUTHORING.md.
#
# Replaces the placeholder tokens in file contents AND in file/folder names, then
# removes the template-only files (TEMPLATE.md, docs/AGENT-INIT-GUIDE.md,
# tests/init-metadata.tests.ps1) and — unless --keep-script — both initializers
# (init.sh and init.ps1).
#
# Usage:
#   bash ./scripts/init.sh --project-name Acme.Widgets \
#       [--author "Jane Doe"] [--author-email you@example.com] \
#       [--github-owner acme] [--description "Widget toolkit"] \
#       [--year 2026] [--keep-script]
#
# Author and author-email values must be single-line; release-workflow use is
# serialized so shell metacharacters remain literal. GitHub owner values must be
# 1-39 letters, digits, or internal hyphens.

set -euo pipefail

# bash 5.2+ treats a literal '&' in ${var//pat/repl} as the matched text. Our
# XML-escaped values contain '&amp;', so turn that off. Harmless on older bash.
shopt -u patsub_replacement 2>/dev/null || true

project_name=""
author=""
author_email=""
github_owner=""
description=""
year=""
keep_script=0

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project-name) project_name="${2:-}"; shift 2 ;;
    --author)       author="${2:-}"; shift 2 ;;
    --author-email) author_email="${2:-}"; shift 2 ;;
    --github-owner) github_owner="${2:-}"; shift 2 ;;
    --description)  description="${2:-}"; shift 2 ;;
    --year)         year="${2:-}"; shift 2 ;;
    --keep-script)  keep_script=1; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[ -n "$project_name" ] || die "--project-name is required (e.g. --project-name Acme.Widgets)."

# Letters, digits, underscores; dot-separated segments allowed. Mirrors init.ps1.
case "$project_name" in
  .*|*.) die "invalid --project-name '$project_name'. Use letters, digits, underscores; dot-separated segments allowed (e.g. Acme.Widgets)." ;;
esac
IFS='.' read -ra _segs <<< "$project_name"
for seg in "${_segs[@]}"; do
  case "$seg" in
    [A-Za-z_]*) ;;
    *) die "invalid --project-name '$project_name'." ;;
  esac
  case "$seg" in
    *[!A-Za-z0-9_]*) die "invalid --project-name '$project_name'." ;;
  esac
done

# Defaults (mirror init.ps1).
if [ -z "$author" ]; then
  author="$(git config user.name 2>/dev/null || true)"
  [ -n "$author" ] || author="Your Name"
fi
if [ -z "$author_email" ]; then
  author_email="$(git config user.email 2>/dev/null || true)"
  [ -n "$author_email" ] || author_email="you@example.com"
fi
[ -n "$github_owner" ] || github_owner="your-org"
[ -n "$description" ]  || description="TODO: project description"
[ -n "$year" ]         || year="$(date +%Y)"

case "$author" in
  *$'\r'*|*$'\n'*) die "invalid --author: line breaks are not allowed. No files were changed." ;;
esac
case "$author_email" in
  *$'\r'*|*$'\n'*) die "invalid --author-email: line breaks are not allowed. No files were changed." ;;
esac
if [[ ! "$github_owner" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
  die "invalid --github-owner. Use 1-39 letters, digits, or hyphens, with no leading or trailing hyphen. No files were changed."
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
self="$script_dir/$(basename "$0")"
sibling_ps1="$script_dir/init.ps1"
claude_settings="$repo_root/.claude/settings.json"
claude_template="$repo_root/.claude/settings.json.template"
has_existing_claude_settings=0
if [ -e "$claude_settings" ] || [ -L "$claude_settings" ]; then
  has_existing_claude_settings=1
fi

# META(%%): XML-manifest languages (.NET) must XML-escape values written into project
# files. Non-XML languages (Rust TOML, Gradle KTS) can drop xml_escape and the
# *.csproj|*.fsproj|... case below so substitution uses raw values.
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
project_x="$(xml_escape "$project_name")"
author_x="$(xml_escape "$author")"
author_email_x="$(xml_escape "$author_email")"
owner_x="$(xml_escape "$github_owner")"
desc_x="$(xml_escape "$description")"
year_x="$(xml_escape "$year")"
author_b64="$(printf '%s' "$author" | base64 | tr -d '\r\n')"
author_email_b64="$(printf '%s' "$author_email" | base64 | tr -d '\r\n')"

token_pattern='(__ProjectName__|__AuthorEmailBase64__|__AuthorBase64__|__AuthorEmail__|__Author__|__GitHubOwner__|__Description__|__Year__)'

replace_tokens() {
  local content="$1"
  local mode="$2"
  local rest="$content"
  local output=""
  local token prefix replacement

  while [[ "$rest" =~ $token_pattern ]]; do
    token="${BASH_REMATCH[1]}"
    prefix="${rest%%"$token"*}"
    output+="$prefix"
    case "$token" in
      __ProjectName__)       if [ "$mode" = xml ]; then replacement="$project_x"; else replacement="$project_name"; fi ;;
      __Author__)            if [ "$mode" = xml ]; then replacement="$author_x"; else replacement="$author"; fi ;;
      __AuthorEmail__)       if [ "$mode" = xml ]; then replacement="$author_email_x"; else replacement="$author_email"; fi ;;
      __AuthorBase64__)      replacement="$author_b64" ;;
      __AuthorEmailBase64__) replacement="$author_email_b64" ;;
      __GitHubOwner__)       if [ "$mode" = xml ]; then replacement="$owner_x"; else replacement="$github_owner"; fi ;;
      __Description__)       if [ "$mode" = xml ]; then replacement="$desc_x"; else replacement="$description"; fi ;;
      __Year__)              if [ "$mode" = xml ]; then replacement="$year_x"; else replacement="$year"; fi ;;
    esac
    output+="$replacement"
    rest="${rest#*"$token"}"
  done
  printf '%s%s' "$output" "$rest"
}

echo "==> Initializing template as '$project_name'"

# 1) Replace tokens in file contents. Both initializers are skipped (they carry the
#    literal token strings as search keys). An existing user settings file is opaque
#    and must survive byte-for-byte. Excluded dirs are pruned.
# META(%%): add your build dirs to the -prune list (e.g. -o -name target -o -name build).
changed=0
while IFS= read -r -d '' file; do
  case "$file" in
    "$self"|"$sibling_ps1") continue ;;
  esac
  if [ "$file" = "$claude_settings" ]; then
    continue
  fi
  # Skip binary files (NUL bytes get stripped through command substitution).
  case "$file" in
    *.snk|*.pfx|*.png|*.jpg|*.jpeg|*.gif|*.ico|*.zip|*.jar) continue ;;
  esac
  # Preserve trailing newlines: append a sentinel before capture, strip it after.
  content="$(cat "$file"; printf x)"; content="${content%x}"
  orig="$content"
  case "$file" in
    *.csproj|*.fsproj|*.props|*.targets|*.slnx|*.config) mode=xml ;;
    *) mode=raw ;;
  esac
  content="$(replace_tokens "$content" "$mode"; printf x)"; content="${content%x}"
  if [ "$content" != "$orig" ]; then
    printf '%s' "$content" > "$file"
    changed=$((changed + 1))
  fi
done < <(find "$repo_root" -type d \( -name .git -o -name .jj -o -name .work -o -name .inbox -o -name bin -o -name obj \) -prune -o -type f -print0)
echo "    Updated contents in $changed file(s)."

# 2) Rename files and folders whose name contains the project-name token. -depth
#    processes children before parents (deepest paths first).
while IFS= read -r -d '' item; do
  relative_item="${item#"$repo_root"/}"
  case "/$relative_item/" in
    */.git/*|*/.jj/*|*/.work/*|*/.inbox/*|*/bin/*|*/obj/*) continue ;;
  esac
  dir="$(dirname "$item")"
  base="$(basename "$item")"
  newbase="${base//__ProjectName__/$project_name}"
  if [ "$newbase" != "$base" ]; then
    mv "$item" "$dir/$newbase"
    echo "    Renamed $base -> $newbase"
  fi
done < <(find "$repo_root" -depth -name '*__ProjectName__*' -print0)

# META(%%): language-specific post-processing here if needed (e.g. Kotlin package-dir move).

# 3) Activate the Claude Code shared settings.
if [ "$has_existing_claude_settings" -eq 1 ]; then
  if [ -f "$claude_template" ]; then
    echo "    Kept existing .claude/settings.json unchanged; left .claude/settings.json.template in place."
  else
    echo "    Kept existing .claude/settings.json unchanged; no settings template needed activation."
  fi
elif [ -f "$claude_template" ]; then
  if ln "$claude_template" "$claude_settings" 2>/dev/null; then
    rm "$claude_template"
    echo "    Activated .claude/settings.json"
  elif [ -e "$claude_settings" ] || [ -L "$claude_settings" ]; then
    echo "    Kept existing .claude/settings.json unchanged; left .claude/settings.json.template in place."
  else
    die "could not activate .claude/settings.json without overwriting a destination."
  fi
fi

# 4) Remove template-only files.
rm -f "$repo_root/TEMPLATE.md" "$repo_root/docs/AGENT-INIT-GUIDE.md" \
  "$repo_root/tests/init-metadata.tests.ps1"
rmdir "$repo_root/docs" 2>/dev/null || true

echo ""
echo "Done. Next steps:"
# META(%%): fill these with your build/test commands and publishing note.
echo "  1. %%BuildCmd%%"
echo "  2. %%TestCmd%%"
echo "  3. Review LICENSE (author/year) and the package metadata in %%ManifestFile%%."
echo "  4. Publishing: add the %%PublishSecret%% repo secret, or delete"
echo "     .github/workflows/release.yml and the packaging metadata."
echo "  5. Commit the initialized project."

# 5) Remove both initializers unless asked to keep them.
if [ "$keep_script" -ne 1 ]; then
  rm -f "$sibling_ps1"
  rm -f "$self"
fi
