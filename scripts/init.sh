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
internal_recover_only="${META_INIT_RECOVER_ONLY:-}"
internal_recovery_parent_token="${META_INIT_RECOVERY_PARENT_TOKEN:-}"
internal_allow_empty_transaction=0

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
    --internal-recover-only) internal_recover_only=1; shift ;;
    --internal-recovery-parent-token) internal_recovery_parent_token="${2:-}"; shift 2 ;;
    --internal-allow-empty-transaction) internal_allow_empty_transaction=1; shift ;;
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

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
self="$script_dir/$(basename "$0")"
sibling_ps1="$script_dir/init.ps1"
claude_settings="$repo_root/.claude/settings.json"
claude_template="$repo_root/.claude/settings.json.template"
has_existing_claude_settings=0

# Fail closed if strict UTF-8 validation is unavailable; silently skipping all
# content would otherwise produce a partially initialized project.
utf8_validator="$(command -v iconv 2>/dev/null || true)"
[ -n "$utf8_validator" ] || die "iconv is required for strict UTF-8 validation. Install iconv and rerun."

failure_phase="${META_INIT_TEST_FAIL_PHASE:-}"
case "$failure_phase" in
  ""|content|rename|settings|cleanup|scripts) ;;
  *) die "invalid META_INIT_TEST_FAIL_PHASE '$failure_phase'. No files were changed." ;;
esac

controlled_failure() {
  local phase="$1" actual_source="${2:-}" wanted_source="${META_INIT_TEST_FAIL_RENAME_SOURCE:-}"
  if [ "$failure_phase" = "$phase" ] &&
    { [ "$phase" != rename ] || [ -z "$wanted_source" ] || [ "$actual_source" = "$wanted_source" ]; }; then
    die "controlled test failure after $1 phase."
  fi
}

crash_phase="${META_INIT_TEST_CRASH_PHASE:-}"
case "$crash_phase" in
  ""|content|rename|settings|cleanup|scripts) ;;
  *) die "invalid META_INIT_TEST_CRASH_PHASE '$crash_phase'. No files were changed." ;;
esac
crash_triggered=0
controlled_crash() {
  local phase="$1" actual_source="${2:-}" wanted_source="${META_INIT_TEST_CRASH_RENAME_SOURCE:-}"
  if [ "$crash_triggered" -eq 0 ] && [ "$crash_phase" = "$phase" ] &&
    { [ "$phase" != rename ] || [ -z "$wanted_source" ] || [ "$actual_source" = "$wanted_source" ]; }; then
    crash_triggered=1
    kill -KILL "$$"
  fi
}

# META(%%): XML-manifest languages (.NET) must XML-escape values written into project
# files. Non-XML languages (Rust TOML, Gradle KTS) can drop xml_escape and the
# *.csproj|*.fsproj|... case below so substitution uses raw values.
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
project_x=""; author_x=""; author_email_x=""; owner_x=""; desc_x=""; year_x=""
author_b64=""; author_email_b64=""

token_pattern='(__ProjectName__|__AuthorEmailBase64__|__AuthorBase64__|__AuthorEmail__|__Author__|__GitHubOwner__|__Description__|__Year__)'

is_supported_utf8_file() {
  local file="$1"
  # iconv is used only as a strict validator; the original bytes are fed to the
  # replacement pass so BOMs, line endings, and all non-token bytes are retained.
  "$utf8_validator" -f UTF-8 -t UTF-8 < "$file" >/dev/null 2>&1 || return 1
  # NUL is technically valid UTF-8 but is a binary marker for this initializer.
  LC_ALL=C tr -d '\000' < "$file" | cmp -s - "$file" || return 1
  return 0
}

replace_tokens_file() {
  local source="$1" destination="$2" mode="$3"
  META_INIT_PROJECT="$project_name" \
  META_INIT_AUTHOR="$author" \
  META_INIT_AUTHOR_EMAIL="$author_email" \
  META_INIT_AUTHOR_B64="$author_b64" \
  META_INIT_AUTHOR_EMAIL_B64="$author_email_b64" \
  META_INIT_OWNER="$github_owner" \
  META_INIT_DESCRIPTION="$description" \
  META_INIT_YEAR="$year" \
  META_INIT_XML_MODE="$mode" \
    perl -0pe '
      BEGIN {
        %replacement = (
          "__ProjectName__"       => $ENV{META_INIT_PROJECT},
          "__Author__"            => $ENV{META_INIT_AUTHOR},
          "__AuthorEmail__"       => $ENV{META_INIT_AUTHOR_EMAIL},
          "__AuthorBase64__"      => $ENV{META_INIT_AUTHOR_B64},
          "__AuthorEmailBase64__" => $ENV{META_INIT_AUTHOR_EMAIL_B64},
          "__GitHubOwner__"        => $ENV{META_INIT_OWNER},
          "__Description__"        => $ENV{META_INIT_DESCRIPTION},
          "__Year__"              => $ENV{META_INIT_YEAR},
        );
        if (($ENV{META_INIT_XML_MODE} // "") eq "xml") {
          for my $key (keys %replacement) {
            $replacement{$key} =~ s/&/&amp;/g;
            $replacement{$key} =~ s/</&lt;/g;
            $replacement{$key} =~ s/>/&gt;/g;
          }
        }
      }
      s/(__ProjectName__|__AuthorEmailBase64__|__AuthorBase64__|__AuthorEmail__|__Author__|__GitHubOwner__|__Description__|__Year__)/$replacement{$1}/g;
    ' "$source" > "$destination"
}

encode_path() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
decode_path() {
  local encoded="$1" decoded
  if decoded="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)"; then :
  elif decoded="$(printf '%s' "$encoded" | base64 -d 2>/dev/null)"; then :
  elif decoded="$(printf '%s' "$encoded" | base64 -D 2>/dev/null)"; then :
  else return 1
  fi
  printf '%s' "$decoded"
}

stat_mode() {
  local value
  if value="$(stat -c '%a' -- "$1" 2>/dev/null)"; then :
  elif value="$(stat -f '%Lp' -- "$1" 2>/dev/null)"; then :
  else return 1
  fi
  case "$value" in *[!0-7]*|'') return 1 ;; esac
  printf '%s' "$value"
}

stat_links() {
  local value
  if [ "${OS:-}" = Windows_NT ] && command -v fsutil.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    if value="$(fsutil.exe hardlink list "$(cygpath -w "$1")" 2>/dev/null)"; then
      value="$(printf '%s\n' "$value" | awk 'NF { count++ } END { print count + 0 }')"
      case "$value" in *[!0-9]*|'') return 1 ;; esac
      printf '%s' "$value"
      return 0
    fi
    return 1
  fi
  if value="$(stat -c '%h' -- "$1" 2>/dev/null)"; then :
  elif value="$(stat -f '%l' -- "$1" 2>/dev/null)"; then :
  else return 1
  fi
  case "$value" in *[!0-9]*|'') return 1 ;; esac
  printf '%s' "$value"
}

