#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("meta-init-metadata-$([guid]::NewGuid().ToString('N'))")
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$metaMaintenanceNote = 'Template initialization now rejects multiline release identities and invalid GitHub owners while preserving shell metacharacters without release-workflow injection.'

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Assert-Equal([string]$expected, [string]$actual, [string]$message) {
    if ($expected -cne $actual) {
        throw "$message`nExpected: <$expected>`nActual:   <$actual>"
    }
}

function Assert-BytesEqual([byte[]]$expected, [byte[]]$actual, [string]$message) {
    $expectedBase64 = [Convert]::ToBase64String($expected)
    $actualBase64 = [Convert]::ToBase64String($actual)
    if ($expectedBase64 -cne $actualBase64) {
        throw "$message`nExpected bytes (base64): $expectedBase64`nActual bytes (base64):   $actualBase64"
    }
}

function Copy-Template([string]$destination) {
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    Get-ChildItem -LiteralPath $sourceRoot -Force | Where-Object {
        $_.Name -notin @('.git', '.jj', '.work')
    } | Copy-Item -Destination $destination -Recurse -Force
}

function Invoke-Captured(
    [string]$executable,
    [string[]]$arguments,
    [string]$workingDirectory,
    [switch]$ExpectFailure
) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $executable
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $process.Start() | Out-Null
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    $output = "$stdout$stderr".TrimEnd("`r", "`n")
    if ($ExpectFailure) {
        Assert-True ($exitCode -ne 0) "Expected failure from $executable $($arguments -join ' '), but it succeeded."
    }
    else {
        Assert-True ($exitCode -eq 0) "Command failed ($exitCode): $executable $($arguments -join ' ')`n$output"
    }

    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Invoke-Initializer(
    [ValidateSet('pwsh', 'bash')][string]$kind,
    [string]$root,
    [string]$author,
    [string]$authorEmail,
    [string]$githubOwner,
    [switch]$ExpectFailure
) {
    if ($kind -eq 'pwsh') {
        Push-Location $root
        try {
            try {
                $parameters = @{
                    ProjectName = 'Acme.Metadata'
                    Author = $author
                    AuthorEmail = $authorEmail
                    GitHubOwner = $githubOwner
                    Description = 'Metadata safety fixture'
                    Year = 2042
                    KeepScript = $true
                }
                $records = @(& './scripts/init.ps1' @parameters *>&1)
                $exitCode = 0
            }
            catch {
                $records = @($_)
                $exitCode = 1
            }
        }
        finally {
            Pop-Location
        }

        $output = ($records | ForEach-Object { $_.ToString() }) -join "`n"
        if ($ExpectFailure) {
            Assert-True ($exitCode -ne 0) 'Expected PowerShell initializer failure, but it succeeded.'
        }
        else {
            Assert-True ($exitCode -eq 0) "PowerShell initializer failed.`n$output"
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    }

    $encodedValues = @(
        'Acme.Metadata',
        $author,
        $authorEmail,
        $githubOwner,
        'Metadata safety fixture',
        '2042'
    ) | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }
    $runnerPath = Join-Path $root '.metadata-test-runner.sh'
    $runner = @"
#!/usr/bin/env bash
set -euo pipefail
decode_value() {
  local encoded="`$1" variable="`$2" decoded
  decoded="`$(printf '%s' "`$encoded" | base64 --decode; printf x)"
  printf -v "`$variable" '%s' "`${decoded%x}"
}
decode_value '$($encodedValues[0])' project_name
decode_value '$($encodedValues[1])' author
decode_value '$($encodedValues[2])' author_email
decode_value '$($encodedValues[3])' github_owner
decode_value '$($encodedValues[4])' description
decode_value '$($encodedValues[5])' year
exec ./scripts/init.sh \
  --project-name "`$project_name" \
  --author "`$author" \
  --author-email "`$author_email" \
  --github-owner "`$github_owner" \
  --description "`$description" \
  --year "`$year" \
  --keep-script
"@
    [IO.File]::WriteAllText($runnerPath, $runner.Replace("`r`n", "`n"), $utf8NoBom)
    try {
        return Invoke-Captured 'bash' @('./.metadata-test-runner.sh') $root -ExpectFailure:$ExpectFailure
    }
    finally {
        Remove-Item -LiteralPath $runnerPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-TreeSnapshot([string]$root) {
    $lines = Get-ChildItem -LiteralPath $root -Force -File -Recurse | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
        "$relative`t$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object
    return $lines -join "`n"
}

function Assert-GeneratedIdentity(
    [string]$root,
    [string]$author,
    [string]$authorEmail,
    [string]$githubOwner
) {
    $workflowPath = Join-Path $root '.github/workflows/release.yml'
    $workflow = [IO.File]::ReadAllText($workflowPath)
    $authorBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($author))
    $emailBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($authorEmail))

    $identityLines = (($workflow -split "\r?\n") | Where-Object { $_ -match 'RELEASE_AUTHOR' }) -join "`n"
    Assert-True $workflow.Contains("RELEASE_AUTHOR_B64: '$authorBase64'") "Generated workflow did not contain the encoded author (expected $authorBase64).`n$identityLines"
    Assert-True $workflow.Contains("RELEASE_AUTHOR_EMAIL_B64: '$emailBase64'") "Generated workflow did not contain the encoded author email.`n$identityLines"
    Assert-True (-not $workflow.Contains($author)) 'Generated workflow embedded the raw author in executable text.'
    Assert-True (-not $workflow.Contains($authorEmail)) 'Generated workflow embedded the raw author email in executable text.'
    Assert-True $workflow.Contains("repo = `"https://github.com/$githubOwner/Acme.Metadata`"") 'Generated Python repository URL was not preserved.'

    $codeOwners = [IO.File]::ReadAllText((Join-Path $root '.github/CODEOWNERS'))
    Assert-True $codeOwners.Contains("# * @$githubOwner") 'Generated CODEOWNERS entry was not preserved.'
    $license = [IO.File]::ReadAllText((Join-Path $root 'LICENSE'))
    Assert-True $license.Contains("Copyright (c) 2042 $author") 'Generated LICENSE author was not preserved exactly.'
}

function Assert-FreshProjectChangelog([string]$root) {
    $changelog = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'))
    Assert-True (-not $changelog.Contains($metaMaintenanceNote)) 'Generated CHANGELOG leaked the meta-template maintenance note.'

    $unreleasedMatch = [regex]::Match(
        $changelog,
        '(?ms)^## \[Unreleased\]\s*\r?\n(?<body>.*?)(?=^## \[|\z)'
    )
    Assert-True $unreleasedMatch.Success 'Generated CHANGELOG has no [Unreleased] section.'
    $unreleasedBody = $unreleasedMatch.Groups['body'].Value.Replace("`r`n", "`n")

    foreach ($heading in @('Added', 'Changed', 'Fixed')) {
        Assert-True $unreleasedBody.Contains("### $heading`n-") "Generated CHANGELOG lost the empty $heading placeholder."
    }

    $hasManualReleaseNote = @($unreleasedBody -split "`n" | Where-Object {
        $_ -match '^-\s+\S'
    }).Count -gt 0
    Assert-True (-not $hasManualReleaseNote) 'The first-release manual-note detector selected a generated [Unreleased] entry.'
}

function Test-GeneratedSyntaxAndExecution(
    [string]$root,
    [string]$author,
    [string]$authorEmail
) {
    $workflowPath = Join-Path $root '.github/workflows/release.yml'
    $workflowLines = [IO.File]::ReadAllLines($workflowPath)
    $start = [Array]::IndexOf($workflowLines, '          release_author="$(printf ''%s'' "$RELEASE_AUTHOR_B64" | base64 --decode)"')
    $end = if ($start -ge 0) {
        [Array]::IndexOf($workflowLines, '          git config user.email "$release_author_email"', $start)
    }
    else {
        -1
    }
    Assert-True ($start -ge 0 -and $end -ge $start) 'Could not extract the release identity shell block.'

    $authorBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($author))
    $emailBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($authorEmail))
    $snippetLines = @(
        'set -euo pipefail',
        "export RELEASE_AUTHOR_B64='$authorBase64'",
        "export RELEASE_AUTHOR_EMAIL_B64='$emailBase64'"
    ) + @($workflowLines[$start..$end] | ForEach-Object { $_.Substring(10) })
    $snippetPath = Join-Path $root '.release-identity.sh'
    [IO.File]::WriteAllText($snippetPath, (($snippetLines -join "`n") + "`n"), $utf8NoBom)

    $null = Invoke-Captured 'bash' @('-n', './.release-identity.sh') $root
    $null = Invoke-Captured 'git' @('init', '-q') $root
    $null = Invoke-Captured 'bash' @('./.release-identity.sh') $root
    $configuredAuthor = (Invoke-Captured 'git' @('config', 'user.name') $root).Output.TrimEnd("`r", "`n")
    $configuredEmail = (Invoke-Captured 'git' @('config', 'user.email') $root).Output.TrimEnd("`r", "`n")
    Assert-Equal $author $configuredAuthor 'Release shell changed the configured author.'
    Assert-Equal $authorEmail $configuredEmail 'Release shell changed the configured author email.'
    foreach ($sentinel in @(
        'INIT_AUTHOR_SUBSTITUTION',
        'INIT_AUTHOR_BACKTICK',
        'INIT_EMAIL_SUBSTITUTION',
        'INIT_EMAIL_BACKTICK'
    )) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root $sentinel))) "Release identity executed $sentinel."
    }

    $workflow = [IO.File]::ReadAllText($workflowPath)
    $pythonBlocks = [regex]::Matches($workflow, "(?ms)^          python3 <<'PY'\r?\n(?<code>.*?)^          PY\r?$")
    Assert-True ($pythonBlocks.Count -gt 0) 'No embedded Python blocks were found in release.yml.'
    $pythonCommand = @(Get-Command -Name @('python', 'python3') -CommandType Application -ErrorAction SilentlyContinue)[0]
    Assert-True ($null -ne $pythonCommand) 'Python is required to syntax-check embedded release blocks.'
    for ($index = 0; $index -lt $pythonBlocks.Count; $index++) {
        $lines = $pythonBlocks[$index].Groups['code'].Value -split "\r?\n"
        $dedented = ($lines | ForEach-Object {
            if ($_.StartsWith('          ')) { $_.Substring(10) } else { $_ }
        }) -join "`n"
        $pythonPath = Join-Path $root ".release-block-$index.py"
        [IO.File]::WriteAllText($pythonPath, "$dedented`n", $utf8NoBom)
        $null = Invoke-Captured $pythonCommand.Source @('-m', 'py_compile', $pythonPath) $root
    }

    $yamllint = @(Get-Command yamllint -CommandType Application -ErrorAction SilentlyContinue)[0]
    if ($null -ne $yamllint) {
        $null = Invoke-Captured $yamllint.Source @('.github/workflows/release.yml') $root
    }
}

