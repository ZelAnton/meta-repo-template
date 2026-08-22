#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initializes this template into a concrete %%LangName%% project.

.DESCRIPTION
    META(%%): this is the GENERATED template's init script. It substitutes the
    PROJECT tokens (__ProjectName__ etc.) — leave those literal strings intact. Fill
    the meta-token slots (the "Next steps" echo) and adapt the marked language-specific
    blocks (XML-escaping, extra tokens, post-processing) for %%LangName%%. The
    substitution/rename/cleanup engine is language-neutral — keep it. See
    META-AUTHORING.md.

    Replaces the placeholder tokens in file contents AND in file/folder names, then
    removes the template-only files (TEMPLATE.md, docs/AGENT-INIT-GUIDE.md,
    tests/init-metadata.tests.ps1, and, unless -KeepScript, both initializers —
    this script and init.sh).

        pwsh ./scripts/init.ps1 -ProjectName Acme.Widgets

.PARAMETER ProjectName
    Project / namespace / package id. Required. Letters, digits, underscores;
    dot-separated segments allowed (e.g. Acme.Widgets).

.PARAMETER Author
    Single-line author for LICENSE and package metadata. Defaults to `git config
    user.name`. Release workflow use is serialized so shell metacharacters remain
    literal.

.PARAMETER AuthorEmail
    Single-line author email for the release commit. Defaults to `git config
    user.email`. Release workflow use is serialized so shell metacharacters remain
    literal.

.PARAMETER GitHubOwner
    GitHub owner/org used in repository URLs. Must be 1-39 letters, digits, or
    internal hyphens. Defaults to "your-org".

.PARAMETER Description
    Short package description. Defaults to "TODO: project description".

.PARAMETER Year
    Copyright year. Defaults to the current year.

.PARAMETER KeepScript
    Keep this script after running (TEMPLATE.md is removed either way).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
    [string]$Author,
    [string]$AuthorEmail,
    [string]$GitHubOwner,
    [string]$Description,
    [int]$Year = (Get-Date).Year,
    [switch]$KeepScript
)

$ErrorActionPreference = 'Stop'

if ($ProjectName -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$') {
    throw "Invalid -ProjectName '$ProjectName'. Use letters, digits, underscores; dot-separated segments allowed (e.g. Acme.Widgets)."
}

if (-not $Author) {
    $Author = (& git config user.name 2>$null)
    if (-not $Author) { $Author = 'Your Name' }
}
if (-not $AuthorEmail) {
    $AuthorEmail = (& git config user.email 2>$null)
    if (-not $AuthorEmail) { $AuthorEmail = 'you@example.com' }
}
if (-not $GitHubOwner) { $GitHubOwner = 'your-org' }
if (-not $Description) { $Description = 'TODO: project description' }

foreach ($field in @(
    @{ Name = 'Author'; Value = $Author },
    @{ Name = 'AuthorEmail'; Value = $AuthorEmail }
)) {
    if ($field.Value.Contains("`r") -or $field.Value.Contains("`n")) {
        throw "Invalid -$($field.Name): line breaks are not allowed. No files were changed."
    }
}

if ($GitHubOwner -notmatch '\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z') {
    throw 'Invalid -GitHubOwner. Use 1-39 letters, digits, or hyphens, with no leading or trailing hyphen. No files were changed.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$selfPath = $PSCommandPath

# META(%%): add any extra project tokens your language needs (e.g. JVM:
#   '__PackageName__' = $PackageName; '__Group__' = $Group) plus matching params above.
$replacements = [ordered]@{
    '__ProjectName__'       = $ProjectName
    '__Author__'            = $Author
    '__AuthorEmail__'       = $AuthorEmail
    '__AuthorBase64__'      = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Author))
    '__AuthorEmailBase64__' = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($AuthorEmail))
    '__GitHubOwner__'       = $GitHubOwner
    '__Description__'       = $Description
    '__Year__'              = "$Year"
}
$tokenPattern = '__ProjectName__|__AuthorEmailBase64__|__AuthorBase64__|__AuthorEmail__|__Author__|__GitHubOwner__|__Description__|__Year__'

# META(%%): XML-manifest languages (.NET: .csproj/.fsproj/.props) must XML-escape
# values written into those files. Non-XML languages (Rust TOML, Gradle KTS) can set
# $xmlFileExtensions = @() and delete the escape map — substitution then uses raw values.
$xmlReplacements = [ordered]@{}
foreach ($key in $replacements.Keys) {
    $xmlReplacements[$key] = $replacements[$key].Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}
$xmlFileExtensions = @('.csproj', '.fsproj', '.props', '.targets', '.slnx', '.config')

