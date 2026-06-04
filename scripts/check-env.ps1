#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Checks this machine can build and test the generated %%LangName%% project
    before you run scripts/init.ps1.

.DESCRIPTION
    META(%%): GENERATED template's environment-readiness check — runs BEFORE init.
    The skeleton ($problems array, soft git note, ready/not-ready output) is
    language-neutral — keep it. Fill the marked language-specific parts: the
    required-tool check(s) (and any version floor) and the per-OS install commands.
    POSIX counterpart is check-env.sh. See META-AUTHORING.md.

    Verifies the %%LangName%% toolchain (%%BuildTool%%) is on PATH so %%BuildCmd%%
    and %%TestCmd%% can run. Prints "Environment ready" and exits 0 on success; if a
    required tool is missing it prints per-OS install commands and exits 1 — install
    it, then re-run:

        pwsh ./scripts/check-env.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$problems = @()

Write-Host "==> Checking environment for %%LangName%% development" -ForegroundColor Cyan

# META(%%): confirm every tool the build/test needs is on PATH, and — where the
# template pins a version (global.json / rust-toolchain.toml / the Gradle launcher
# JDK) — that the installed one meets the floor. The build driver below is only a
# baseline; replace/extend it with the compiler / runtime / version checks your
# language needs (copy the sibling's shape: rust → cargo + rustc; .NET → a dotnet
# SDK whose major matches global.json; Kotlin → a launcher JDK >= 17, since Gradle
# runs through the wrapper rather than a PATH `gradle`).
if (-not (Get-Command %%BuildTool%% -ErrorAction SilentlyContinue)) {
    $problems += "the %%LangName%% toolchain ('%%BuildTool%%' is not on PATH)"
}

# Soft: git drives init's author/email defaults and the VCS workflow, but is not
# required to build.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "    note: git is not on PATH — init falls back to placeholder author/email." -ForegroundColor DarkGray
}

if ($problems.Count -eq 0) {
    Write-Host ""
    Write-Host "Environment ready. Next: pwsh ./scripts/init.ps1 -ProjectName ..." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Environment NOT ready. Missing:" -ForegroundColor Red
foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
Write-Host ""
# META(%%): replace the three lines below with the real per-OS install commands for
# the %%LangName%% toolchain (copy the shape from the sibling: winget / brew / the
# official installer or a docs URL).
Write-Host "Install the %%LangName%% toolchain, then re-run this check:" -ForegroundColor Yellow
Write-Host "  Windows : TODO(meta): winget/choco install command"
Write-Host "  macOS   : TODO(meta): brew install command"
Write-Host "  Linux   : TODO(meta): apt/dnf or official-installer command (or a docs URL)"
exit 1
