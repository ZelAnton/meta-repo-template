#!/usr/bin/env bash
#
# META(%%): GENERATED template's environment-readiness check — runs BEFORE init.sh
# to confirm this machine can build and test %%LangName%%. The skeleton (problems
# array, soft git note, ready/not-ready output, --help) is language-neutral — keep
# it. Fill the marked language-specific parts: the required-tool check(s) (and any
# version floor) and the per-OS install commands. POSIX counterpart of
# check-env.ps1. See META-AUTHORING.md.
#
# Verifies the %%LangName%% toolchain (%%BuildTool%%) is on PATH so %%BuildCmd%% and
# %%TestCmd%% can run. Exits 0 when ready; if a required tool is missing it prints
# per-OS install commands and exits 1 — install it, then re-run.
#
# Usage: bash ./scripts/check-env.sh

set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,14p' "$0"; exit 0 ;; esac

problems=()
echo "==> Checking environment for %%LangName%% development"

# META(%%): confirm every tool the build/test needs is on PATH, and — where the
# template pins a version (global.json / rust-toolchain.toml / the Gradle launcher
# JDK) — that the installed one meets the floor. The build driver below is only a
# baseline; replace/extend it with the compiler / runtime / version checks your
# language needs (copy the sibling's shape: rust → cargo + rustc; .NET → a dotnet
# SDK whose major matches global.json; Kotlin → a launcher JDK >= 17, since Gradle
# runs through the wrapper rather than a PATH `gradle`).
command -v %%BuildTool%% >/dev/null 2>&1 || \
  problems+=("the %%LangName%% toolchain ('%%BuildTool%%' is not on PATH)")

# Soft: git drives init's author/email defaults and the VCS workflow, but is not
# required to build.
command -v git >/dev/null 2>&1 || \
  echo "    note: git is not on PATH — init falls back to placeholder author/email."

if [ ${#problems[@]} -eq 0 ]; then
  echo
  echo "Environment ready. Next: bash ./scripts/init.sh --project-name ..."
  exit 0
fi

echo
echo "Environment NOT ready. Missing:"
for p in "${problems[@]}"; do echo "  - $p"; done
echo
# META(%%): replace the three lines below with the real per-OS install commands for
# the %%LangName%% toolchain (copy the shape from the sibling: winget / brew / the
# official installer or a docs URL).
echo "Install the %%LangName%% toolchain, then re-run this check:"
echo "  Windows : TODO(meta): winget/choco install command"
echo "  macOS   : TODO(meta): brew install command"
echo "  Linux   : TODO(meta): apt/dnf or official-installer command (or a docs URL)"
exit 1