function Get-ReleaseVersionScript([string]$seedVersion = '1.2.3') {
    $workflowLines = [IO.File]::ReadAllLines((Join-Path $sourceRoot '.github/workflows/release.yml'))
    $stepStart = [Array]::IndexOf($workflowLines, '      - name: Determine next version')
    $runStart = if ($stepStart -ge 0) {
        [Array]::IndexOf($workflowLines, '        run: |', $stepStart)
    }
    else {
        -1
    }
    $stepEnd = if ($runStart -ge 0) {
        [Array]::IndexOf($workflowLines, '      - name: Verify tag does not exist', $runStart)
    }
    else {
        -1
    }
    Assert-True ($runStart -ge 0 -and $stepEnd -gt $runStart) 'Could not extract the release version shell block.'

    $script = @($workflowLines[($runStart + 1)..($stepEnd - 1)] | ForEach-Object {
        if ($_.StartsWith('          ')) { $_.Substring(10) } else { $_ }
    }) -join "`n"
    return $script.Replace('${{ inputs.bump }}', 'patch').Replace('NEW=$(%%VersionSeedCmd%%)', "NEW=`"$seedVersion`"")
}

function Test-ReleaseVersionSelection {
    $versionScript = Get-ReleaseVersionScript
    $cases = @(
        @{
            Name = 'no-tags'
            Tags = @()
            Current = '0.0.0'
            Version = '1.2.3'
            FirstRelease = 'true'
        },
        @{
            Name = 'stable-tags'
            Tags = @('v1.2.9', 'v1.10.0')
            Current = '1.10.0'
            Version = '1.10.1'
            FirstRelease = 'false'
        },
        @{
            Name = 'stable-and-prerelease-tags'
            Tags = @('v1.9.0', 'v2.0.0-rc.1', 'v2.0.0+build.1', 'release-99.0.0')
            Current = '1.9.0'
            Version = '1.9.1'
            FirstRelease = 'false'
        },
        @{
            Name = 'stable-and-leading-zero-tags'
            Tags = @('v1.9.0', 'v2.08.0', 'v3.0.00', 'v04.0.0')
            Current = '1.9.0'
            Version = '1.9.1'
            FirstRelease = 'false'
        },
        @{
            Name = 'only-leading-zero-tags'
            Tags = @('v01.0.0', 'v2.00.0', 'v3.0.00')
            Current = '0.0.0'
            Version = '1.2.3'
            FirstRelease = 'true'
        }
    )

    foreach ($case in $cases) {
        $root = Join-Path $tempRoot "release-version-$($case.Name)"
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $null = Invoke-Captured 'git' @('init', '-q') $root
        $null = Invoke-Captured 'git' @('config', 'user.name', 'Release Test') $root
        $null = Invoke-Captured 'git' @('config', 'user.email', 'release-test@example.invalid') $root
        $null = Invoke-Captured 'git' @('commit', '--allow-empty', '-qm', 'fixture') $root
        foreach ($tag in $case.Tags) {
            $null = Invoke-Captured 'git' @('tag', $tag) $root
        }

        $runnerPath = Join-Path $root '.release-version.sh'
        $runner = 'export GITHUB_OUTPUT="$PWD/.github-output"' + "`n$versionScript`n"
        [IO.File]::WriteAllText($runnerPath, $runner.Replace("`r`n", "`n"), $utf8NoBom)
        $null = Invoke-Captured 'bash' @('-n', './.release-version.sh') $root
        $result = Invoke-Captured 'bash' @('./.release-version.sh') $root

        $outputs = @{}
        foreach ($line in [IO.File]::ReadAllLines((Join-Path $root '.github-output'))) {
            $pair = $line -split '=', 2
            if ($pair.Count -eq 2) { $outputs[$pair[0]] = $pair[1] }
        }
        Assert-Equal $case.Current $outputs.current "Release version case '$($case.Name)' selected the wrong base version.`n$($result.Output)"
        Assert-Equal $case.Version $outputs.version "Release version case '$($case.Name)' computed the wrong next version.`n$($result.Output)"
        Assert-Equal $case.FirstRelease $outputs.first_release "Release version case '$($case.Name)' reported the wrong first-release state.`n$($result.Output)"
    }
}