is_excluded() {
  local relative="${1#"$repo_root"/}"
  case "$relative" in
    .meta-init-transaction.owner|.meta-init-transaction.recovery|.meta-init-owner.*.tmp) return 0 ;;
  esac
  case "/$relative/" in
    */.git/*|*/.jj/*|*/.work/*|*/.inbox/*|*/bin/*|*/obj/*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_owned_path() {
  local path="$1" purpose="$2" require_file="${3:-0}" relative cursor links
  case "$path" in
    "$repo_root"|"$repo_root"/*) ;;
    *) die "the $purpose path '$path' escapes the repository. No files were changed." ;;
  esac
  case "$path" in *$'\n'*|*$'\r'*) die "the $purpose path contains a line break and cannot be journaled safely. No files were changed." ;; esac
  relative="${path#"$repo_root"/}"
  cursor="$repo_root"
  IFS='/' read -ra _path_segments <<< "$relative"
  for _path_segment in "${_path_segments[@]}"; do
    cursor="$cursor/$_path_segment"
    if [ -L "$cursor" ]; then
      die "the $purpose path '$path' uses a symbolic link. No files were changed."
    fi
  done
  if [ "$require_file" -eq 1 ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || die "the $purpose path '$path' is not a regular owned file. No files were changed."
    links="$(stat_links "$path")" || die "could not inspect hard-link ownership for '$path'. No files were changed."
    [ "$links" -eq 1 ] || die "the $purpose path '$path' is hard-linked and is not independently owned. No files were changed."
  fi
}

coordination_repo_identity="$repo_root"
if [ "${OS:-}" = Windows_NT ]; then
  if command -v cygpath >/dev/null 2>&1; then
    coordination_repo_identity="$(cygpath -am "$coordination_repo_identity")" ||
      die "could not establish the Windows repository identity. No files were changed."
  else
    case "$coordination_repo_identity" in
      /[A-Za-z]/*) coordination_repo_identity="${coordination_repo_identity:1:1}:${coordination_repo_identity:2}" ;;
      [A-Za-z]:/*) ;;
    esac
  fi
  coordination_repo_identity="${coordination_repo_identity,,}"
elif [ -n "${WSL_DISTRO_NAME:-}" ]; then
  case "$coordination_repo_identity" in
    /mnt/[A-Za-z]/*)
      coordination_repo_identity="${coordination_repo_identity:5:1}:${coordination_repo_identity:6}"
      coordination_repo_identity="${coordination_repo_identity,,}" ;;
  esac
fi

if command -v sha256sum >/dev/null 2>&1; then
  repo_hash="$(printf '%s' "$repo_root" | sha256sum | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  repo_hash="$(printf '%s' "$repo_root" | shasum -a 256 | awk '{print $1}')"
else
  die "sha256sum or shasum is required for crash-recovery identity. No files were changed."
fi
transaction_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
case "$transaction_parent/" in
  "$repo_root/"|"$repo_root/"*) die "the temporary directory must be outside the repository. No files were changed." ;;
esac
transaction_root="$transaction_parent/meta-init-transaction-$repo_hash-bash"
manifest_path="$transaction_root/manifest"
coordination_path="$repo_root/.meta-init-transaction.owner"
coordination_recovery_path="$repo_root/.meta-init-transaction.recovery"
coordination_token=""
owns_coordination=0
owns_recovery_claim=0
recovery_only="$internal_recover_only"

journal_state=""
journal_root=""
journal_version=""
journal_engine=""
journal_content_paths=()
journal_content_backups=()
journal_content_stages=()
journal_content_modes=()
journal_rename_sources=()
journal_rename_destinations=()
journal_cleanup_paths=()
journal_cleanup_backups=()
journal_cleanup_modes=()
journal_settings_template=""
journal_settings_destination=""
journal_settings_backup=""
journal_settings_mode=""
journal_docs=""
journal_deferred=()

owner_engine=""
owner_root=""
owner_pid=""
owner_namespace=""
owner_identity_kind=""
owner_identity=""
owner_token=""

load_coordination_record() {
  local record_path="$1" key value extra
  owner_engine=""; owner_root=""; owner_pid=""; owner_namespace=""
  owner_identity_kind=""; owner_identity=""; owner_token=""
  declare -A seen=()
  while IFS='|' read -r key value extra <&9; do
    value="${value%$'\r'}"
    [ -n "$key" ] && [ -z "$extra" ] && [ -z "${seen["$key"]+set}" ] || return 1
    seen["$key"]=1
    case "$key" in
      VERSION) [ "$value" = 2 ] || return 1 ;;
      ENGINE) owner_engine="$(decode_path "$value")" || return 1 ;;
      ROOT) owner_root="$(decode_path "$value")" || return 1 ;;
      PID) owner_pid="$(decode_path "$value")" || return 1 ;;
      NAMESPACE) owner_namespace="$(decode_path "$value")" || return 1 ;;
      IDENTITY_KIND) owner_identity_kind="$(decode_path "$value")" || return 1 ;;
      IDENTITY) owner_identity="$(decode_path "$value")" || return 1 ;;
      TOKEN) owner_token="$(decode_path "$value")" || return 1 ;;
      *) return 1 ;;
    esac
  done 9< "$record_path"
  [ "$owner_engine" = bash ] || [ "$owner_engine" = pwsh ] || return 1
  [ "$owner_root" = "$coordination_repo_identity" ] || return 1
  case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$owner_pid" -gt 0 ] && [ -n "$owner_namespace" ] && [ -n "$owner_identity_kind" ] &&
    [ -n "$owner_identity" ] && [ -n "$owner_token" ]
}

resolve_pwsh() {
  if command -v pwsh >/dev/null 2>&1; then printf '%s' pwsh; return 0; fi
  if command -v pwsh.exe >/dev/null 2>&1; then printf '%s' pwsh.exe; return 0; fi
  if pwsh.exe -NoProfile -Command 'exit 0' >/dev/null 2>&1; then printf '%s' pwsh.exe; return 0; fi
  return 1
}

resolve_windows_pwsh() {
  if command -v pwsh.exe >/dev/null 2>&1; then printf '%s' pwsh.exe; return 0; fi
  if [ "${OS:-}" = Windows_NT ] && command -v pwsh >/dev/null 2>&1; then printf '%s' pwsh; return 0; fi
  return 1
}

stat_owner() {
  local value
  if value="$(stat -c '%u' -- "$1" 2>/dev/null)"; then :
  elif value="$(stat -f '%u' -- "$1" 2>/dev/null)"; then :
  else return 1
  fi
  case "$value" in *[!0-9]*|'') return 1 ;; esac
  printf '%s' "$value"
}

set_private_windows_transaction_root() {
  local pwsh_command path_b64 windows_path
  pwsh_command="$(resolve_windows_pwsh)" || return 1
  command -v cygpath >/dev/null 2>&1 || return 1
  windows_path="$(cygpath -aw "$transaction_root")" || return 1
  path_b64="$(encode_path "$windows_path")"
  META_INIT_TRANSACTION_PATH_B64="$path_b64" "$pwsh_command" -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"
    $path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:META_INIT_TRANSACTION_PATH_B64))
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $path "/inheritance:r" "/grant:r" ("*" + $sid + ":(OI)(CI)F") | Out-Null
    if ($LASTEXITCODE -ne 0) { exit 11 }
  ' >/dev/null
}

assert_private_windows_transaction_tree() {
  local full_check="${1:-1}" pwsh_command path_b64 windows_path
  pwsh_command="$(resolve_windows_pwsh)" || return 1
  command -v cygpath >/dev/null 2>&1 || return 1
  windows_path="$(cygpath -aw "$transaction_root")" || return 1
  path_b64="$(encode_path "$windows_path")"
  META_INIT_TRANSACTION_PATH_B64="$path_b64" META_INIT_TRANSACTION_FULL_CHECK="$full_check" "$pwsh_command" -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"
    $root = [IO.Path]::GetFullPath([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:META_INIT_TRANSACTION_PATH_B64)))
    $fullCheck = $env:META_INIT_TRANSACTION_FULL_CHECK -eq "1"
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $items = @((Get-Item -LiteralPath $root -Force -ErrorAction Stop)) +
      @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)
    foreach ($item in $items) {
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) {
        throw "linked transaction path"
      }
      if ($fullCheck -or $item.FullName -eq $root) {
        $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid) {
          throw "foreign transaction owner"
        }
        $foreignAllows = @($acl.Access | Where-Object {
          if ($_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { return $false }
          $ruleSid = try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { "" }
          $ruleSid -ne $sid
        })
        if ($foreignAllows.Count -gt 0) { throw "non-private transaction ACL" }
        if ($item.FullName -eq $root -and -not $acl.AreAccessRulesProtected) {
          throw "inherited transaction ACL"
        }
      }
    }
  ' >/dev/null
}

assert_private_posix_transaction_item() {
  local path="$1" expected_mode="$2" owner mode current_uid
  current_uid="$(id -u 2>/dev/null)" || return 1
  owner="$(stat_owner "$path")" || return 1
  [ "$owner" = "$current_uid" ] || return 1
  mode="$(stat_mode "$path")" || return 1
  [ "$mode" = "$expected_mode" ]
}

assert_private_transaction_directory() {
  local directory="$1" path links
  local -a entries
  shopt -s nullglob dotglob
  entries=("$directory"/*)
  shopt -u nullglob dotglob
  for path in "${entries[@]}"; do
    [ ! -L "$path" ] || return 1
    if [ -d "$path" ]; then
      if [ "${OS:-}" != Windows_NT ]; then
        assert_private_posix_transaction_item "$path" 700 || return 1
      fi
      assert_private_transaction_directory "$path" || return 1
    elif [ -f "$path" ]; then
      links="$(stat_links "$path")" || return 1
      [ "$links" -eq 1 ] || return 1
      if [ "${OS:-}" != Windows_NT ]; then
        assert_private_posix_transaction_item "$path" 600 || return 1
      fi
    else
      return 1
    fi
  done
}

assert_private_transaction_tree() {
  [ -d "$transaction_root" ] && [ ! -L "$transaction_root" ] || {
    echo "error: transaction root '$transaction_root' is not an owned regular directory. Refusing unsafe recovery." >&2
    return 1
  }
  if [ "${OS:-}" = Windows_NT ]; then
    assert_private_windows_transaction_tree 1 || {
      echo "error: transaction root '$transaction_root' has an insecure owner, ACL, or link boundary. Refusing unsafe recovery." >&2
      return 1
    }
    return 0
  else
    assert_private_posix_transaction_item "$transaction_root" 700 || {
      echo "error: transaction root '$transaction_root' has an insecure owner or mode. Refusing unsafe recovery." >&2
      return 1
    }
  fi
  assert_private_transaction_directory "$transaction_root" || {
    echo "error: transaction tree '$transaction_root' contains an insecure link, owner, mode, or file type. Refusing unsafe recovery." >&2
    return 1
  }
}

assert_owned_transaction_tree() {
  [ -d "$transaction_root" ] && [ ! -L "$transaction_root" ] || return 1
  if [ "${OS:-}" = Windows_NT ]; then
    assert_private_windows_transaction_tree 0
    return
  fi
  assert_private_posix_transaction_item "$transaction_root" 700 &&
    assert_private_transaction_directory "$transaction_root"
}

assert_transaction_root_entry() {
  [ -d "$transaction_root" ] && [ ! -L "$transaction_root" ]
}

validate_recovery_repo_path() {
  local path="$1" purpose="$2" relative cursor
  [ -n "$path" ] || { echo "error: recovery $purpose path is empty." >&2; return 1; }
  case "$path" in *$'\n'*|*$'\r'*) echo "error: recovery $purpose path contains a line break." >&2; return 1 ;; esac
  case "$path" in "$repo_root"|"$repo_root"/*) ;; *) echo "error: recovery $purpose path '$path' escapes the repository." >&2; return 1 ;; esac
  relative="${path#"$repo_root"/}"
  case "/$relative/" in *'/../'*|*'/./'*|*'//'*) echo "error: recovery $purpose path '$path' is not canonical." >&2; return 1 ;; esac
  case "$path" in */) echo "error: recovery $purpose path '$path' is not canonical." >&2; return 1 ;; esac
  cursor="$path"
  while [ "$cursor" != "$repo_root" ]; do
    [ ! -L "$cursor" ] || { echo "error: recovery $purpose path '$path' uses a symbolic link." >&2; return 1; }
    cursor="${cursor%/*}"
    [ -n "$cursor" ] || return 1
  done
}