# Binary files carry no tokens; reading/rewriting them as text would corrupt them.
$binaryExtensions = @('.snk', '.pfx', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.zip', '.jar')

# META(%%): add your build output/cache dirs (e.g. 'target', 'build', '.gradle').
$excludedDirs = @('.git', '.jj', 'bin', 'obj')

function Test-Excluded([string]$fullPath) {
    $rel = $fullPath.Substring($repoRoot.Length).TrimStart('\', '/')
    foreach ($seg in ($rel -split '[\\/]')) {
        if ($excludedDirs -contains $seg) { return $true }
    }
    return $false
}

Write-Host "==> Initializing template as '$ProjectName'" -ForegroundColor Cyan

# 1) Replace tokens in file contents. Both initializers are skipped: they carry the
#    placeholder search-keys as literals, so substituting them would corrupt them.
$siblingShPath = Join-Path $PSScriptRoot 'init.sh'
$files = Get-ChildItem -Path $repoRoot -File -Recurse -Force | Where-Object {
    -not (Test-Excluded $_.FullName) -and $_.FullName -ne $selfPath -and $_.FullName -ne $siblingShPath
}
$contentChanged = 0
foreach ($file in $files) {
    if ($binaryExtensions -contains $file.Extension) { continue }
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $map = if ($xmlFileExtensions -contains $file.Extension) { $xmlReplacements } else { $replacements }
    # A single pass prevents a replacement value that resembles another token from
    # being interpreted as template syntax.
    $new = [regex]::Replace($text, $tokenPattern, { param($match) [string]$map[$match.Value] })
    if ($new -ne $text) {
        [System.IO.File]::WriteAllText($file.FullName, $new, (New-Object System.Text.UTF8Encoding($false)))
        $contentChanged++
    }
}
Write-Host "    Updated contents in $contentChanged file(s)." -ForegroundColor DarkGray

# 2) Rename files and folders whose name contains the project-name token.
#    Deepest paths first so child renames don't invalidate parent paths.
$named = Get-ChildItem -Path $repoRoot -Recurse -Force | Where-Object {
    -not (Test-Excluded $_.FullName) -and $_.Name -like '*__ProjectName__*'
} | Sort-Object { $_.FullName.Length } -Descending
foreach ($item in $named) {
    $newName = $item.Name.Replace('__ProjectName__', $ProjectName)
    Rename-Item -LiteralPath $item.FullName -NewName $newName
    Write-Host "    Renamed $($item.Name) -> $newName" -ForegroundColor DarkGray
}

# META(%%): language-specific post-processing goes here if needed. Example (Kotlin):
#   move src/main/kotlin/__PackageName__ to the real dotted package directory tree.

# 3) Activate the Claude Code shared settings (shipped inert as a .template file).
$claudeTemplate = Join-Path $repoRoot '.claude/settings.json.template'
if (Test-Path $claudeTemplate) {
    Move-Item -LiteralPath $claudeTemplate -Destination (Join-Path $repoRoot '.claude/settings.json') -Force
    Write-Host "    Activated .claude/settings.json" -ForegroundColor DarkGray
}

# 4) Remove template-only files.
$templateOnly = @(
    (Join-Path $repoRoot 'TEMPLATE.md'),
    (Join-Path $repoRoot 'docs/AGENT-INIT-GUIDE.md'),
    (Join-Path $repoRoot 'tests/init-metadata.tests.ps1')
)
foreach ($path in $templateOnly) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
        Write-Host "    Removed $($path.Substring($repoRoot.Length).TrimStart('\','/'))" -ForegroundColor DarkGray
    }
}

# Drop docs/ if it's now empty.
$docsDir = Join-Path $repoRoot 'docs'
if ((Test-Path -LiteralPath $docsDir) -and -not (Get-ChildItem -LiteralPath $docsDir -Force)) {
    Remove-Item -LiteralPath $docsDir -Force
    Write-Host "    Removed docs" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Green
# META(%%): fill these with your build/test commands and publishing note.
Write-Host "  1. %%BuildCmd%%"
Write-Host "  2. %%TestCmd%%"
Write-Host "  3. Review LICENSE (author/year) and the package metadata in %%ManifestFile%%."
Write-Host "  4. Publishing: add the %%PublishSecret%% repo secret, or delete"
Write-Host "     .github/workflows/release.yml and the packaging metadata."
Write-Host "  5. Commit the initialized project."

# Remove both initializers unless asked to keep them.
if (-not $KeepScript) {
    $siblingSh = Join-Path $PSScriptRoot 'init.sh'
    if (Test-Path -LiteralPath $siblingSh) {
        Remove-Item -LiteralPath $siblingSh -Force
    }
    Remove-Item -LiteralPath $selfPath -Force
}
