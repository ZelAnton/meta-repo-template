#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [ValidateSet('quick', 'all', 'cross-bash-pwsh', 'cross-engine', 'cross-pwsh-bash', 'failure-io', 'hostile-recovery', 'quarantine', 'recovery-bash-pwsh', 'recovery-pwsh-bash', 'same-engine')]
    [string]$TestScope = 'quick'
)

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

function Read-TestCoordinationRecord([string]$path) {
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        $separator = $line.IndexOf('|')
        Assert-True ($separator -gt 0) "Malformed test coordination record at $path."
        $key = $line.Substring(0, $separator)
        $value = $line.Substring($separator + 1)
        $values[$key] = if ($key -eq 'VERSION') {
            $value
        }
        else {
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value))
        }
    }
    return $values
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
    $failurePhase = [Environment]::GetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE')
    if ($failurePhase) {
        $startInfo.Environment['META_INIT_TEST_FAIL_PHASE'] = $failurePhase
    }
    else {
        $null = $startInfo.Environment.Remove('META_INIT_TEST_FAIL_PHASE')
    }
    $crashPhase = [Environment]::GetEnvironmentVariable('META_INIT_TEST_CRASH_PHASE')
    if ($crashPhase) {
        $startInfo.Environment['META_INIT_TEST_CRASH_PHASE'] = $crashPhase
    }
    else {
        $null = $startInfo.Environment.Remove('META_INIT_TEST_CRASH_PHASE')
    }
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
        Assert-True ($exitCode -ne 0) "Expected failure from $executable $($arguments -join ' '), but it succeeded (workingDirectory=$workingDirectory; failurePhase=$failurePhase; crashPhase=$crashPhase).`n$output"
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
    [bool]$KeepScript = $true,
    [ValidateSet('', 'content', 'rename', 'settings', 'cleanup', 'scripts')][string]$FailurePhase = '',
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
                    KeepScript = $KeepScript
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
            Assert-True ($exitCode -eq 0) "PowerShell initializer failed (root=$root; failurePhase=$FailurePhase).`n$output"
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    }

    $encodedValues = @(
        'Acme.Metadata',
        $author,
        $authorEmail,
        $githubOwner,
        'Metadata safety fixture',
        '2042',
        [string][Environment]::GetEnvironmentVariable('META_INIT_TEST_SKIP_CONTENT_PATH')
    ) | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }
    $runnerPath = Join-Path $root '.metadata-test-runner.sh'
    $runnerCrashPhase = [Environment]::GetEnvironmentVariable('META_INIT_TEST_CRASH_PHASE')
    $runnerPathPrefix = [Environment]::GetEnvironmentVariable('META_INIT_TEST_PATH_PREFIX')
    $runner = @"
#!/usr/bin/env bash
set -euo pipefail
export META_INIT_TEST_FAIL_PHASE='$FailurePhase'
export META_INIT_TEST_CRASH_PHASE='$runnerCrashPhase'
if [ -n '$runnerPathPrefix' ]; then
  export PATH="`$PWD/${runnerPathPrefix}:`$PATH"
  export BASH_ENV="`$PWD/${runnerPathPrefix}/bash-env.sh"
  hash -r
fi
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
decode_value '$($encodedValues[6])' skip_content_path
export META_INIT_TEST_SKIP_CONTENT_PATH="`$skip_content_path"
keep_script_args=()
if [ '$($KeepScript.ToString().ToLowerInvariant())' = true ]; then
  keep_script_args+=(--keep-script)
fi
exec ./scripts/init.sh \
  --project-name "`$project_name" \
  --author "`$author" \
  --author-email "`$author_email" \
  --github-owner "`$github_owner" \
  --description "`$description" \
  --year "`$year" \
  "`${keep_script_args[@]}"
"@
    [IO.File]::WriteAllText($runnerPath, $runner.Replace("`r`n", "`n"), $utf8NoBom)
    try {
        return Invoke-Captured 'bash' @('./.metadata-test-runner.sh') $root -ExpectFailure:$ExpectFailure
    }
    finally {
        Remove-Item -LiteralPath $runnerPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-InitializerAtFailurePhase(
    [ValidateSet('pwsh', 'bash')][string]$kind,
    [string]$root,
    [ValidateSet('content', 'rename', 'settings', 'cleanup', 'scripts')][string]$phase
) {
    $previousPhase = [Environment]::GetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE')
    [Environment]::SetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE', $phase)
    try {
        return Invoke-Initializer $kind $root 'Transactional Author' 'transaction@example.invalid' 'transaction-owner' -KeepScript ($phase -notin @('cleanup', 'scripts')) -FailurePhase $phase -ExpectFailure
    }
    finally {
        [Environment]::SetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE', $previousPhase)
    }
}

function Invoke-InitializerAtCrashPhase(
    [ValidateSet('pwsh', 'bash')][string]$kind,
    [string]$root,
    [ValidateSet('content', 'rename', 'settings', 'cleanup', 'scripts')][string]$phase
) {
    $previousCrash = [Environment]::GetEnvironmentVariable('META_INIT_TEST_CRASH_PHASE')
    [Environment]::SetEnvironmentVariable('META_INIT_TEST_CRASH_PHASE', $phase)
    try {
        if ($kind -eq 'pwsh') {
            $arguments = @(
                '-NoProfile', '-File', './scripts/init.ps1',
                '-ProjectName', 'Acme.Metadata',
                '-Author', 'Crash Author',
                '-AuthorEmail', 'crash@example.invalid',
                '-GitHubOwner', 'crash-owner',
                '-Description', 'Metadata safety fixture',
                '-Year', '2042'
            )
            if ($phase -ne 'scripts') { $arguments += '-KeepScript' }
            return Invoke-Captured 'pwsh' $arguments $root -ExpectFailure
        }
        return Invoke-Initializer $kind $root 'Crash Author' 'crash@example.invalid' 'crash-owner' -KeepScript ($phase -ne 'scripts') -ExpectFailure
    }
    finally {
        [Environment]::SetEnvironmentVariable('META_INIT_TEST_CRASH_PHASE', $previousCrash)
    }
}

function Get-PowerShellTransactionPath([string]$root) {
    $boundary = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path).TrimEnd('\', '/')
    $hash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($boundary))
    ).ToLowerInvariant()
    return Join-Path ([IO.Path]::GetTempPath()) "meta-init-transaction-$hash-pwsh"
}

function Get-BashTransactionPath([string]$root) {
    $runnerPath = Join-Path $root '.metadata-transaction-path.sh'
    $runner = @'
#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd . && pwd)"
if command -v sha256sum >/dev/null 2>&1; then
  repo_hash="$(printf '%s' "$repo_root" | sha256sum | awk '{print $1}')"
else
  repo_hash="$(printf '%s' "$repo_root" | shasum -a 256 | awk '{print $1}')"
fi
transaction_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
transaction_root="$transaction_parent/meta-init-transaction-$repo_hash-bash"
if [ "${OS:-}" = Windows_NT ]; then cygpath -aw "$transaction_root"
else printf '%s\n' "$transaction_root"
fi
'@
    [IO.File]::WriteAllText($runnerPath, $runner.Replace("`r`n", "`n"), $utf8NoBom)
    try {
        return (Invoke-Captured 'bash' @('./.metadata-transaction-path.sh') $root).Output.Trim()
    }
    finally { Remove-Item -LiteralPath $runnerPath -Force -ErrorAction SilentlyContinue }
}