validate_recovery_file_if_present() {
  local path="$1" purpose="$2" allow_settings_pair="${3:-0}" links
  validate_recovery_repo_path "$path" "$purpose" || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || { echo "error: recovery $purpose path '$path' is not a regular file." >&2; return 1; }
    if [ "$allow_settings_pair" -ne 1 ]; then
      links="$(stat_links "$path")" || return 1
      [ "$links" -eq 1 ] || { echo "error: recovery $purpose path '$path' is hard-linked." >&2; return 1; }
    fi
  fi
}

valid_journal_mode() {
  case "$1" in ''|*[!0-7]*) return 1 ;; esac
  [ "${#1}" -ge 3 ] && [ "${#1}" -le 4 ]
}

if [ "${OS:-}" = Windows_NT ]; then
  current_process_namespace=windows
elif [ -n "${WSL_DISTRO_NAME:-}" ]; then
  current_process_namespace="wsl:$WSL_DISTRO_NAME"
else
  case "$(uname -s)" in
    Linux) current_process_namespace=linux ;;
    Darwin) current_process_namespace=darwin ;;
    *) die "this platform cannot provide a supported process namespace for initializer coordination." ;;
  esac
fi

# Return 0 for live, 1 for definitely dead, and 2 when the namespace/probe cannot
# establish either fact. Callers treat 2 as a fail-closed coordination error.
owner_status() {
  local line tail fields actual pwsh_command probe distro status
  case "$owner_identity_kind" in
    linux-proc-start)
      if [ "$owner_namespace" = "$current_process_namespace" ] &&
        { [ "$current_process_namespace" = linux ] || [[ "$current_process_namespace" = wsl:* ]]; }; then
        [ -e "/proc/$owner_pid/stat" ] || return 1
        line="$(cat "/proc/$owner_pid/stat" 2>/dev/null)" || return 2
        tail="${line##*) }"
        read -ra fields <<< "$tail"
        [ "${#fields[@]}" -ge 20 ] || return 2
        [ "${fields[19]}" = "$owner_identity" ]
        return
      fi
      if [ "$current_process_namespace" = windows ] && [[ "$owner_namespace" = wsl:* ]]; then
        distro="${owner_namespace#wsl:}"
        [ -n "$distro" ] || return 2
        probe='pid='"$owner_pid"'; line=$(cat "/proc/$pid/stat" 2>/dev/null) || exit 3; tail=${line##*) }; set -- $tail; [ "$#" -ge 20 ] || exit 4; printf "%s" "${20}"'
        set +e
        actual="$(wsl.exe --distribution "$distro" --exec bash -c "$probe" 2>/dev/null)"
        status=$?
        set -e
        [ "$status" -ne 3 ] || return 1
        [ "$status" -eq 0 ] || return 2
        [ "$actual" = "$owner_identity" ]
        return
      fi
      return 2 ;;
    ps-lstart)
      [ "$owner_namespace" = darwin ] && [ "$current_process_namespace" = darwin ] || return 2
      set +e
      actual="$(ps -p "$owner_pid" -o lstart= 2>/dev/null)"
      status=$?
      set -e
      [ "$status" -eq 0 ] || return 1
      [ -n "$actual" ] || return 2
      [ "$actual" = "$owner_identity" ] ;;
    dotnet-start-ticks)
      [ "$owner_namespace" = windows ] || return 2
      pwsh_command="$(resolve_windows_pwsh)" || return 2
      set +e
      actual="$("$pwsh_command" -NoProfile -Command "if(Get-Process -Id $owner_pid -ErrorAction SilentlyContinue){(Get-Process -Id $owner_pid).StartTime.ToUniversalTime().Ticks}else{exit 3}" 2>/dev/null)"
      status=$?
      set -e
      [ "$status" -ne 3 ] || return 1
      [ "$status" -eq 0 ] || return 2
      actual="${actual//$'\r'/}"
      [ "$actual" = "$owner_identity" ] ;;
    *) return 2 ;;
  esac
}