function Test-ReleaseVersionRejectsNoncanonicalSeed {
    $root = Join-Path $tempRoot 'release-version-noncanonical-seed'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $null = Invoke-Captured 'git' @('init', '-q') $root
    $null = Invoke-Captured 'git' @('config', 'user.name', 'Release Test') $root
    $null = Invoke-Captured 'git' @('config', 'user.email', 'release-test@example.invalid') $root
    $null = Invoke-Captured 'git' @('commit', '--allow-empty', '-qm', 'fixture') $root

    $runnerPath = Join-Path $root '.release-version.sh'
    $runner = 'export GITHUB_OUTPUT="$PWD/.github-output"' + "`n$(Get-ReleaseVersionScript '01.2.3')`n"
    [IO.File]::WriteAllText($runnerPath, $runner.Replace("`r`n", "`n"), $utf8NoBom)
    $null = Invoke-Captured 'bash' @('-n', './.release-version.sh') $root
    $result = Invoke-Captured 'bash' @('./.release-version.sh') $root -ExpectFailure

    Assert-True $result.Output.Contains("Computed version '01.2.3' is not a valid MAJOR.MINOR.PATCH semver.") 'Release version validation accepted a manifest seed with a leading zero.'
}

function Test-ReleaseOrderingInvariant {
    $workflow = [IO.File]::ReadAllText((Join-Path $sourceRoot '.github/workflows/release.yml'))
    $orderedSteps = @(
        '- name: Determine next version',
        '- name: Build, test, and package',
        '- name: Commit and tag the release (local only)',
        '- name: Publish to %%RegistryName%% (irreversible pivot)',
        '- name: Push the release commit + tag (atomic)',
        '- name: Create or update the GitHub Release (idempotent)'
    )
    $previous = -1
    foreach ($step in $orderedSteps) {
        $current = $workflow.IndexOf($step, [StringComparison]::Ordinal)
        Assert-True ($current -gt $previous) "Release ordering invariant is broken at step '$step'."
        $previous = $current
    }
}