function Get-TransactionPath([ValidateSet('pwsh', 'bash')][string]$kind, [string]$root) {
    if ($kind -eq 'pwsh') { return (Get-PowerShellTransactionPath $root) }
    return (Get-BashTransactionPath $root)
}

function Remove-TestTransactionRoot([string]$transactionRoot) {
    $item = Get-Item -LiteralPath $transactionRoot -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) {
        Remove-Item -LiteralPath $transactionRoot -Force -ErrorAction Stop
    }
    else {
        Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction Stop
    }
}

function Set-TestPrivateTransactionRoot([string]$transactionRoot) {
    if ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & icacls.exe $transactionRoot '/inheritance:r' '/grant:r' "*$sid`:(OI)(CI)F" | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) 'Could not restore the private transaction ACL in a hostile-recovery fixture.'
    }
    else {
        [IO.File]::SetUnixFileMode(
            $transactionRoot,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute
        )
    }
}

function Write-TestTransactionManifest([string]$manifestPath, [string]$content) {
    [IO.File]::WriteAllText($manifestPath, $content, $utf8NoBom)
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode(
            $manifestPath,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        )
    }
}

function Invoke-HostileRecoveryAttempt(
    [ValidateSet('pwsh', 'bash')][string]$kind,
    [string]$root,
    [string]$before,
    [string]$label,
    [object[]]$externalFiles = @()
) {
    $result = Invoke-Initializer $kind $root 'Hostile Recovery Author' 'hostile@example.invalid' 'hostile-owner' -ExpectFailure
    Assert-Equal $before (Get-TreeSnapshot $root) "$kind hostile recovery '$label' changed repository data before rejecting the journal."
    foreach ($external in $externalFiles) {
        Assert-BytesEqual $external.Bytes ([IO.File]::ReadAllBytes($external.Path)) "$kind hostile recovery '$label' changed external data at '$($external.Path)'."
    }
    Assert-True ($result.Output.ToLowerInvariant().Contains('transaction') -or $result.Output.ToLowerInvariant().Contains('recovery')) "$kind hostile recovery '$label' failed without a recovery-boundary diagnostic.`n$($result.Output)"
    return $result
}

function Get-TreeSnapshotWithMetadata([string]$root) {
    $lines = Get-ChildItem -LiteralPath $root -Force -Recurse | Where-Object {
        $_.Name -notin @('.meta-init-transaction.owner', '.meta-init-transaction.recovery', '.metadata-held-runner.sh') -and
        $_.Name -notlike '.metadata-preflight-*.marker' -and
        $_.Name -notlike '.meta-init-owner.*.tmp'
    } | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
        if ($_.PSIsContainer) {
            "directory`t$relative"
        }
        else {
            $metadata = if ($IsWindows) {
                "$([int]$_.Attributes):$((Get-Acl -LiteralPath $_.FullName).Sddl)"
            }
            else {
                [int][IO.File]::GetUnixFileMode($_.FullName)
            }
            "file`t$relative`t$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)`t$metadata"
        }
    } | Sort-Object
    return $lines -join "`n"
}

function Get-TreeSnapshot([string]$root) {
    $lines = Get-ChildItem -LiteralPath $root -Force -Recurse | Where-Object {
        $_.Name -notin @('.meta-init-transaction.owner', '.meta-init-transaction.recovery', '.metadata-held-runner.sh') -and
        $_.Name -notlike '.metadata-preflight-*.marker' -and
        $_.Name -notlike '.meta-init-owner.*.tmp'
    } | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
        if ($_.PSIsContainer) {
            "directory`t$relative"
        }
        else {
            "file`t$relative`t$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        }
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

function Test-QuarantineAuthorSubstitution([ValidateSet('pwsh', 'bash')][string]$kind) {
    $root = Join-Path $tempRoot ".work/worktrees/quarantine-author-$kind"
    Copy-Template $root
    $author = 'A O''Connor "quoted" \ $(touch INIT_AUTHOR_SUBSTITUTION); `touch INIT_AUTHOR_BACKTICK`'
    $authorEmail = 'quarantine-author@example.invalid'
    $expectedAuthorBase64 = 'QSBPJ0Nvbm5vciAicXVvdGVkIiBcICQodG91Y2ggSU5JVF9BVVRIT1JfU1VCU1RJVFVUSU9OKTsgYHRvdWNoIElOSVRfQVVUSE9SX0JBQ0tUSUNLYA=='
    $actualAuthorBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($author))
    Assert-Equal $expectedAuthorBase64 $actualAuthorBase64 'The quarantine author fixture no longer matches the failed integration input.'

    $result = Invoke-Initializer $kind $root $author $authorEmail 'quarantine-owner'
    $workflow = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/release.yml'))
    $identityLines = (($workflow -split "\r?\n") | Where-Object { $_ -match 'RELEASE_AUTHOR' }) -join "`n"
    Assert-True $workflow.Contains("RELEASE_AUTHOR_B64: '$expectedAuthorBase64'") "$kind reproduced the quarantined literal author token.`n$identityLines`n$($result.Output)"
    Assert-True (-not $workflow.Contains("RELEASE_AUTHOR_B64: '__AuthorBase64__'")) "$kind left the quarantined __AuthorBase64__ token in generated release.yml."
    Assert-GeneratedIdentity $root $author $authorEmail 'quarantine-owner'
}

function Test-ContentCommitVerification([ValidateSet('pwsh', 'bash')][string]$kind) {
    $root = Join-Path $tempRoot "content-commit-verification-$kind"
    Copy-Template $root
    $before = Get-TreeSnapshot $root
    $previous = [Environment]::GetEnvironmentVariable('META_INIT_TEST_SKIP_CONTENT_PATH')
    [Environment]::SetEnvironmentVariable('META_INIT_TEST_SKIP_CONTENT_PATH', '.github/workflows/release.yml')
    try {
        $result = Invoke-Initializer $kind $root 'A O''Connor "quoted" \ $(touch INIT_AUTHOR_SUBSTITUTION); `touch INIT_AUTHOR_BACKTICK`' 'verification@example.invalid' 'verification-owner' -ExpectFailure
    }
    finally {
        [Environment]::SetEnvironmentVariable('META_INIT_TEST_SKIP_CONTENT_PATH', $previous)
    }

    Assert-Equal $before (Get-TreeSnapshot $root) "$kind did not roll back a skipped release.yml content commit."
    Assert-True $result.Output.ToLowerInvariant().Contains('staged content was not applied exactly') "$kind accepted a generated release.yml whose author token was not replaced.`n$($result.Output)"
    $workflow = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/release.yml'))
    Assert-True $workflow.Contains("RELEASE_AUTHOR_B64: '__AuthorBase64__'") "$kind did not restore the exact pre-initialization release workflow after commit verification failed."
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

function Test-ExcludedStatePreserved([ValidateSet('pwsh', 'bash')][string]$kind) {
    $root = Join-Path $tempRoot ".work/outer/.inbox/excluded-state-$kind"
    Copy-Template $root

    $fixtures = @(
        '.git',
        'nested/file-form/.work',
        'nested/file-form/deeper/bin',
        '.work/queue/__ProjectName__-pending.state',
        'nested/.inbox/messages/__ProjectName__-message.state',
        'nested/one/.git/refs/__ProjectName__-ref.state',
        'nested/one/two/.jj/state/__ProjectName__-operation.state',
        'nested/one/two/three/bin/__ProjectName__-output.state',
        'nested/one/two/three/four/obj/__ProjectName__-cache.state'
    )
    $expectedBytes = @{}
    foreach ($relativePath in $fixtures) {
        $path = Join-Path $root $relativePath
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
        $payload = [byte[]](@(0xEF, 0xBB, 0xBF, 0x00, 0xFF) + [Text.Encoding]::UTF8.GetBytes(
            "path=$relativePath`r`nproject=__ProjectName__`nauthor=__Author__"
        ))
        [IO.File]::WriteAllBytes($path, $payload)
        $expectedBytes[$relativePath] = $payload
    }

    $ordinarySource = Join-Path $root 'ordinary/__ProjectName__-project.txt'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ordinarySource)) | Out-Null
    [IO.File]::WriteAllText(
        $ordinarySource,
        'project=__ProjectName__; author=__Author__',
        $utf8NoBom
    )

    $null = Invoke-Initializer $kind $root 'Preservation Author' 'preservation@example.invalid' 'preservation-owner'

    foreach ($relativePath in $fixtures) {
        $path = Join-Path $root $relativePath
        $renamedPath = Join-Path $root $relativePath.Replace('__ProjectName__', 'Acme.Metadata')
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "$kind renamed excluded state path '$relativePath'."
        if ($renamedPath -cne $path) {
            Assert-True (-not (Test-Path -LiteralPath $renamedPath)) "$kind created a renamed excluded state path for '$relativePath'."
        }
        Assert-BytesEqual $expectedBytes[$relativePath] ([IO.File]::ReadAllBytes($path)) "$kind changed bytes in excluded state path '$relativePath'."
    }

    $ordinaryResult = Join-Path $root 'ordinary/Acme.Metadata-project.txt'
    Assert-True (-not (Test-Path -LiteralPath $ordinarySource)) "$kind did not rename an ordinary project path."
    Assert-True (Test-Path -LiteralPath $ordinaryResult -PathType Leaf) "$kind did not create the renamed ordinary project path."
    Assert-Equal 'project=Acme.Metadata; author=Preservation Author' ([IO.File]::ReadAllText($ordinaryResult)) "$kind did not substitute ordinary project content."
}