get_process_identity() {
  local line tail fields win_pid pwsh_command identity
  if [ "${OS:-}" = Windows_NT ]; then
    win_pid="$(ps -p "$$" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    case "$win_pid" in ''|*[!0-9]*) return 1 ;; esac
    pwsh_command="$(resolve_pwsh)" || return 1
    identity="$("$pwsh_command" -NoProfile -Command "(Get-Process -Id $win_pid -ErrorAction Stop).StartTime.ToUniversalTime().Ticks" 2>/dev/null)" || return 1
    identity="${identity//$'\r'/}"
    printf '%s|%s|%s|%s' "$win_pid" "$current_process_namespace" dotnet-start-ticks "$identity"
  elif [ -r "/proc/$$/stat" ]; then
    line="$(cat "/proc/$$/stat")" || return 1
    tail="${line##*) }"
    read -ra fields <<< "$tail"
    [ "${#fields[@]}" -ge 20 ] || return 1
    printf '%s|%s|%s|%s' "$$" "$current_process_namespace" linux-proc-start "${fields[19]}"
  else
    identity="$(ps -p "$$" -o lstart= 2>/dev/null)" || return 1
    [ -n "$identity" ] || return 1
    printf '%s|%s|%s|%s' "$$" "$current_process_namespace" ps-lstart "$identity"
  fi
}

coordination_process_identity="$(get_process_identity)" || die "could not establish a non-reusable process identity. No files were changed."
IFS='|' read -r coordination_pid coordination_namespace coordination_identity_kind coordination_identity <<< "$coordination_process_identity"
coordination_token="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \r\n')"
[ -n "$coordination_token" ] || die "could not generate a coordination token. No files were changed."

create_coordination_record() {
  local target="$1" temporary="$repo_root/.meta-init-owner.$coordination_token.$RANDOM.tmp"
  {
    printf 'VERSION|2\n'
    printf 'ENGINE|%s\n' "$(encode_path bash)"
    printf 'ROOT|%s\n' "$(encode_path "$coordination_repo_identity")"
    printf 'PID|%s\n' "$(encode_path "$coordination_pid")"
    printf 'NAMESPACE|%s\n' "$(encode_path "$coordination_namespace")"
    printf 'IDENTITY_KIND|%s\n' "$(encode_path "$coordination_identity_kind")"
    printf 'IDENTITY|%s\n' "$(encode_path "$coordination_identity")"
    printf 'TOKEN|%s\n' "$(encode_path "$coordination_token")"
  } > "$temporary"
  chmod 600 "$temporary"
  sync
  if ln -- "$temporary" "$target" 2>/dev/null; then
    rm -f -- "$temporary"
  else
    rm -f -- "$temporary"
    die "another initializer process acquired the repository coordination lock. No files were changed."
  fi
}

acquire_coordination() { create_coordination_record "$coordination_path"; owns_coordination=1; }
acquire_recovery_claim() { create_coordination_record "$coordination_recovery_path"; owns_recovery_claim=1; }

release_recovery_claim() {
  local current_token
  [ "$owns_recovery_claim" -eq 1 ] || return 0
  if [ -f "$coordination_recovery_path" ] && load_coordination_record "$coordination_recovery_path"; then
    current_token="$owner_token"
    if [ "$current_token" = "$coordination_token" ]; then rm -f -- "$coordination_recovery_path"; fi
  fi
  owns_recovery_claim=0
}

release_coordination() {
  local current_token
  [ "$owns_coordination" -eq 1 ] || return 0
  if [ -f "$coordination_path" ] && load_coordination_record "$coordination_path"; then
    current_token="$owner_token"
    if [ "$current_token" = "$coordination_token" ]; then rm -f -- "$coordination_path"; fi
  fi
  owns_coordination=0
}