function Test-RejectedInput(
    [ValidateSet('pwsh', 'bash')][string]$kind,
    [string]$caseName,
    [string]$author,
    [string]$authorEmail,
    [string]$githubOwner,
    [string]$diagnostic
) {
    $root = Join-Path $tempRoot "reject-$kind-$caseName"
    Copy-Template $root
    $before = Get-TreeSnapshot $root
    $result = Invoke-Initializer $kind $root $author $authorEmail $githubOwner -ExpectFailure
    $after = Get-TreeSnapshot $root

    Assert-Equal $before $after "$kind $caseName rejection partially changed the template."
    Assert-True $result.Output.ToLowerInvariant().Contains($diagnostic) "$kind $caseName rejection did not identify $diagnostic.`n$($result.Output)"
    foreach ($sentinel in @('INIT_OWNER_SUBSTITUTION', 'INIT_OWNER_BACKTICK')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root $sentinel))) "$kind $caseName executed $sentinel."
    }
}

function Test-OwnerBoundary(
    [ValidateSet('pwsh', 'bash')][string]$kind,
    [string]$owner,
    [string]$caseName
) {
    $root = Join-Path $tempRoot "owner-$kind-$caseName"
    Copy-Template $root
    $null = Invoke-Initializer $kind $root 'Boundary Author' 'boundary@example.invalid' $owner
    $codeOwners = [IO.File]::ReadAllText((Join-Path $root '.github/CODEOWNERS'))
    Assert-True $codeOwners.Contains("# * @$owner") "$kind did not preserve supported owner boundary $caseName."
}