function Test-ContentEncodingSafety([ValidateSet('pwsh', 'bash')][string]$kind) {
    $root = Join-Path $tempRoot "content-encoding-$kind"
    Copy-Template $root

    $binaryPath = Join-Path $root 'fixtures/token-payload.bin'
    $utf16Path = Join-Path $root 'fixtures/token-payload.utf16'
    $utf8Path = Join-Path $root 'fixtures/utf8-bom-crlf.txt'
    $stablePath = Join-Path $root 'fixtures/utf8-no-token.txt'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($binaryPath)) | Out-Null

    $binaryBytes = [byte[]](0x13, 0x00, 0xFF, 0x5F, 0x5F, 0x50, 0x72, 0x6F, 0x6A, 0x65, 0x63, 0x74, 0x4E, 0x61, 0x6D, 0x65, 0x5F, 0x5F, 0x7E)
    $utf16Encoding = [Text.UnicodeEncoding]::new($false, $true)
    $utf16Bytes = [byte[]]($utf16Encoding.GetPreamble() + $utf16Encoding.GetBytes('project=__ProjectName__'))
    $utf8BomEncoding = [Text.UTF8Encoding]::new($true)
    $utf8Bytes = [byte[]]($utf8BomEncoding.GetPreamble() + $utf8BomEncoding.GetBytes("project=__ProjectName__`r`nauthor=__Author__`r`n"))
    $stableBytes = [byte[]]($utf8BomEncoding.GetPreamble() + $utf8BomEncoding.GetBytes("stable content`r`nwithout tokens`r`n"))
    [IO.File]::WriteAllBytes($binaryPath, $binaryBytes)
    [IO.File]::WriteAllBytes($utf16Path, $utf16Bytes)
    [IO.File]::WriteAllBytes($utf8Path, $utf8Bytes)
    [IO.File]::WriteAllBytes($stablePath, $stableBytes)

    $null = Invoke-Initializer $kind $root 'Safety Author' 'safety@example.invalid' 'safety-owner'

    Assert-BytesEqual $binaryBytes ([IO.File]::ReadAllBytes($binaryPath)) "$kind rewrote a binary file containing a token-like byte sequence."
    Assert-BytesEqual $utf16Bytes ([IO.File]::ReadAllBytes($utf16Path)) "$kind rewrote a UTF-16 file containing a token."
    $expectedUtf8 = [byte[]]($utf8BomEncoding.GetPreamble() + $utf8BomEncoding.GetBytes("project=Acme.Metadata`r`nauthor=Safety Author`r`n"))
    Assert-BytesEqual $expectedUtf8 ([IO.File]::ReadAllBytes($utf8Path)) "$kind did not preserve UTF-8 BOM and CRLF bytes during substitution."
    Assert-BytesEqual $stableBytes ([IO.File]::ReadAllBytes($stablePath)) "$kind rewrote a UTF-8 file without a replacement."
}

function Test-TransactionalFailure(
    [ValidateSet('pwsh', 'bash')][string]$kind,
    [ValidateSet('content', 'rename', 'settings', 'cleanup', 'scripts')][string]$phase
) {
    $root = Join-Path $tempRoot "transaction-$kind-$phase"
    Copy-Template $root
    $before = Get-TreeSnapshot $root

    $result = Invoke-InitializerAtFailurePhase $kind $root $phase
    $after = Get-TreeSnapshot $root

    Assert-Equal $before $after "$kind left a mixed tree after a controlled $phase failure."
    $normalizedOutput = $result.Output.ToLowerInvariant()
    Assert-True $normalizedOutput.Contains("controlled test failure after $phase phase") "$kind did not report the controlled $phase failure.`n$($result.Output)"
    Assert-True $normalizedOutput.Contains('original tree was restored') "$kind did not report a completed rollback after $phase failure.`n$($result.Output)"
}

function Test-CrashRecovery(
    [ValidateSet('pwsh', 'bash')][string]$kind,
    [ValidateSet('content', 'rename', 'settings', 'cleanup', 'scripts')][string]$phase,
    [string]$expectedCompletedTree
) {
    $root = Join-Path $tempRoot "crash-$kind-$phase"
    Copy-Template $root

    $result = Invoke-InitializerAtCrashPhase $kind $root $phase
    Assert-True ($result.ExitCode -ne 0) "$kind did not terminate abruptly during $phase."

    $restart = Invoke-Initializer $kind $root 'Crash Author' 'crash@example.invalid' 'crash-owner'
    Assert-True $restart.Output.Contains('Recovered an interrupted initialization transaction.') "$kind did not report automatic $phase recovery on restart.`n$($restart.Output)"
    Assert-Equal $expectedCompletedTree (Get-TreeSnapshot $root) "$kind restart after abrupt $phase termination did not produce the exact completed tree."
}

function Add-NestedRenameFixture([string]$root) {
    $inner = Join-Path $root 'nested/outer__ProjectName__/inner__ProjectName__'
    [IO.Directory]::CreateDirectory($inner) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $inner 'leaf__ProjectName__.txt'),
        'project=__ProjectName__',
        $utf8NoBom
    )
}