load_manifest() {
  local type first second third extra decoded index backup_relative settings_extra links
  journal_state=""; journal_root=""; journal_version=""; journal_engine=""
  journal_content_paths=(); journal_content_backups=(); journal_content_stages=(); journal_content_modes=()
  journal_rename_sources=(); journal_rename_destinations=()
  journal_cleanup_paths=(); journal_cleanup_backups=(); journal_cleanup_modes=()
  journal_settings_template=""; journal_settings_destination=""; journal_settings_backup=""; journal_settings_mode=""
  journal_docs=""; journal_deferred=()
  declare -A seen_scalar=() seen_content=() seen_rename=() seen_cleanup=() seen_deferred=() seen_transaction=()
  while IFS='|' read -r type first second third extra <&9; do
    case "$type$first$second$third$extra" in *$'\r'*|*$'\n'*) echo "error: recovery manifest contains a line break in a field." >&2; return 1 ;; esac
    case "$type" in
      VERSION)
        [ -n "$first" ] && [ -z "$second$third$extra" ] && [ -z "${seen_scalar[VERSION]+set}" ] || return 1
        seen_scalar[VERSION]=1; journal_version="$first" ;;
      ENGINE)
        [ -n "$first" ] && [ -z "$second$third$extra" ] && [ -z "${seen_scalar[ENGINE]+set}" ] || return 1
        seen_scalar[ENGINE]=1; journal_engine="$first" ;;
      ROOT)
        [ -n "$first" ] && [ -z "$second$third$extra" ] && [ -z "${seen_scalar[ROOT]+set}" ] || return 1
        seen_scalar[ROOT]=1; journal_root="$(decode_path "$first")" || return 1 ;;
      STATE)
        [ -n "$first" ] && [ -z "$second$third$extra" ] && [ -z "${seen_scalar[STATE]+set}" ] || return 1
        seen_scalar[STATE]=1; journal_state="$first" ;;
      CONTENT)
        [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ] && [ -z "$extra" ] || return 1
        index="${#journal_content_paths[@]}"
        [ "$second" = "content-backup/$index" ] && valid_journal_mode "$third" || return 1
        decoded="$(decode_path "$first")" || return 1
        validate_recovery_file_if_present "$decoded" content || return 1
        [ -z "${seen_content["$decoded"]+set}" ] || return 1
        seen_content["$decoded"]=1
        journal_content_paths+=("$decoded")
        journal_content_backups+=("$transaction_root/$second")
        journal_content_stages+=("$transaction_root/content-stage/$index")
        journal_content_modes+=("$third")
        [ -z "${seen_transaction["$transaction_root/$second"]+set}" ] || return 1
        seen_transaction["$transaction_root/$second"]=1
        seen_transaction["$transaction_root/content-stage/$index"]=1 ;;
      RENAME)
        [ -n "$first" ] && [ -n "$second" ] && [ -z "$third$extra" ] || return 1
        decoded="$(decode_path "$first")" || return 1
        validate_recovery_repo_path "$decoded" 'rename source' || return 1
        [ -z "${seen_rename["$decoded"]+set}" ] || return 1
        seen_rename["$decoded"]=1
        journal_rename_sources+=("$decoded")
        decoded="$(decode_path "$second")" || return 1
        validate_recovery_repo_path "$decoded" 'rename destination' || return 1
        [ -z "${seen_rename["$decoded"]+set}" ] || return 1
        seen_rename["$decoded"]=1
        journal_rename_destinations+=("$decoded") ;;
      CLEANUP)
        [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ] && [ -z "$extra" ] || return 1
        index="${#journal_cleanup_paths[@]}"
        [ "$second" = "cleanup-backup/$index" ] && valid_journal_mode "$third" || return 1
        decoded="$(decode_path "$first")" || return 1
        validate_recovery_file_if_present "$decoded" cleanup || return 1
        [ -z "${seen_cleanup["$decoded"]+set}" ] || return 1
        seen_cleanup["$decoded"]=1
        journal_cleanup_paths+=("$decoded")
        journal_cleanup_backups+=("$transaction_root/$second")
        journal_cleanup_modes+=("$third")
        [ -z "${seen_transaction["$transaction_root/$second"]+set}" ] || return 1
        seen_transaction["$transaction_root/$second"]=1 ;;
      SETTINGS)
        [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ] && [ -z "$extra" ] && [ -z "${seen_scalar[SETTINGS]+set}" ] || return 1
        seen_scalar[SETTINGS]=1
        journal_settings_template="$(decode_path "$first")" || return 1
        journal_settings_destination="$(decode_path "$second")" || return 1
        validate_recovery_file_if_present "$journal_settings_template" 'settings template' 1 || return 1
        validate_recovery_file_if_present "$journal_settings_destination" 'settings destination' 1 || return 1
        IFS=',' read -r backup_relative journal_settings_mode settings_extra <<< "$third"
        [ "$backup_relative" = settings-template ] && [ -z "$settings_extra" ] && valid_journal_mode "$journal_settings_mode" || return 1
        journal_settings_backup="$transaction_root/$backup_relative"
        [ -z "${seen_transaction["$journal_settings_backup"]+set}" ] || return 1
        seen_transaction["$journal_settings_backup"]=1 ;;
      DOCS)
        [ -n "$first" ] && [ -z "$second$third$extra" ] && [ -z "${seen_scalar[DOCS]+set}" ] || return 1
        seen_scalar[DOCS]=1; journal_docs="$(decode_path "$first")" || return 1
        validate_recovery_repo_path "$journal_docs" 'docs directory' || return 1
        [ "$journal_docs" = "$repo_root/docs" ] || return 1 ;;
      DEFERRED)
        [ -n "$first" ] && [ -z "$second$third$extra" ] || return 1
        decoded="$(decode_path "$first")" || return 1
        validate_recovery_file_if_present "$decoded" 'deferred cleanup' || return 1
        [ -z "${seen_deferred["$decoded"]+set}" ] || return 1
        seen_deferred["$decoded"]=1; journal_deferred+=("$decoded") ;;
      *) echo "error: recovery manifest contains unknown record '$type'." >&2; return 1 ;;
    esac
  done 9< "$manifest_path"
  [ "${seen_scalar[VERSION]:-}" = 1 ] && [ "$journal_version" = 1 ] || { echo "error: recovery manifest has an unsupported or missing VERSION." >&2; return 1; }
  [ "${seen_scalar[ENGINE]:-}" = 1 ] && [ "$journal_engine" = bash ] || { echo "error: recovery manifest has the wrong or missing ENGINE." >&2; return 1; }
  [ "${seen_scalar[ROOT]:-}" = 1 ] && [ "$journal_root" = "$repo_root" ] || { echo "error: recovery journal '$transaction_root' belongs to a different repository." >&2; return 1; }
  [ "${seen_scalar[STATE]:-}" = 1 ] && { [ "$journal_state" = prepared ] || [ "$journal_state" = committed ]; } || { echo "error: recovery manifest has an unsupported or missing STATE." >&2; return 1; }

  for ((index=0; index<${#journal_content_backups[@]}; index++)); do
    [ -f "${journal_content_backups[$index]}" ] && [ ! -L "${journal_content_backups[$index]}" ] || return 1
    [ -f "${journal_content_stages[$index]}" ] && [ ! -L "${journal_content_stages[$index]}" ] || return 1
  done
  for backup_relative in "${journal_cleanup_backups[@]}"; do
    [ -f "$backup_relative" ] && [ ! -L "$backup_relative" ] || return 1
  done
  if [ -n "$journal_settings_backup" ]; then
    [ -f "$journal_settings_backup" ] && [ ! -L "$journal_settings_backup" ] || return 1
    if [ -e "$journal_settings_template" ] && [ -e "$journal_settings_destination" ]; then
      [ "$journal_settings_template" -ef "$journal_settings_destination" ] || return 1
      links="$(stat_links "$journal_settings_template")" || return 1
      [ "$links" -eq 2 ] || return 1
    else
      validate_recovery_file_if_present "$journal_settings_template" 'settings template' || return 1
      validate_recovery_file_if_present "$journal_settings_destination" 'settings destination' || return 1
    fi
  fi
  for decoded in "${journal_deferred[@]}"; do
    [ -n "${seen_cleanup["$decoded"]+set}" ] || return 1
  done
}

restore_transaction() {
  local failed=0 index path source destination backup mode actual_mode
  load_manifest || {
    echo "error: recovery manifest is malformed. Refusing unsafe recovery." >&2
    return 1
  }
  [ "$journal_root" = "$repo_root" ] || {
    echo "error: recovery journal '$transaction_root' belongs to a different repository." >&2
    return 1
  }
  set +e
  if [ "$journal_state" = committed ]; then
    for path in "${journal_deferred[@]}"; do
      if validate_recovery_file_if_present "$path" 'deferred cleanup'; then rm -f -- "$path" || failed=1
      else failed=1
      fi
    done
  elif [ "$journal_state" = prepared ]; then
    for ((index=0; index<${#journal_cleanup_paths[@]}; index++)); do
      path="${journal_cleanup_paths[$index]}"; backup="${journal_cleanup_backups[$index]}"
      if ! { validate_recovery_file_if_present "$path" cleanup && mkdir -p "$(dirname "$path")" &&
        cp -p -- "$backup" "$path" && chmod "${journal_cleanup_modes[$index]}" "$path"; }; then
        echo "error: could not restore cleanup path '$path'." >&2
        failed=1
      fi
    done
    if [ -n "$journal_docs" ]; then mkdir -p "$journal_docs" || failed=1; fi
    if [ -n "$journal_settings_template" ]; then
      if [ -e "$journal_settings_destination" ] || [ -L "$journal_settings_destination" ]; then
        if ! cmp -s -- "$journal_settings_destination" "$journal_settings_backup"; then
          failed=1
        elif [ "${META_INIT_TEST_FAIL_ROLLBACK_SETTINGS_REMOVE:-}" = 1 ]; then
          failed=1
        else
          rm -f -- "$journal_settings_destination" || failed=1
          if [ -e "$journal_settings_destination" ] || [ -L "$journal_settings_destination" ]; then failed=1; fi
        fi
      fi
      if ! { cp -p -- "$journal_settings_backup" "$journal_settings_template" && chmod "$journal_settings_mode" "$journal_settings_template"; }; then
        echo "error: could not restore settings template '$journal_settings_template'." >&2
        failed=1
      fi
    fi
    for ((index=${#journal_rename_sources[@]}-1; index>=0; index--)); do
      source="${journal_rename_sources[$index]}"; destination="${journal_rename_destinations[$index]}"
      if ! validate_recovery_repo_path "$source" 'rename source' ||
        ! validate_recovery_repo_path "$destination" 'rename destination'; then
        failed=1
      elif { [ -e "$source" ] || [ -L "$source" ]; } && { [ -e "$destination" ] || [ -L "$destination" ]; }; then
        failed=1
      elif [ -e "$destination" ] || [ -L "$destination" ]; then
        mv -- "$destination" "$source" || failed=1
      elif [ ! -e "$source" ] && [ ! -L "$source" ]; then
        failed=1
      fi
    done
    for ((index=0; index<${#journal_content_paths[@]}; index++)); do
      path="${journal_content_paths[$index]}"; backup="${journal_content_backups[$index]}"; mode="${journal_content_modes[$index]}"
      if ! { validate_recovery_file_if_present "$path" content && cp -p -- "$backup" "$path" && chmod "$mode" "$path"; }; then
        echo "error: could not restore content path '$path'." >&2
        failed=1
      fi
    done
    for ((index=0; index<${#journal_content_paths[@]}; index++)); do
      path="${journal_content_paths[$index]}"; backup="${journal_content_backups[$index]}"; mode="${journal_content_modes[$index]}"
      if ! cmp -s -- "$path" "$backup"; then
        echo "error: restored content differs from its backup at '$path'." >&2
        failed=1
      fi
      if [ "${OS:-}" != Windows_NT ]; then
        actual_mode="$(stat_mode "$path" 2>/dev/null)"
        if [ "$actual_mode" != "$mode" ]; then
          echo "error: restored content mode at '$path' is '$actual_mode', expected '$mode'." >&2
          failed=1
        fi
      fi
    done
    for ((index=0; index<${#journal_cleanup_paths[@]}; index++)); do
      path="${journal_cleanup_paths[$index]}"; backup="${journal_cleanup_backups[$index]}"; mode="${journal_cleanup_modes[$index]}"
      if ! cmp -s -- "$path" "$backup"; then
        echo "error: restored cleanup path differs from its backup at '$path'." >&2
        failed=1
      fi
      if [ "${OS:-}" != Windows_NT ]; then
        actual_mode="$(stat_mode "$path" 2>/dev/null)"
        if [ "$actual_mode" != "$mode" ]; then
          echo "error: restored cleanup mode at '$path' is '$actual_mode', expected '$mode'." >&2
          failed=1
        fi
      fi
    done
    if [ -n "$journal_settings_template" ]; then
      { [ ! -e "$journal_settings_destination" ] && [ ! -L "$journal_settings_destination" ]; } || failed=1
      cmp -s -- "$journal_settings_template" "$journal_settings_backup" || failed=1
    fi
  else
    failed=1
  fi
  set -e
  if [ "$failed" -ne 0 ]; then
    echo "error: automatic recovery was incomplete; private backups remain at '$transaction_root'." >&2
    return 1
  fi
  assert_transaction_root_entry || return 1
  rm -rf -- "$transaction_root"
  echo "    Recovered an interrupted initialization transaction."
}

recover_native_transaction() {
  local allow_empty_transaction="${1:-0}"
  if [ -e "$transaction_root" ] || [ -L "$transaction_root" ]; then
    assert_private_transaction_tree || return 1
    if [ -f "$manifest_path" ] && [ ! -L "$manifest_path" ]; then restore_transaction || return 1
    elif [ "$allow_empty_transaction" -eq 1 ]; then
      rm -rf -- "$transaction_root" || return 1
      echo "    Recovered an interrupted preflight transaction."
    else
      echo "error: transaction root '$transaction_root' has no regular manifest. Refusing unsafe recovery." >&2
      return 1
    fi
  fi
}

invoke_pwsh_recovery_only() {
  local pwsh_command
  [ -f "$sibling_ps1" ] && [ ! -L "$sibling_ps1" ] || {
    echo "error: the PowerShell initializer required for cross-engine recovery is unavailable." >&2
    return 1
  }
  pwsh_command="$(resolve_pwsh)" || {
    echo "error: pwsh is required to recover the interrupted PowerShell transaction." >&2
    return 1
  }
  (
    unset META_INIT_TEST_FAIL_PHASE META_INIT_TEST_CRASH_PHASE
    unset META_INIT_TEST_FAIL_RENAME_SOURCE META_INIT_TEST_CRASH_RENAME_SOURCE
    unset META_INIT_TEST_HOLD_AFTER_LOCK_SECONDS META_INIT_TEST_HOLD_PREFLIGHT_SECONDS
    unset META_INIT_TEST_PREFLIGHT_MARKER META_INIT_TEST_SKIP_CONTENT_PATH
    export META_INIT_RECOVER_ONLY=1
    export META_INIT_RECOVERY_PARENT_TOKEN="$coordination_token"
    cd "$repo_root"
    "$pwsh_command" -NoProfile -File ./scripts/init.ps1 \
      -ProjectName "$project_name" -KeepScript -InternalRecoverOnly \
      -InternalRecoveryParentToken "$coordination_token" -InternalAllowEmptyTransaction
  )
}

enter_coordination_and_recover() {
  local existing_engine="" existing_token="" status confirmed_token
  if [ -e "$coordination_recovery_path" ] || [ -L "$coordination_recovery_path" ]; then
    [ -f "$coordination_recovery_path" ] && [ ! -L "$coordination_recovery_path" ] ||
      die "the initializer recovery claim is not a regular file. Refusing unsafe recovery."
    load_coordination_record "$coordination_recovery_path" ||
      die "the initializer recovery claim is malformed. Refusing unsafe recovery."
    if owner_status; then
      die "another initializer process owns repository recovery. No files were changed."
    else
      status=$?
      [ "$status" -eq 1 ] || die "the initializer recovery owner cannot be checked in its process namespace. Refusing unsafe recovery."
    fi
    confirmed_token="$owner_token"
    load_coordination_record "$coordination_recovery_path" ||
      die "the initializer recovery claim changed while being inspected. Refusing unsafe recovery."
    [ "$owner_token" = "$confirmed_token" ] ||
      die "the initializer recovery claim changed while being inspected. Refusing unsafe recovery."
    rm -f -- "$coordination_recovery_path"
  fi

  if [ -e "$coordination_path" ] || [ -L "$coordination_path" ]; then
    [ -f "$coordination_path" ] && [ ! -L "$coordination_path" ] ||
      die "the initializer coordination owner is not a regular file. Refusing unsafe recovery."
    load_coordination_record "$coordination_path" ||
      die "the initializer coordination owner record is malformed. Refusing unsafe recovery."
    if owner_status; then
      die "another initializer process owns the active repository transaction. No files were changed."
    else
      status=$?
      [ "$status" -eq 1 ] || die "the initializer owner cannot be checked in its process namespace. Refusing unsafe recovery."
    fi
    existing_engine="$owner_engine"
    existing_token="$owner_token"
  fi

  if [ -z "$existing_token" ] && [ ! -e "$transaction_root" ] && [ ! -L "$transaction_root" ]; then
    acquire_coordination
    return
  fi

  acquire_recovery_claim
  if [ -n "$existing_token" ]; then
    if [ -e "$coordination_path" ] || [ -L "$coordination_path" ]; then
      load_coordination_record "$coordination_path" ||
        die "the initializer coordination owner changed during recovery acquisition. Refusing unsafe recovery."
      [ "$owner_token" = "$existing_token" ] ||
        die "the initializer coordination owner changed during recovery acquisition. Refusing unsafe recovery."
      if owner_status; then
        die "another initializer process owns the active repository transaction. No files were changed."
      else
        status=$?
        [ "$status" -eq 1 ] || die "the initializer owner cannot be checked in its process namespace. Refusing unsafe recovery."
      fi
      rm -f -- "$coordination_path"
    fi
  elif [ -e "$coordination_path" ] || [ -L "$coordination_path" ]; then
    die "another initializer process acquired the repository coordination lock. No files were changed."
  fi

  acquire_coordination
  if [ "$existing_engine" = pwsh ]; then invoke_pwsh_recovery_only || return 2; fi
  if [ "$existing_engine" = bash ]; then recover_native_transaction 1 || return 2
  else recover_native_transaction 0 || return 2
  fi
  release_recovery_claim
}

if [ -z "$year" ]; then year="$(date +%Y)"; fi

if [ "$recovery_only" = 1 ]; then
  parent_token="$internal_recovery_parent_token"
  [ -n "$parent_token" ] || die "recovery-only mode requires an active parent coordination token."
  [ -f "$coordination_path" ] && [ ! -L "$coordination_path" ] ||
    die "recovery-only mode could not find the active parent coordination owner."
  load_coordination_record "$coordination_path" || die "recovery-only mode found a malformed parent coordination owner."
  [ "$owner_token" = "$parent_token" ] || die "recovery-only mode found the wrong parent coordination owner."
  if ! owner_status; then
    die "recovery-only mode could not validate the active parent coordination owner."
  fi
  recover_native_transaction "$internal_allow_empty_transaction" || exit 2
  exit 0
fi

transaction_active=0
owns_transaction=0
rollback() {
  transaction_active=0
  if restore_transaction; then
    owns_transaction=0
    echo "error: initialization failed; the original tree was restored." >&2
    return 0
  fi
  echo "error: initialization failed and rollback was incomplete; backups remain at '$transaction_root'." >&2
  return 1
}

on_exit() {
  local exit_code=$?
  trap - EXIT
  if [ "$transaction_active" -eq 1 ]; then
    rollback || exit_code=2
  elif [ "$owns_transaction" -eq 1 ] && [ -d "$transaction_root" ]; then
    if assert_transaction_root_entry; then rm -rf -- "$transaction_root"
    else exit_code=2
    fi
  fi
  release_recovery_claim
  release_coordination
  exit "$exit_code"
}
trap on_exit EXIT

umask 077
enter_coordination_and_recover

# Repository-derived defaults and every source-tree snapshot are taken only after
# this process owns the cross-engine boundary and recovery has completed.
if [ -z "$author" ]; then
  author="$(git config user.name 2>/dev/null || true)"
  [ -n "$author" ] || author="Your Name"
fi
if [ -z "$author_email" ]; then
  author_email="$(git config user.email 2>/dev/null || true)"
  [ -n "$author_email" ] || author_email="you@example.com"
fi
[ -n "$github_owner" ] || github_owner="your-org"
[ -n "$description" ] || description="TODO: project description"
case "$author" in *$'\r'*|*$'\n'*) die "invalid --author: line breaks are not allowed. No files were changed." ;; esac
case "$author_email" in *$'\r'*|*$'\n'*) die "invalid --author-email: line breaks are not allowed. No files were changed." ;; esac
if [[ ! "$github_owner" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
  die "invalid --github-owner. Use 1-39 letters, digits, or hyphens, with no leading or trailing hyphen. No files were changed."
fi
project_x="$(xml_escape "$project_name")"
author_x="$(xml_escape "$author")"
author_email_x="$(xml_escape "$author_email")"
owner_x="$(xml_escape "$github_owner")"
desc_x="$(xml_escape "$description")"
year_x="$(xml_escape "$year")"
author_b64="$(printf '%s' "$author" | base64 | tr -d '\r\n')"
author_email_b64="$(printf '%s' "$author_email" | base64 | tr -d '\r\n')"
has_existing_claude_settings=0
if [ -e "$claude_settings" ] || [ -L "$claude_settings" ]; then has_existing_claude_settings=1; fi

if ! mkdir -- "$transaction_root"; then
  release_coordination
  die "another initializer process acquired '$transaction_root'. No files were changed."
fi
owns_transaction=1
chmod 700 "$transaction_root"
if [ "${OS:-}" = Windows_NT ]; then
  set_private_windows_transaction_root || die "could not restrict transaction directory '$transaction_root' to the current Windows identity. No files were changed."
else
  assert_private_posix_transaction_item "$transaction_root" 700 || die "could not establish a private transaction directory at '$transaction_root'. No files were changed."
fi

# Preflight every path mutation before the source tree is changed. Enumeration is
# captured in a real file so a traversal error cannot be hidden by process substitution.
[ -f "$self" ] && [ ! -L "$self" ] || die "the Bash initializer is not available as a regular file. No files were changed."
hold_seconds="${META_INIT_TEST_HOLD_PREFLIGHT_SECONDS:-}"
if [ -n "$hold_seconds" ]; then
  case "$hold_seconds" in *[!0-9]*|'') die "META_INIT_TEST_HOLD_PREFLIGHT_SECONDS must be an integer from 1 through 60." ;; esac
  [ "$hold_seconds" -ge 1 ] && [ "$hold_seconds" -le 60 ] || die "META_INIT_TEST_HOLD_PREFLIGHT_SECONDS must be an integer from 1 through 60."
  if [ -n "${META_INIT_TEST_PREFLIGHT_MARKER:-}" ]; then
    printf '%s' preflight > "$META_INIT_TEST_PREFLIGHT_MARKER"
  fi
  sleep "$hold_seconds"
fi
all_entries_file="$transaction_root/all-entries"
if ! find "$repo_root" \( -name .git -o -name .jj -o -name .work -o -name .inbox -o -name bin -o -name obj \) -prune -o -print0 > "$all_entries_file"; then
  die "source-tree enumeration failed. No files were changed."
fi

content_candidates=()
all_entries=()
while IFS= read -r -d '' item <&9; do
  [ "$item" != "$repo_root" ] || continue
  is_excluded "$item" && continue
  validate_owned_path "$item" source-tree "$([ -f "$item" ] && [ ! -L "$item" ] && printf 1 || printf 0)"
  all_entries+=("$item")
  if [ -f "$item" ] && [ ! -L "$item" ]; then content_candidates+=("$item"); fi
done 9< "$all_entries_file"

rename_sources=()
rename_destinations=()
rename_old_names=()
rename_new_names=()
declare -A planned_destinations=()
rename_candidates_file="$transaction_root/rename-candidates"
: > "$rename_candidates_file"
for item in "${all_entries[@]}"; do
  base="$(basename "$item")"
  case "$base" in *'__ProjectName__'*) ;; *) continue ;; esac
  relative="${item#"$repo_root"/}"
  separators="${relative//[^\/]/}"
  printf '%08d|%s\n' "${#separators}" "$(encode_path "$item")" >> "$rename_candidates_file"
done
if ! LC_ALL=C sort -t '|' -k1,1nr -k2,2 "$rename_candidates_file" -o "$rename_candidates_file"; then
  die "could not order the rename plan safely. No files were changed."
fi
while IFS='|' read -r _depth encoded_item extra <&9; do
  [ -n "$encoded_item" ] && [ -z "$extra" ] || die "the rename plan is malformed. No files were changed."
  item="$(decode_path "$encoded_item")" || die "the rename plan contains an invalid path. No files were changed."
  base="$(basename "$item")"
  dir="$(dirname "$item")"
  newbase="${base//__ProjectName__/$project_name}"
  destination="$dir/$newbase"
  if [ -n "${planned_destinations["$destination"]+set}" ]; then
    die "multiple template paths would be renamed to '$destination'. No files were changed."
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    die "cannot rename '$item' because '$destination' already exists. No files were changed."
  fi
  planned_destinations["$destination"]=1
  rename_sources+=("$item")
  rename_destinations+=("$destination")
  rename_old_names+=("$base")
  rename_new_names+=("$newbase")
done 9< "$rename_candidates_file"

settings_will_activate=0
if [ "$has_existing_claude_settings" -eq 0 ] && { [ -e "$claude_template" ] || [ -L "$claude_template" ]; }; then
  [ -f "$claude_template" ] || die "the settings template is not a regular file. No files were changed."
  validate_owned_path "$claude_template" settings-template 1
  settings_will_activate=1
fi

cleanup_sources=()
script_cleanup_sources=()
deferred_cleanup=()
for path in "$repo_root/TEMPLATE.md" "$repo_root/docs/AGENT-INIT-GUIDE.md" \
  "$repo_root/tests/init-metadata.tests.ps1"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] || die "cannot remove '$path' because it is not a regular file. No files were changed."
    validate_owned_path "$path" cleanup 1
    cleanup_sources+=("$path")
  fi
done
if [ "$keep_script" -ne 1 ]; then
  if [ -e "$sibling_ps1" ] || [ -L "$sibling_ps1" ]; then
    [ -f "$sibling_ps1" ] || die "cannot remove '$sibling_ps1' because it is not a regular file. No files were changed."
    validate_owned_path "$sibling_ps1" cleanup 1
    script_cleanup_sources+=("$sibling_ps1")
  fi
  if [ -e "$self" ] || [ -L "$self" ]; then
    [ -f "$self" ] || die "cannot remove '$self' because it is not a regular file. No files were changed."
    validate_owned_path "$self" cleanup 1
    deferred_cleanup+=("$self")
  fi
fi
backup_sources=("${cleanup_sources[@]}" "${script_cleanup_sources[@]}" "${deferred_cleanup[@]}")
content_files=()
content_backups=()
content_staged=()
cleanup_backups=()

mkdir -p "$transaction_root/content-backup" "$transaction_root/content-stage" \
  "$transaction_root/cleanup-backup"
chmod 700 "$transaction_root/content-backup" "$transaction_root/content-stage" \
  "$transaction_root/cleanup-backup"

# Stage all rewritten contents and byte-preserving backups outside the repository.
changed=0
content_modes=()
for file in "${content_candidates[@]}"; do
  case "$file" in
    "$self"|"$sibling_ps1"|"$claude_settings") continue ;;
    *.snk|*.pfx|*.png|*.jpg|*.jpeg|*.gif|*.ico|*.zip|*.jar) continue ;;
  esac
  is_supported_utf8_file "$file" || continue
  LC_ALL=C grep -Eq "$token_pattern" -- "$file" || continue
  case "$file" in
    *.csproj|*.fsproj|*.props|*.targets|*.slnx|*.config) mode=xml ;;
    *) mode=raw ;;
  esac
  candidate="$transaction_root/content-stage/.candidate"
  replace_tokens_file "$file" "$candidate" "$mode" ||
    die "could not safely rewrite '$file'. No files were changed."
  if cmp -s -- "$candidate" "$file"; then
    rm -f -- "$candidate"
    continue
  fi
  index="${#content_files[@]}"
  backup="$transaction_root/content-backup/$index"
  staged="$transaction_root/content-stage/$index"
  original_mode="$(stat_mode "$file")" || die "could not read permissions for '$file'. No files were changed."
  cp -p -- "$file" "$backup"
  cp -p -- "$file" "$staged"
  cat -- "$candidate" > "$staged"
  rm -f -- "$candidate"
  chmod 600 "$backup" "$staged"
  content_files+=("$file")
  content_backups+=("$backup")
  content_staged+=("$staged")
  content_modes+=("$original_mode")
  changed=$((changed + 1))
done

cleanup_modes=()
for ((index=0; index<${#backup_sources[@]}; index++)); do
  backup="$transaction_root/cleanup-backup/$index"
  original_mode="$(stat_mode "${backup_sources[$index]}")" || die "could not read cleanup permissions. No files were changed."
  cp -p -- "${backup_sources[$index]}" "$backup"
  chmod 600 "$backup"
  cleanup_backups+=("$backup")
  cleanup_modes+=("$original_mode")
done
settings_mode=""
if [ "$settings_will_activate" -eq 1 ]; then
  settings_mode="$(stat_mode "$claude_template")" || die "could not read settings permissions. No files were changed."
  cp -p -- "$claude_template" "$transaction_root/settings-template"
  chmod 600 "$transaction_root/settings-template"
fi

write_manifest() {
  local state="$1" index temporary="$manifest_path.new"
  {
    printf 'VERSION|1\nENGINE|bash\nROOT|%s\nSTATE|%s\n' "$(encode_path "$repo_root")" "$state"
    for ((index=0; index<${#content_files[@]}; index++)); do
      printf 'CONTENT|%s|content-backup/%s|%s\n' "$(encode_path "${content_files[$index]}")" "$index" "${content_modes[$index]}"
    done
    for ((index=0; index<${#rename_sources[@]}; index++)); do
      printf 'RENAME|%s|%s\n' "$(encode_path "${rename_sources[$index]}")" "$(encode_path "${rename_destinations[$index]}")"
    done
    if [ "$settings_will_activate" -eq 1 ]; then
      printf 'SETTINGS|%s|%s|settings-template,%s\n' "$(encode_path "$claude_template")" "$(encode_path "$claude_settings")" "$settings_mode"
    fi
    for ((index=0; index<${#backup_sources[@]}; index++)); do
      printf 'CLEANUP|%s|cleanup-backup/%s|%s\n' "$(encode_path "${backup_sources[$index]}")" "$index" "${cleanup_modes[$index]}"
    done
    if [ -d "$repo_root/docs" ]; then printf 'DOCS|%s\n' "$(encode_path "$repo_root/docs")"; fi
    for path in "${deferred_cleanup[@]}"; do printf 'DEFERRED|%s\n' "$(encode_path "$path")"; done
  } > "$temporary"
  chmod 600 "$temporary"
  sync
  mv -f -- "$temporary" "$manifest_path"
  sync
}

# Every rollback record and backup is durable before the first source-tree write.
write_manifest prepared
assert_owned_transaction_tree || die "the prepared transaction tree is not private. No source files were changed."

echo "==> Initializing template as '$project_name'"
transaction_active=1

# 1) Commit staged content replacements.
for ((index=0; index<${#content_files[@]}; index++)); do
  chmod "${content_modes[$index]}" "${content_staged[$index]}"
  relative_path="${content_files[$index]#"$repo_root"/}"
  if [ "${META_INIT_TEST_SKIP_CONTENT_PATH:-}" != "$relative_path" ]; then
    cp -p -- "${content_staged[$index]}" "${content_files[$index]}"
  fi
  cmp -s -- "${content_staged[$index]}" "${content_files[$index]}" ||
    die "staged content was not applied exactly to '$relative_path'."
  [ "$(stat_mode "${content_files[$index]}")" = "${content_modes[$index]}" ] || die "metadata was not preserved for '${content_files[$index]}'."
  controlled_crash content
done
echo "    Updated contents in $changed file(s)."
controlled_failure content

# 2) Rename token-bearing paths, deepest first.
for ((index=0; index<${#rename_sources[@]}; index++)); do
  mv -- "${rename_sources[$index]}" "${rename_destinations[$index]}"
  echo "    Renamed ${rename_old_names[$index]} -> ${rename_new_names[$index]}"
  controlled_crash rename "${rename_old_names[$index]}"
  controlled_failure rename "${rename_old_names[$index]}"
done
controlled_failure rename

# META(%%): language-specific post-processing here if needed (e.g. Kotlin package-dir move).

# 3) Activate the Claude Code shared settings without overwriting a concurrent destination.
if [ "$has_existing_claude_settings" -eq 1 ]; then
  if [ -f "$claude_template" ]; then
    echo "    Kept existing .claude/settings.json unchanged; left .claude/settings.json.template in place."
  else
    echo "    Kept existing .claude/settings.json unchanged; no settings template needed activation."
  fi
elif [ "$settings_will_activate" -eq 1 ]; then
  if ln "$claude_template" "$claude_settings" 2>/dev/null; then
    controlled_crash settings
    rm -- "$claude_template"
    echo "    Activated .claude/settings.json"
  elif [ -e "$claude_settings" ] || [ -L "$claude_settings" ]; then
    die "a .claude/settings.json destination appeared after preflight."
  else
    die "could not activate .claude/settings.json without overwriting a destination."
  fi
fi
controlled_failure settings

# 4) Remove template-only files only after each one has an external backup.
for path in "${cleanup_sources[@]}"; do
  rm -f -- "$path"
  case "$path" in
    "$repo_root/TEMPLATE.md"|"$repo_root/docs/AGENT-INIT-GUIDE.md"|"$repo_root/tests/init-metadata.tests.ps1")
      echo "    Removed ${path#"$repo_root"/}" ;;
  esac
  controlled_crash cleanup
done
if [ -d "$repo_root/docs" ] && rmdir "$repo_root/docs" 2>/dev/null; then
  echo "    Removed docs"
fi
controlled_failure cleanup

# 5) Remove the non-running initializer while this script can still recover the
# transaction. The running script is deleted only after the journal is committed.
for path in "${script_cleanup_sources[@]}"; do
  rm -f -- "$path"
  controlled_crash scripts
done
controlled_failure scripts

write_manifest committed
for path in "${deferred_cleanup[@]}"; do rm -f -- "$path"; done
transaction_active=0
if ! assert_transaction_root_entry || ! rm -rf -- "$transaction_root"; then
  echo "warning: initialization succeeded, but temporary backups could not be removed: $transaction_root" >&2
fi
owns_transaction=0
release_coordination
trap - EXIT

echo ""
echo "Done. Next steps:"
# META(%%): fill these with your build/test commands and publishing note.
echo "  1. %%BuildCmd%%"
echo "  2. %%TestCmd%%"
echo "  3. Review LICENSE (author/year) and the package metadata in %%ManifestFile%%."
echo "  4. Publishing: add the %%PublishSecret%% repo secret, or delete"
echo "     .github/workflows/release.yml and the packaging metadata."
echo "  5. Commit the initialized project."