function Test-ExistingSettingsPreserved([ValidateSet('pwsh', 'bash')][string]$kind) {
    $root = Join-Path $tempRoot "settings-existing-$kind"
    Copy-Template $root
    $settingsPath = Join-Path $root '.claude/settings.json'
    $templatePath = Join-Path $root '.claude/settings.json.template'
    $payload = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes(
        "{`r`n  `"localLiteral`": `"__ProjectName__`",`r`n  `"enabled`": true`r`n}"
    ))
    [IO.File]::WriteAllBytes($settingsPath, $payload)

    $result = Invoke-Initializer $kind $root 'Settings Author' 'settings@example.invalid' 'settings-owner'

    Assert-True $result.Output.Contains('Kept existing .claude/settings.json unchanged; left .claude/settings.json.template in place.') "$kind did not report the settings conflict clearly.`n$($result.Output)"
    Assert-BytesEqual $payload ([IO.File]::ReadAllBytes($settingsPath)) "$kind changed the existing user settings bytes."
    Assert-True (Test-Path -LiteralPath $templatePath -PathType Leaf) "$kind removed the settings template during a destination conflict."
}

function Test-SettingsActivationAndRepeat([ValidateSet('pwsh', 'bash')][string]$kind) {
    $root = Join-Path $tempRoot "settings-repeat-$kind"
    Copy-Template $root
    $settingsPath = Join-Path $root '.claude/settings.json'
    $templatePath = Join-Path $root '.claude/settings.json.template'

    $first = Invoke-Initializer $kind $root 'Settings Author' 'settings@example.invalid' 'settings-owner'
    Assert-True $first.Output.Contains('Activated .claude/settings.json') "$kind did not report settings activation.`n$($first.Output)"
    Assert-True (Test-Path -LiteralPath $settingsPath -PathType Leaf) "$kind did not activate the settings template."
    Assert-True (-not (Test-Path -LiteralPath $templatePath)) "$kind retained the template after successful activation."
    $activatedBytes = [IO.File]::ReadAllBytes($settingsPath)

    $second = Invoke-Initializer $kind $root 'Settings Author' 'settings@example.invalid' 'settings-owner'
    Assert-True $second.Output.Contains('Kept existing .claude/settings.json unchanged; no settings template needed activation.') "$kind did not report the idempotent repeat state.`n$($second.Output)"
    Assert-BytesEqual $activatedBytes ([IO.File]::ReadAllBytes($settingsPath)) "$kind changed activated settings on a repeated run."
    Assert-True (-not (Test-Path -LiteralPath $templatePath)) "$kind recreated the settings template on a repeated run."
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $author = 'A O''Connor "quoted" \ $(touch INIT_AUTHOR_SUBSTITUTION); `touch INIT_AUTHOR_BACKTICK`'
    $authorEmail = 'mail\"$(touch INIT_EMAIL_SUBSTITUTION);`touch INIT_EMAIL_BACKTICK`@example.invalid'
    $githubOwner = 'acme-tools'
    $roots = @{}

    foreach ($kind in @('pwsh', 'bash')) {
        $root = Join-Path $tempRoot "positive-$kind"
        $roots[$kind] = $root
        Copy-Template $root
        $result = Invoke-Initializer $kind $root $author $authorEmail $githubOwner
        Assert-True $result.Output.Contains('Activated .claude/settings.json') "$kind did not activate settings when the destination was absent.`n$($result.Output)"
        Assert-True (Test-Path -LiteralPath (Join-Path $root '.claude/settings.json') -PathType Leaf) "$kind did not create .claude/settings.json."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.claude/settings.json.template'))) "$kind left the template after activation."
        Assert-GeneratedIdentity $root $author $authorEmail $githubOwner
        Assert-FreshProjectChangelog $root
        Test-GeneratedSyntaxAndExecution $root $author $authorEmail
    }

    foreach ($relativePath in @('.github/workflows/release.yml', '.github/CODEOWNERS', 'LICENSE')) {
        $powerShellOutput = [IO.File]::ReadAllText((Join-Path $roots.pwsh $relativePath))
        $bashOutput = [IO.File]::ReadAllText((Join-Path $roots.bash $relativePath))
        Assert-Equal $powerShellOutput $bashOutput "Initializer parity failed for $relativePath."
    }

    Test-ReleaseVersionSelection
    Test-ReleaseVersionRejectsNoncanonicalSeed
    Test-ReleaseOrderingInvariant

    $ownerCases = @(
        @{ Name = 'quote'; Value = 'bad"owner' },
        @{ Name = 'backtick'; Value = 'bad`owner' },
        @{ Name = 'substitution'; Value = '$(touch INIT_OWNER_SUBSTITUTION)' },
        @{ Name = 'backslash'; Value = 'bad\owner' },
        @{ Name = 'newline'; Value = "bad`nowner" },
        @{ Name = 'trailing-lf'; Value = "valid-owner`n" },
        @{ Name = 'trailing-crlf'; Value = "valid-owner`r`n" }
    )
    foreach ($kind in @('pwsh', 'bash')) {
        $ownerDiagnostic = if ($kind -eq 'pwsh') { 'githubowner' } else { 'github-owner' }
        $emailDiagnostic = if ($kind -eq 'pwsh') { 'authoremail' } else { 'author-email' }
        foreach ($case in $ownerCases) {
            Test-RejectedInput $kind "owner-$($case.Name)" 'Valid Author' 'valid@example.invalid' $case.Value $ownerDiagnostic
        }
        Test-RejectedInput $kind 'author-newline' "first`nsecond" 'valid@example.invalid' 'valid-owner' 'author'
        Test-RejectedInput $kind 'email-newline' 'Valid Author' "first`nsecond@example.invalid" 'valid-owner' $emailDiagnostic
        Test-OwnerBoundary $kind 'a' 'minimum'
        Test-OwnerBoundary $kind ("a$('-' * 37)z") 'maximum'
        Test-ExistingSettingsPreserved $kind
        Test-SettingsActivationAndRepeat $kind
    }

    Write-Host 'PASS: metadata and settings initialization are equivalent, idempotent, syntax-valid, failure-safe, and injection-safe.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