function Test-NestedRenameStateMachine([ValidateSet('pwsh', 'bash')][string]$kind) {
    $control = Join-Path $tempRoot "nested-control-$kind"
    Copy-Template $control
    Add-NestedRenameFixture $control
    $null = Invoke-Initializer $kind $control 'Nested Author' 'nested@example.invalid' 'nested-owner'
    $expectedCompleted = Get-TreeSnapshot $control
    $finalLeaf = Join-Path $control 'nested/outerAcme.Metadata/innerAcme.Metadata/leafAcme.Metadata.txt'
    Assert-True (Test-Path -LiteralPath $finalLeaf -PathType Leaf) "$kind did not complete deepest-first nested path renaming."

    foreach ($sourceName in @('inner__ProjectName__', 'outer__ProjectName__')) {
        $position = if ($sourceName.StartsWith('inner')) { 'before-parent' } else { 'after-parent' }
        $failureRoot = Join-Path $tempRoot "nested-failure-$kind-$position"
        Copy-Template $failureRoot
        Add-NestedRenameFixture $failureRoot
        $before = Get-TreeSnapshot $failureRoot
        $savedPhase = [Environment]::GetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE')
        $savedSource = [Environment]::GetEnvironmentVariable('META_INIT_TEST_FAIL_RENAME_SOURCE')
        [Environment]::SetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE', 'rename')
        [Environment]::SetEnvironmentVariable('META_INIT_TEST_FAIL_RENAME_SOURCE', $sourceName)
        try {
            $result = Invoke-Initializer $kind $failureRoot 'Nested Author' 'nested@example.invalid' 'nested-owner' -FailurePhase rename -ExpectFailure
        }
        finally {
            [Environment]::SetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE', $savedPhase)
            [Environment]::SetEnvironmentVariable('META_INIT_TEST_FAIL_RENAME_SOURCE', $savedSource)
        }
        Assert-True $result.Output.ToLowerInvariant().Contains('original tree was restored') "$kind did not report nested $position rollback.`n$($result.Output)"
        Assert-Equal $before (Get-TreeSnapshot $failureRoot) "$kind did not exactly roll back a nested rename failure $position."

        $crashRoot = Join-Path $tempRoot "nested-crash-$kind-$position"
        Copy-Template $crashRoot
        Add-NestedRenameFixture $crashRoot
        $savedSource = [Environment]::GetEnvironmentVariable('META_INIT_TEST_CRASH_RENAME_SOURCE')
        [Environment]::SetEnvironmentVariable('META_INIT_TEST_CRASH_RENAME_SOURCE', $sourceName)
        try { $null = Invoke-InitializerAtCrashPhase $kind $crashRoot rename }
        finally { [Environment]::SetEnvironmentVariable('META_INIT_TEST_CRASH_RENAME_SOURCE', $savedSource) }
        $restart = Invoke-Initializer $kind $crashRoot 'Nested Author' 'nested@example.invalid' 'nested-owner'
        Assert-True $restart.Output.Contains('Recovered an interrupted initialization transaction.') "$kind did not recover a nested rename crash $position.`n$($restart.Output)"
        Assert-Equal $expectedCompleted (Get-TreeSnapshot $crashRoot) "$kind restart after a nested rename crash $position was not exact."
    }
}

function Start-HeldInitializer(
    [ValidateSet('pwsh', 'bash')][string]$kind,
    [string]$root,
    [ValidateRange(1, 60)][int]$HoldSeconds = 30
) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $kind
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($name in @(
        'META_INIT_TEST_FAIL_PHASE', 'META_INIT_TEST_CRASH_PHASE',
        'META_INIT_TEST_FAIL_RENAME_SOURCE', 'META_INIT_TEST_CRASH_RENAME_SOURCE',
        'META_INIT_RECOVER_ONLY', 'META_INIT_RECOVERY_PARENT_TOKEN',
        'META_INIT_TEST_HOLD_AFTER_LOCK_SECONDS', 'META_INIT_TEST_HOLD_PREFLIGHT_SECONDS',
        'META_INIT_TEST_PREFLIGHT_MARKER', 'META_INIT_TEST_SKIP_CONTENT_PATH'
    )) { $null = $startInfo.Environment.Remove($name) }
    $runnerPath = $null
    $markerPath = Join-Path $root ".metadata-preflight-$([guid]::NewGuid().ToString('N')).marker"
    $startInfo.Environment['META_INIT_TEST_HOLD_PREFLIGHT_SECONDS'] = $HoldSeconds.ToString()
    $startInfo.Environment['META_INIT_TEST_PREFLIGHT_MARKER'] = if ($kind -eq 'bash') {
        "./$([IO.Path]::GetFileName($markerPath))"
    }
    else { $markerPath }
    $arguments = if ($kind -eq 'pwsh') {
        @(
            '-NoProfile', '-File', './scripts/init.ps1', '-ProjectName', 'Acme.Metadata',
            '-Author', 'Cross Author', '-AuthorEmail', 'cross@example.invalid',
            '-GitHubOwner', 'cross-owner', '-Description', 'Metadata safety fixture',
            '-Year', '2042', '-KeepScript'
        )
    }
    else {
        $runnerPath = Join-Path $root '.metadata-held-runner.sh'
        $bashMarker = "./$([IO.Path]::GetFileName($markerPath))"
        $runner = @"
#!/usr/bin/env bash
set -euo pipefail
export META_INIT_TEST_HOLD_PREFLIGHT_SECONDS=$HoldSeconds
export META_INIT_TEST_PREFLIGHT_MARKER='$bashMarker'
exec ./scripts/init.sh --project-name Acme.Metadata --author 'Cross Author' \
  --author-email cross@example.invalid --github-owner cross-owner \
  --description 'Metadata safety fixture' --year 2042 --keep-script
"@
        [IO.File]::WriteAllText($runnerPath, $runner.Replace("`r`n", "`n"), $utf8NoBom)
        @('./.metadata-held-runner.sh')
    }
    foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $process.Start() | Out-Null
    return [pscustomobject]@{
        Process = $process
        Stdout = $process.StandardOutput.ReadToEndAsync()
        Stderr = $process.StandardError.ReadToEndAsync()
        RunnerPath = $runnerPath
        MarkerPath = $markerPath
    }
}

function Test-SameEngineRejectionPreservesOwnedTransaction {
    $root = Join-Path $tempRoot 'same-engine-live-bash'
    Copy-Template $root
    $held = Start-HeldInitializer bash $root 15
    $nativeOwnerPid = $null
    try {
        $deadline = (Get-Date).AddSeconds(15)
        while (-not (Test-Path -LiteralPath $held.MarkerPath -PathType Leaf) -and
            (Get-Date) -lt $deadline -and -not $held.Process.HasExited) {
            Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path -LiteralPath $held.MarkerPath -PathType Leaf) 'Bash did not reach the same-engine preflight barrier.'
        $ownerRecord = Read-TestCoordinationRecord (Join-Path $root '.meta-init-transaction.owner')
        $nativeOwnerPid = [int]$ownerRecord.PID
        Assert-True ($nativeOwnerPid -gt 0 -and $nativeOwnerPid -ne $PID) 'Bash published an unsafe native owner PID.'
        $second = Invoke-Initializer bash $root 'Cross Author' 'cross@example.invalid' 'cross-owner' -ExpectFailure
        Assert-True $second.Output.ToLowerInvariant().Contains('another initializer process owns') "Bash did not reject a same-engine contender.`n$($second.Output)"
        Assert-True ($held.Process.WaitForExit(60000)) 'The first Bash initializer did not finish after the same-engine rejection.'
        $output = "$($held.Stdout.GetAwaiter().GetResult())$($held.Stderr.GetAwaiter().GetResult())"
        Assert-True ($held.Process.ExitCode -eq 0) "The rejected Bash contender removed the active transaction state.`n$output"
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'src/Acme.Metadata') -PathType Container) 'The first Bash initializer did not complete its rename after the contender exited.'
    }
    finally {
        if (-not $held.Process.HasExited) { $held.Process.Kill($true); $held.Process.WaitForExit() }
        $held.Process.Dispose()
        if ($IsWindows -and $nativeOwnerPid) {
            $nativeOwner = Get-Process -Id $nativeOwnerPid -ErrorAction SilentlyContinue
            if ($nativeOwner) {
                try {
                    $nativeOwner.Kill($true)
                    Assert-True ($nativeOwner.WaitForExit(5000)) 'Bash native owner did not terminate after the same-engine test.'
                }
                finally { $nativeOwner.Dispose() }
            }
        }
        if ($held.RunnerPath) { Remove-Item -LiteralPath $held.RunnerPath -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $held.MarkerPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-CrossEngineLiveOwner(
    [ValidateSet('pwsh', 'bash')][string]$firstKind,
    [ValidateSet('pwsh', 'bash')][string]$secondKind
) {
    $delimiter = if ($IsWindows) { ';' } else { '|' }
    $root = Join-Path $tempRoot "cross-live$delimiter$firstKind-to-$secondKind"
    $control = Join-Path $tempRoot "cross-live-control-$secondKind"
    Copy-Template $root
    Copy-Template $control
    $before = Get-TreeSnapshot $root
    $held = Start-HeldInitializer $firstKind $root
    $nativeOwnerPid = $null
    try {
        $coordinationPath = Join-Path $root '.meta-init-transaction.owner'
        $deadline = (Get-Date).AddSeconds(15)
        while (-not (Test-Path -LiteralPath $held.MarkerPath -PathType Leaf) -and (Get-Date) -lt $deadline -and -not $held.Process.HasExited) {
            Start-Sleep -Milliseconds 100
        }
        if ($held.Process.HasExited) {
            $output = "$($held.Stdout.GetAwaiter().GetResult())$($held.Stderr.GetAwaiter().GetResult())"
            throw "$firstKind exited before holding the shared coordination lock.`n$output"
        }
        Assert-True (Test-Path -LiteralPath $held.MarkerPath -PathType Leaf) "$firstKind did not reach the deterministic slow-preflight barrier."
        Assert-True (Test-Path -LiteralPath $coordinationPath -PathType Leaf) "$firstKind did not publish the shared coordination owner before preflight."
        $ownerRecord = Read-TestCoordinationRecord $coordinationPath
        $nativeOwnerPid = [int]$ownerRecord.PID
        Assert-True ($nativeOwnerPid -gt 0 -and $nativeOwnerPid -ne $PID) "$firstKind published an unsafe native owner PID."
        if (-not $IsWindows) {
            $expectedNamespace = if ([Environment]::GetEnvironmentVariable('WSL_DISTRO_NAME')) {
                "wsl:$([Environment]::GetEnvironmentVariable('WSL_DISTRO_NAME'))"
            }
            elseif ($IsLinux) { 'linux' } else { 'darwin' }
            $expectedIdentity = if ($IsLinux) { 'linux-proc-start' } else { 'ps-lstart' }
            Assert-Equal '2' $ownerRecord.VERSION "$firstKind did not publish the namespace-aware owner format."
            Assert-Equal $expectedNamespace $ownerRecord.NAMESPACE "$firstKind published the wrong native POSIX process namespace."
            Assert-Equal $expectedIdentity $ownerRecord.IDENTITY_KIND "$firstKind published the wrong native POSIX process-start probe."
        }
        $second = Invoke-Initializer $secondKind $root 'Cross Author' 'cross@example.invalid' 'cross-owner' -ExpectFailure
        Assert-True $second.Output.ToLowerInvariant().Contains('another initializer process owns') "$secondKind did not reject the live $firstKind owner.`n$($second.Output)"
        Assert-Equal $before (Get-TreeSnapshot $root) "$secondKind mutated the tree while $firstKind held the shared lock."
    }
    finally {
        if (-not $held.Process.HasExited) { $held.Process.Kill($true) }
        $held.Process.WaitForExit()
        $held.Process.Dispose()
        if ($IsWindows -and $nativeOwnerPid) {
            $nativeOwner = Get-Process -Id $nativeOwnerPid -ErrorAction SilentlyContinue
            if ($nativeOwner) {
                try {
                    $nativeOwner.Kill($true)
                    Assert-True ($nativeOwner.WaitForExit(5000)) "$firstKind native owner did not terminate after the deterministic test kill."
                }
                finally { $nativeOwner.Dispose() }
            }
        }
        if ($held.RunnerPath) { Remove-Item -LiteralPath $held.RunnerPath -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $held.MarkerPath -Force -ErrorAction SilentlyContinue
    }

    $restart = Invoke-Initializer $secondKind $root 'Cross Author' 'cross@example.invalid' 'cross-owner'
    $null = Invoke-Initializer $secondKind $control 'Cross Author' 'cross@example.invalid' 'cross-owner'
    Assert-Equal '1' "$([regex]::Matches($restart.Output, '(?m)^==> Initializing template').Count)" "$secondKind takeover caused the foreign engine to initialize instead of recovery-only cleanup."
    Assert-Equal (Get-TreeSnapshot $control) (Get-TreeSnapshot $root) "$secondKind did not safely take over the interrupted $firstKind lock."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.meta-init-transaction.owner'))) 'The shared coordination owner remained after a successful takeover.'
}

function Test-CrossEngineInterruptedRecovery(
    [ValidateSet('pwsh', 'bash')][string]$firstKind,
    [ValidateSet('pwsh', 'bash')][string]$secondKind
) {
    $delimiter = if ($IsWindows) { ';' } else { '|' }
    $root = Join-Path $tempRoot "cross-crash$delimiter$firstKind-to-$secondKind"
    $control = Join-Path $tempRoot "cross-crash-control-$secondKind"
    Copy-Template $root
    Copy-Template $control
    $null = Invoke-InitializerAtCrashPhase $firstKind $root content
    $restart = Invoke-Initializer $secondKind $root 'Crash Author' 'crash@example.invalid' 'crash-owner'
    $null = Invoke-Initializer $secondKind $control 'Crash Author' 'crash@example.invalid' 'crash-owner'
    Assert-True $restart.Output.Contains('Recovered an interrupted initialization transaction.') "$secondKind did not invoke compatible $firstKind recovery.`n$($restart.Output)"
    Assert-Equal '1' "$([regex]::Matches($restart.Output, '(?m)^==> Initializing template').Count)" "$secondKind recovery caused both engines to initialize the repository."
    Assert-Equal (Get-TreeSnapshot $control) (Get-TreeSnapshot $root) "$secondKind recovery of interrupted $firstKind journal was not exact."
}

function Test-HostileRecoveryRejected([ValidateSet('pwsh', 'bash')][string]$kind) {
    $root = Join-Path $tempRoot "hostile-recovery-$kind"
    Copy-Template $root
    $null = Invoke-InitializerAtCrashPhase $kind $root content
    $transactionRoot = Get-TransactionPath $kind $root
    $manifestPath = Join-Path $transactionRoot $(if ($kind -eq 'pwsh') { 'manifest.json' } else { 'manifest' })
    Assert-True (Test-Path -LiteralPath $transactionRoot -PathType Container) "$kind crash did not retain its transaction root for hostile-recovery tests."
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) "$kind crash did not retain its recovery manifest."
    $before = Get-TreeSnapshot $root
    $originalManifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)
    $adjacentFiles = [Collections.Generic.List[string]]::new()

    try {
        $schemaVariants = [Collections.Generic.List[object]]::new()
        if ($kind -eq 'pwsh') {
            $manifest = $originalManifest | ConvertFrom-Json
            $manifest.Version = 2
            $schemaVariants.Add(@{ Name = 'wrong-version'; Text = ($manifest | ConvertTo-Json -Depth 8 -Compress) })
            $manifest = $originalManifest | ConvertFrom-Json
            $manifest.Engine = 'bash'
            $schemaVariants.Add(@{ Name = 'wrong-engine'; Text = ($manifest | ConvertTo-Json -Depth 8 -Compress) })
            $manifest = $originalManifest | ConvertFrom-Json
            $manifest | Add-Member -NotePropertyName UnknownRecoveryField -NotePropertyValue 'hostile'
            $schemaVariants.Add(@{ Name = 'unknown-field'; Text = ($manifest | ConvertTo-Json -Depth 8 -Compress) })
            $schemaVariants.Add(@{ Name = 'duplicate-required-field'; Text = ('{"Version":1,' + $originalManifest.Substring(1)) })
        }
        else {
            $schemaVariants.Add(@{ Name = 'wrong-version'; Text = $originalManifest.Replace("VERSION|1`n", "VERSION|2`n") })
            $schemaVariants.Add(@{ Name = 'wrong-engine'; Text = $originalManifest.Replace("ENGINE|bash`n", "ENGINE|pwsh`n") })
            $schemaVariants.Add(@{ Name = 'unknown-record'; Text = "$originalManifest`nUNKNOWN|hostile`n" })
            $rootRecord = [regex]::Match($originalManifest, '(?m)^ROOT\|[^\r\n]+$').Value
            Assert-True ([bool]$rootRecord) 'The Bash hostile fixture has no ROOT record to duplicate.'
            $schemaVariants.Add(@{ Name = 'duplicate-required-record'; Text = "$originalManifest$rootRecord`n" })
        }
        foreach ($variant in $schemaVariants) {
            Write-TestTransactionManifest $manifestPath $variant.Text
            $null = Invoke-HostileRecoveryAttempt $kind $root $before $variant.Name
        }

        $externalRepoPath = Join-Path $tempRoot "hostile-repo-escape-$kind.txt"
        $externalRepoBytes = [Text.Encoding]::UTF8.GetBytes("external repo escape $kind")
        [IO.File]::WriteAllBytes($externalRepoPath, $externalRepoBytes)
        if ($kind -eq 'pwsh') {
            $manifest = $originalManifest | ConvertFrom-Json
            Assert-True (@($manifest.Contents).Count -gt 0) 'The PowerShell hostile fixture has no content entry.'
            $manifest.Contents[0].Path = $externalRepoPath
            $mutated = $manifest | ConvertTo-Json -Depth 8 -Compress
        }
        else {
            $encodedExternal = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($externalRepoPath.Replace('\', '/')))
            $mutated = [regex]::new('(?m)^CONTENT\|[^|]+').Replace($originalManifest, "CONTENT|$encodedExternal", 1)
            Assert-True ($mutated -cne $originalManifest) 'The Bash hostile fixture has no content entry.'
        }
        Write-TestTransactionManifest $manifestPath $mutated
        $null = Invoke-HostileRecoveryAttempt $kind $root $before 'repo-path-escape' @(@{ Path = $externalRepoPath; Bytes = $externalRepoBytes })

        $adjacentName = "meta-init-hostile-backup-$([guid]::NewGuid().ToString('N'))"
        $adjacentBackup = Join-Path (Split-Path -Parent $transactionRoot) $adjacentName
        $adjacentFiles.Add($adjacentBackup)
        $adjacentBytes = [Text.Encoding]::UTF8.GetBytes("external dotdot backup $kind")
        [IO.File]::WriteAllBytes($adjacentBackup, $adjacentBytes)
        if ($kind -eq 'pwsh') {
            $manifest = $originalManifest | ConvertFrom-Json
            $manifest.Contents[0].Backup = $adjacentBackup
            $mutated = $manifest | ConvertTo-Json -Depth 8 -Compress
        }
        else {
            $contentLine = [regex]::Match($originalManifest, '(?m)^CONTENT\|[^\r\n]+$').Value
            Assert-True ([bool]$contentLine) 'The Bash hostile fixture has no content record.'
            $fields = $contentLine -split '\|'
            $fields[2] = "../$adjacentName"
            $mutated = $originalManifest.Replace($contentLine, ($fields -join '|'))
        }
        Write-TestTransactionManifest $manifestPath $mutated
        $null = Invoke-HostileRecoveryAttempt $kind $root $before 'backup-dotdot-escape' @(@{ Path = $adjacentBackup; Bytes = $adjacentBytes })

        Write-TestTransactionManifest $manifestPath $originalManifest
        if ($IsWindows) {
            & icacls.exe $transactionRoot '/grant' '*S-1-1-0:(OI)(CI)R' | Out-Null
            Assert-True ($LASTEXITCODE -eq 0) 'Could not prepare the insecure Windows transaction ACL fixture.'
        }
        else {
            [IO.File]::SetUnixFileMode(
                $transactionRoot,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor
                    [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor
                    [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute
            )
        }
        $null = Invoke-HostileRecoveryAttempt $kind $root $before 'insecure-mode-or-acl'
        Set-TestPrivateTransactionRoot $transactionRoot

        Write-TestTransactionManifest $manifestPath $originalManifest
        if ($kind -eq 'pwsh') {
            $manifest = $originalManifest | ConvertFrom-Json
            $backupPath = [string]$manifest.Contents[0].Backup
        }
        else {
            $contentLine = [regex]::Match($originalManifest, '(?m)^CONTENT\|[^\r\n]+$').Value
            $backupRelative = ($contentLine -split '\|')[2]
            $backupPath = Join-Path $transactionRoot $backupRelative
        }
        $externalLinkPath = Join-Path $tempRoot "hostile-linked-backup-$kind.txt"
        $externalLinkBytes = [Text.Encoding]::UTF8.GetBytes("external linked backup $kind")
        [IO.File]::WriteAllBytes($externalLinkPath, $externalLinkBytes)
        $backupBytes = [IO.File]::ReadAllBytes($backupPath)
        Remove-Item -LiteralPath $backupPath -Force
        $null = New-Item -ItemType HardLink -Path $backupPath -Target $externalLinkPath
        $null = Invoke-HostileRecoveryAttempt $kind $root $before 'backup-hardlink-escape' @(@{ Path = $externalLinkPath; Bytes = $externalLinkBytes })
        Remove-Item -LiteralPath $backupPath -Force
        [IO.File]::WriteAllBytes($backupPath, $backupBytes)
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($backupPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }

        Remove-Item -LiteralPath $manifestPath -Force
        $null = Invoke-HostileRecoveryAttempt $kind $root $before 'ownerless-missing-manifest'
        Write-TestTransactionManifest $manifestPath $originalManifest
        Remove-TestTransactionRoot $transactionRoot
        $externalDirectory = Join-Path $tempRoot "hostile-transaction-link-$kind"
        [IO.Directory]::CreateDirectory($externalDirectory) | Out-Null
        $externalRootSentinel = Join-Path $externalDirectory 'sentinel.txt'
        $externalRootBytes = [Text.Encoding]::UTF8.GetBytes("external transaction root $kind")
        [IO.File]::WriteAllBytes($externalRootSentinel, $externalRootBytes)
        if ($IsWindows) {
            $null = New-Item -ItemType Junction -Path $transactionRoot -Target $externalDirectory
        }
        else {
            $null = New-Item -ItemType SymbolicLink -Path $transactionRoot -Target $externalDirectory
        }
        $null = Invoke-HostileRecoveryAttempt $kind $root $before 'linked-transaction-root' @(@{ Path = $externalRootSentinel; Bytes = $externalRootBytes })
    }
    finally {
        $transactionItem = Get-Item -LiteralPath $transactionRoot -Force -ErrorAction SilentlyContinue
        if ($null -ne $transactionItem -and
            -not ($transactionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            -not $transactionItem.LinkType) {
            Set-TestPrivateTransactionRoot $transactionRoot
        }
        Remove-TestTransactionRoot $transactionRoot
        foreach ($path in $adjacentFiles) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

function Test-LinkedBoundaryRejected([ValidateSet('pwsh', 'bash')][string]$kind) {
    $root = Join-Path $tempRoot "linked-boundary-$kind"
    Copy-Template $root
    $external = Join-Path $tempRoot "linked-boundary-$kind-external.txt"
    $alias = Join-Path $root 'ordinary-linked.txt'
    $payload = [Text.Encoding]::UTF8.GetBytes('external=__ProjectName__; author=__Author__')
    [IO.File]::WriteAllBytes($external, $payload)
    $null = New-Item -ItemType HardLink -Path $alias -Target $external
    $before = Get-TreeSnapshotWithMetadata $root

    $result = Invoke-Initializer $kind $root 'Link Author' 'link@example.invalid' 'link-owner' -ExpectFailure

    Assert-Equal $before (Get-TreeSnapshotWithMetadata $root) "$kind changed the repository before rejecting a hard-linked source."
    Assert-BytesEqual $payload ([IO.File]::ReadAllBytes($external)) "$kind changed the external hard-link peer."
    Assert-True $result.Output.ToLowerInvariant().Contains('hard-link') "$kind did not diagnose the hard-link ownership boundary.`n$($result.Output)"
}

function Test-PowerShellMetadataPreserved {
    $root = Join-Path $tempRoot 'metadata-preservation-pwsh'
    Copy-Template $root
    $path = Join-Path $root 'restricted-tool.txt'
    [IO.File]::WriteAllText($path, 'project=__ProjectName__', $utf8NoBom)
    if ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & icacls.exe $path '/inheritance:r' '/grant:r' "*$sid`:F" | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) 'Could not prepare the restrictive Windows metadata fixture.'
    }
    else {
        [IO.File]::SetUnixFileMode(
            $path,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute
        )
    }
    $beforeMetadata = if ($IsWindows) { (Get-Acl -LiteralPath $path).Sddl } else { [int][IO.File]::GetUnixFileMode($path) }

    $null = Invoke-Initializer 'pwsh' $root 'Mode Author' 'mode@example.invalid' 'mode-owner'

    $afterMetadata = if ($IsWindows) { (Get-Acl -LiteralPath $path).Sddl } else { [int][IO.File]::GetUnixFileMode($path) }
    Assert-Equal "$beforeMetadata" "$afterMetadata" 'PowerShell content replacement did not preserve restrictive file metadata.'
    Assert-Equal 'project=Acme.Metadata' ([IO.File]::ReadAllText($path)) 'PowerShell metadata fixture was not substituted.'
}

function Assert-PrivatePowerShellTransaction([string]$transactionRoot) {
    Assert-True (Test-Path -LiteralPath $transactionRoot -PathType Container) 'The retained PowerShell transaction directory was not found.'
    if ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($path in @($transactionRoot) + @(Get-ChildItem -LiteralPath $transactionRoot -Force -Recurse | ForEach-Object FullName)) {
            $acl = Get-Acl -LiteralPath $path
            $foreignAllows = @($acl.Access | Where-Object {
                if ($_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { return $false }
                $ruleSid = try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
                return $ruleSid -ne $sid
            })
            Assert-True ($foreignAllows.Count -eq 0) "Transaction path '$path' grants access to another identity."
        }
        Assert-True (Get-Acl -LiteralPath $transactionRoot).AreAccessRulesProtected 'The transaction root still inherits a broader ACL.'
    }
    else {
        Assert-Equal '448' "$([int][IO.File]::GetUnixFileMode($transactionRoot))" 'The transaction root is not mode 0700.'
        foreach ($file in Get-ChildItem -LiteralPath $transactionRoot -File -Force -Recurse) {
            Assert-Equal '384' "$([int][IO.File]::GetUnixFileMode($file.FullName))" "Transaction file '$($file.FullName)' is not mode 0600."
        }
    }
}

function Test-PowerShellRollbackFailureIsRetained {
    $root = Join-Path $tempRoot 'rollback-removal-failure-pwsh'
    $control = Join-Path $tempRoot 'rollback-removal-control-pwsh'
    Copy-Template $root
    Copy-Template $control
    $null = Invoke-Initializer 'pwsh' $control 'Rollback Author' 'rollback@example.invalid' 'rollback-owner'
    $expectedCompleted = Get-TreeSnapshotWithMetadata $control
    $transactionRoot = Get-PowerShellTransactionPath $root
    $previousPhase = [Environment]::GetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE')
    $previousRemoval = [Environment]::GetEnvironmentVariable('META_INIT_TEST_FAIL_ROLLBACK_SETTINGS_REMOVE')
    [Environment]::SetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE', 'settings')
    [Environment]::SetEnvironmentVariable('META_INIT_TEST_FAIL_ROLLBACK_SETTINGS_REMOVE', '1')
    try {
        $result = Invoke-Initializer 'pwsh' $root 'Rollback Author' 'rollback@example.invalid' 'rollback-owner' -FailurePhase settings -ExpectFailure
    }
    finally {
        [Environment]::SetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE', $previousPhase)
        [Environment]::SetEnvironmentVariable('META_INIT_TEST_FAIL_ROLLBACK_SETTINGS_REMOVE', $previousRemoval)
    }
    Assert-True $result.Output.ToLowerInvariant().Contains('rollback was incomplete') "PowerShell falsely claimed complete rollback when settings removal failed.`n$($result.Output)"
    Assert-PrivatePowerShellTransaction $transactionRoot

    $restart = Invoke-Initializer 'pwsh' $root 'Rollback Author' 'rollback@example.invalid' 'rollback-owner'
    Assert-True $restart.Output.Contains('Recovered an interrupted initialization transaction.') "PowerShell did not recover the retained rollback journal.`n$($restart.Output)"
    Assert-Equal $expectedCompleted (Get-TreeSnapshotWithMetadata $root) 'PowerShell restart after retained rollback did not produce the exact completed tree.'
}

function Test-BashEnumerationAndReadFailures {
    foreach ($failure in @('find', 'cat')) {
        $root = Join-Path $tempRoot "bash-$failure-failure"
        Copy-Template $root
        if ($failure -eq 'cat') {
            [IO.File]::WriteAllText((Join-Path $root 'read-denied.txt'), 'project=__ProjectName__', $utf8NoBom)
        }
        $shim = Join-Path $root '.metadata-test-shim'
        [IO.Directory]::CreateDirectory($shim) | Out-Null
        if ($failure -eq 'find') {
            $shimText = "find() { echo 'controlled traversal failure' >&2; return 73; }`n"
        }
        else {
            $realCat = (& bash -lc 'command -v cat').Trim()
            $shimText = @"
cat() {
  local args=("`$@") target
  target="`${args[`${#args[@]}-1]}"
  case "`$target" in *read-denied.txt) echo 'controlled read failure' >&2; return 74 ;; esac
  '$realCat' "`$@"
}
"@
        }
        [IO.File]::WriteAllText((Join-Path $shim 'bash-env.sh'), $shimText.Replace("`r`n", "`n"), $utf8NoBom)
        $before = Get-TreeSnapshotWithMetadata $root
        $previousPrefix = [Environment]::GetEnvironmentVariable('META_INIT_TEST_PATH_PREFIX')
        [Environment]::SetEnvironmentVariable('META_INIT_TEST_PATH_PREFIX', '.metadata-test-shim')
        try {
            $result = Invoke-Initializer 'bash' $root 'Failure Author' 'failure@example.invalid' 'failure-owner' -ExpectFailure
        }
        finally { [Environment]::SetEnvironmentVariable('META_INIT_TEST_PATH_PREFIX', $previousPrefix) }
        Assert-Equal $before (Get-TreeSnapshotWithMetadata $root) "Bash changed the tree after a controlled $failure failure."
        $diagnostic = if ($failure -eq 'find') { 'enumeration failed' } else { 'could not read' }
        Assert-True $result.Output.ToLowerInvariant().Contains($diagnostic) "Bash did not fail closed on $failure failure.`n$($result.Output)"
    }
}

function Test-RenameConflictPreflight([ValidateSet('pwsh', 'bash')][string]$kind) {
    $root = Join-Path $tempRoot "rename-conflict-$kind"
    Copy-Template $root
    $conflict = Join-Path $root 'src/Acme.Metadata'
    [IO.Directory]::CreateDirectory($conflict) | Out-Null
    [IO.File]::WriteAllText((Join-Path $conflict 'existing.txt'), 'must survive', $utf8NoBom)
    $before = Get-TreeSnapshot $root

    $result = Invoke-Initializer $kind $root 'Conflict Author' 'conflict@example.invalid' 'conflict-owner' -ExpectFailure
    $after = Get-TreeSnapshot $root

    Assert-Equal $before $after "$kind changed the tree before rejecting a rename destination conflict."
    Assert-True $result.Output.ToLowerInvariant().Contains('already exists') "$kind did not identify the rename destination conflict.`n$($result.Output)"
}

function Test-ScriptCleanup([ValidateSet('pwsh', 'bash')][string]$kind) {
    $root = Join-Path $tempRoot "script-cleanup-$kind"
    Copy-Template $root

    $null = Invoke-Initializer $kind $root 'Cleanup Author' 'cleanup@example.invalid' 'cleanup-owner' -KeepScript $false

    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'scripts/init.ps1'))) "$kind retained scripts/init.ps1 without the keep option."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'scripts/init.sh'))) "$kind retained scripts/init.sh without the keep option."
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    if ($TestScope -eq 'quarantine') {
        foreach ($kind in @('pwsh', 'bash')) {
            Test-QuarantineAuthorSubstitution $kind
            Test-ContentCommitVerification $kind
        }
        Write-Host 'PASS: quarantine author substitution is exact and every staged content commit is verified.' -ForegroundColor Green
        return
    }
    if ($TestScope -eq 'hostile-recovery') {
        foreach ($kind in @('pwsh', 'bash')) { Test-HostileRecoveryRejected $kind }
        Write-Host 'PASS: hostile recovery roots, schemas, paths, and backup links are rejected without repository or external mutation.' -ForegroundColor Green
        return
    }
    if ($TestScope -eq 'cross-engine') {
        Test-CrossEngineLiveOwner pwsh bash
        Test-CrossEngineLiveOwner bash pwsh
        Test-SameEngineRejectionPreservesOwnedTransaction
        Write-Host 'PASS: cross-engine slow-preflight coordination is live-owner safe.' -ForegroundColor Green
        return
    }
    if ($TestScope -eq 'cross-pwsh-bash') {
        Test-CrossEngineLiveOwner pwsh bash
        Write-Host 'PASS: Bash rejects and safely takes over a PowerShell live owner.' -ForegroundColor Green
        return
    }
    if ($TestScope -eq 'cross-bash-pwsh') {
        Test-CrossEngineLiveOwner bash pwsh
        Write-Host 'PASS: PowerShell rejects and safely takes over a Bash live owner.' -ForegroundColor Green
        return
    }
    if ($TestScope -eq 'same-engine') {
        Test-SameEngineRejectionPreservesOwnedTransaction
        Write-Host 'PASS: Bash rejects a same-engine contender without disturbing the owner.' -ForegroundColor Green
        return
    }
    if ($TestScope -eq 'recovery-pwsh-bash') {
        Test-CrossEngineInterruptedRecovery pwsh bash
        Write-Host 'PASS: Bash recovers an interrupted PowerShell transaction.' -ForegroundColor Green
        return
    }
    if ($TestScope -eq 'recovery-bash-pwsh') {
        Test-CrossEngineInterruptedRecovery bash pwsh
        Write-Host 'PASS: PowerShell recovers an interrupted Bash transaction.' -ForegroundColor Green
        return
    }
    if ($TestScope -eq 'failure-io') {
        Test-BashEnumerationAndReadFailures
        Write-Host 'PASS: Bash source enumeration and reads fail closed.' -ForegroundColor Green
        return
    }
    $author = 'A O''Connor "quoted" \ $(touch INIT_AUTHOR_SUBSTITUTION); `touch INIT_AUTHOR_BACKTICK`'
    $authorEmail = 'mail\"$(touch INIT_EMAIL_SUBSTITUTION);`touch INIT_EMAIL_BACKTICK`@example.invalid'
    $githubOwner = 'acme-tools'
    $roots = @{}

    foreach ($kind in @('pwsh', 'bash')) {
        Test-QuarantineAuthorSubstitution $kind
        Test-ContentCommitVerification $kind
    }

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
        Test-ExcludedStatePreserved $kind
        Test-ContentEncodingSafety $kind
        Test-RenameConflictPreflight $kind
        Test-ScriptCleanup $kind
        if ($TestScope -eq 'all') {
            Test-LinkedBoundaryRejected $kind
            Test-NestedRenameStateMachine $kind
            foreach ($phase in @('content', 'rename', 'settings', 'cleanup', 'scripts')) {
                Test-TransactionalFailure $kind $phase
            }
            $crashControl = Join-Path $tempRoot "crash-control-$kind"
            Copy-Template $crashControl
            $null = Invoke-Initializer $kind $crashControl 'Crash Author' 'crash@example.invalid' 'crash-owner'
            $expectedCrashCompletion = Get-TreeSnapshot $crashControl
            foreach ($phase in @('content', 'rename', 'settings', 'cleanup', 'scripts')) {
                Test-CrashRecovery $kind $phase $expectedCrashCompletion
            }
        }
    }

    Test-PowerShellMetadataPreserved
    if ($TestScope -eq 'all') {
        Test-PowerShellRollbackFailureIsRetained
        foreach ($kind in @('pwsh', 'bash')) { Test-HostileRecoveryRejected $kind }
        Test-BashEnumerationAndReadFailures
        Test-CrossEngineLiveOwner pwsh bash
        Test-CrossEngineLiveOwner bash pwsh
        Test-SameEngineRejectionPreservesOwnedTransaction
        Test-CrossEngineInterruptedRecovery pwsh bash
        Test-CrossEngineInterruptedRecovery bash pwsh
        Write-Host 'PASS: metadata and settings initialization are equivalent, idempotent, crash-recoverable, link-safe, permission-preserving, transactional, failure-safe, and injection-safe.' -ForegroundColor Green
    }
    else {
        Write-Host 'PASS: quick metadata initialization checks are equivalent, idempotent, failure-safe, and injection-safe. Use -TestScope all for the exhaustive crash/recovery matrix.' -ForegroundColor Green
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
