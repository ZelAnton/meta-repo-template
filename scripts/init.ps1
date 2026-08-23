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
    [switch]$KeepScript,
    [Parameter(DontShow = $true)]
    [switch]$InternalRecoverOnly,
    [Parameter(DontShow = $true)]
    [string]$InternalRecoveryParentToken
)

$ErrorActionPreference = 'Stop'

if ($ProjectName -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$') {
    throw "Invalid -ProjectName '$ProjectName'. Use letters, digits, underscores; dot-separated segments allowed (e.g. Acme.Widgets)."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$selfPath = $PSCommandPath
$siblingShPath = Join-Path $PSScriptRoot 'init.sh'
$claudeSettings = Join-Path $repoRoot '.claude/settings.json'
$claudeTemplate = Join-Path $repoRoot '.claude/settings.json.template'
$tokenPattern = '__ProjectName__|__AuthorEmailBase64__|__AuthorBase64__|__AuthorEmail__|__Author__|__GitHubOwner__|__Description__|__Year__'
$replacements = $null
$xmlReplacements = $null
$hasExistingClaudeSettings = $false
$xmlFileExtensions = @('.csproj', '.fsproj', '.props', '.targets', '.slnx', '.config')

# Binary files carry no tokens; reading/rewriting them as text would corrupt them.
$binaryExtensions = @('.snk', '.pfx', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.zip', '.jar')

# META(%%): add your build output/cache dirs (e.g. 'target', 'build', '.gradle').
$excludedDirs = @('.git', '.jj', '.work', '.inbox', 'bin', 'obj')

function Test-Excluded([string]$fullPath) {
    $rel = $fullPath.Substring($repoRoot.Length).TrimStart('\', '/')
    if ($rel -in @('.meta-init-transaction.owner', '.meta-init-transaction.recovery') -or
        $rel -like '.meta-init-owner.*.tmp') {
        return $true
    }
    foreach ($seg in ($rel -split '[\\/]')) {
        if ($excludedDirs -contains $seg) { return $true }
    }
    return $false
}

$pathComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$repoBoundary = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/')
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Get-CoordinationRepoIdentity([string]$path) {
    $identity = [IO.Path]::GetFullPath($path).TrimEnd('\', '/').Replace('\', '/')
    if ($IsWindows) {
        return $identity.ToLowerInvariant()
    }
    if ([Environment]::GetEnvironmentVariable('WSL_DISTRO_NAME') -and
        $identity -match '^/mnt/([A-Za-z])(?:/(.*))?$') {
        return ("$($Matches[1].ToLowerInvariant()):/$($Matches[2])").TrimEnd('/').ToLowerInvariant()
    }
    return $identity
}

function ConvertTo-CoordinationField([string]$value) {
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
}

function ConvertFrom-CoordinationField([string]$value) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value))
}

function Get-FileMetadata([string]$path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    $metadata = [ordered]@{ Attributes = [int]$item.Attributes; UnixMode = $null; Sddl = $null }
    if ($IsWindows) {
        $sections = [Security.AccessControl.AccessControlSections]::Access
        $metadata.Sddl = (Get-Acl -LiteralPath $path -ErrorAction Stop).GetSecurityDescriptorSddlForm($sections)
    }
    else {
        $metadata.UnixMode = [int][IO.File]::GetUnixFileMode($path)
    }
    return [pscustomobject]$metadata
}

function Set-FileMetadata([string]$path, [object]$metadata) {
    [IO.File]::SetAttributes($path, [IO.FileAttributes][int]$metadata.Attributes)
    if ($IsWindows) {
        $sections = [Security.AccessControl.AccessControlSections]::Access
        $security = Get-Acl -LiteralPath $path -ErrorAction Stop
        if ($security.GetSecurityDescriptorSddlForm($sections) -cne [string]$metadata.Sddl) {
            $security.SetSecurityDescriptorSddlForm([string]$metadata.Sddl, $sections)
            Set-Acl -LiteralPath $path -AclObject $security -ErrorAction Stop
        }
    }
    else {
        [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode][int]$metadata.UnixMode)
    }
}

function Test-FileMetadata([string]$path, [object]$metadata) {
    $actual = Get-FileMetadata $path
    if ([int]$actual.Attributes -ne [int]$metadata.Attributes) { return $false }
    if ($IsWindows) { return [string]$actual.Sddl -ceq [string]$metadata.Sddl }
    return [int]$actual.UnixMode -eq [int]$metadata.UnixMode
}

function Test-FileBytesEqual([string]$left, [string]$right) {
    $leftInfo = Get-Item -LiteralPath $left -Force -ErrorAction Stop
    $rightInfo = Get-Item -LiteralPath $right -Force -ErrorAction Stop
    if ($leftInfo.Length -ne $rightInfo.Length) { return $false }
    $leftHash = (Get-FileHash -LiteralPath $left -Algorithm SHA256).Hash
    $rightHash = (Get-FileHash -LiteralPath $right -Algorithm SHA256).Hash
    return $leftHash -ceq $rightHash
}

function Copy-PrivateFile([string]$source, [string]$destination) {
    $bytes = [IO.File]::ReadAllBytes($source)
    $stream = [IO.FileStream]::new(
        $destination,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($destination, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        if ([int][IO.File]::GetUnixFileMode($destination) -ne 384) {
            throw "Could not restrict transaction file '$destination' to mode 0600. No source files were changed."
        }
    }
}

function Set-PrivateTransactionDirectory([string]$path) {
    [IO.Directory]::CreateDirectory($path) | Out-Null
    if ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & icacls.exe $path '/inheritance:r' '/grant:r' "*$sid`:(OI)(CI)F" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not restrict transaction directory '$path'. No source files were changed." }
        $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
        $hasOwnerRule = @($acl.Access | Where-Object {
            $ruleSid = try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
            -not $_.IsInherited -and $ruleSid -eq $sid -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl)
        }).Count -gt 0
        if (-not $acl.AreAccessRulesProtected -or -not $hasOwnerRule) {
            throw "Transaction directory '$path' is not private. No source files were changed."
        }
    }
    else {
        $privateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute
        [IO.File]::SetUnixFileMode($path, $privateMode)
        if ([int][IO.File]::GetUnixFileMode($path) -ne 448) {
            throw "Could not restrict transaction directory '$path' to mode 0700. No source files were changed."
        }
    }
}

function Write-DurableText([string]$path, [string]$value) {
    $temporary = "$path.new"
    $bytes = [Text.Encoding]::UTF8.GetBytes($value)
    $stream = [IO.FileStream]::new(
        $temporary,
        [IO.FileMode]::Create,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($temporary, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
    [IO.File]::Move($temporary, $path, $true)
    if (-not $IsWindows) { & sync }
}

function Get-LinkCount([string]$path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.LinkType -eq 'HardLink') {
        return 2
    }
    if ($IsWindows) {
        $lines = @(& fsutil.exe hardlink list $path 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "Could not inspect hard-link ownership for '$path'. No files were changed." }
        return @($lines | Where-Object { $_.ToString().Trim().Length -gt 0 }).Count
    }
    $value = & stat -c '%h' -- $path 2>$null
    if ($LASTEXITCODE -ne 0) { $value = & stat -f '%l' -- $path 2>$null }
    if ($LASTEXITCODE -ne 0 -or $value -notmatch '^\d+$') {
        throw "Could not inspect hard-link ownership for '$path'. No files were changed."
    }
    return [int]$value
}

function Assert-OwnedPath([string]$path, [string]$purpose, [switch]$RegularFile) {
    $fullPath = [IO.Path]::GetFullPath($path)
    if (-not ($pathComparer.Equals($fullPath, $repoBoundary) -or
        $fullPath.StartsWith("$repoBoundary$([IO.Path]::DirectorySeparatorChar)", $pathComparison))) {
        throw "The $purpose path '$path' escapes the repository. No files were changed."
    }
    $cursor = $fullPath
    while (-not $pathComparer.Equals($cursor, $repoBoundary)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ($item.LinkType -and $item.LinkType -ne 'HardLink')) {
            throw "The $purpose path '$path' uses a symbolic/reparse link. No files were changed."
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    if ($RegularFile) {
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if ($item.PSIsContainer) { throw "The $purpose path '$path' is not a regular file. No files were changed." }
        if ((Get-LinkCount $fullPath) -ne 1) {
            throw "The $purpose path '$path' is hard-linked and is not independently owned. No files were changed."
        }
    }
}

$transactionParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
if ($pathComparer.Equals($transactionParent, $repoBoundary) -or
    $transactionParent.StartsWith("$repoBoundary$([IO.Path]::DirectorySeparatorChar)", $pathComparison)) {
    throw 'The temporary directory must be outside the repository. No files were changed.'
}
$repoHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($repoBoundary))).ToLowerInvariant()
$transactionRoot = Join-Path $transactionParent "meta-init-transaction-$repoHash-pwsh"
$manifestPath = Join-Path $transactionRoot 'manifest.json'
$coordinationPath = Join-Path $repoRoot '.meta-init-transaction.owner'
$coordinationRecoveryPath = Join-Path $repoRoot '.meta-init-transaction.recovery'
$coordinationRepoIdentity = Get-CoordinationRepoIdentity $repoBoundary
$coordinationToken = [guid]::NewGuid().ToString('N')
$ownsCoordination = $false
$ownsRecoveryClaim = $false
$recoveryOnly = $InternalRecoverOnly -or [Environment]::GetEnvironmentVariable('META_INIT_RECOVER_ONLY') -eq '1'

function Get-CurrentProcessNamespace {
    if ($IsWindows) { return 'windows' }
    if ($IsLinux) {
        $distro = [Environment]::GetEnvironmentVariable('WSL_DISTRO_NAME')
        if ($distro) { return "wsl:$distro" }
        return 'linux'
    }
    if ($IsMacOS) { return 'darwin' }
    throw 'This platform cannot provide a supported process namespace for initializer coordination.'
}

function Get-LinuxProcessStart([int]$processId) {
    $statPath = "/proc/$processId/stat"
    if (-not (Test-Path -LiteralPath $statPath -PathType Leaf)) { return $null }
    $line = [IO.File]::ReadAllText($statPath)
    $close = $line.LastIndexOf(') ')
    if ($close -lt 0) { throw "Could not parse Linux process identity for PID $processId." }
    $fields = @($line.Substring($close + 2) -split '\s+' | Where-Object { $_ })
    if ($fields.Count -lt 20) { throw "Could not parse Linux process identity for PID $processId." }
    return [string]$fields[19]
}

function Get-CurrentCoordinationIdentity {
    $namespace = Get-CurrentProcessNamespace
    if ($namespace -eq 'windows') {
        return [pscustomobject]@{
            Namespace = $namespace
            Kind = 'dotnet-start-ticks'
            Value = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().Ticks.ToString()
        }
    }
    if ($namespace -eq 'linux' -or $namespace.StartsWith('wsl:', [StringComparison]::Ordinal)) {
        $identity = Get-LinuxProcessStart $PID
        if (-not $identity) { throw 'Could not establish a Linux process-start identity for initializer coordination.' }
        return [pscustomobject]@{ Namespace = $namespace; Kind = 'linux-proc-start'; Value = $identity }
    }
    $identity = (& ps -p $PID -o lstart= 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $identity) {
        throw 'Could not establish a POSIX process-start identity for initializer coordination.'
    }
    return [pscustomobject]@{ Namespace = $namespace; Kind = 'ps-lstart'; Value = $identity.Trim() }
}

$coordinationIdentity = Get-CurrentCoordinationIdentity

function Read-CoordinationRecord([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        $separator = $line.IndexOf('|')
        if ($separator -le 0) { throw "The initializer coordination owner record is malformed. Refusing unsafe recovery." }
        $key = $line.Substring(0, $separator)
        if ($values.ContainsKey($key)) { throw "The initializer coordination owner record repeats '$key'. Refusing unsafe recovery." }
        $values[$key] = $line.Substring($separator + 1)
    }
    foreach ($required in @('VERSION', 'ENGINE', 'ROOT', 'PID', 'NAMESPACE', 'IDENTITY_KIND', 'IDENTITY', 'TOKEN')) {
        if (-not $values.ContainsKey($required)) { throw "The initializer coordination owner record lacks '$required'. Refusing unsafe recovery." }
    }
    if ($values.VERSION -ne '2') { throw "Unsupported initializer coordination owner version '$($values.VERSION)'." }
    try {
        $owner = [pscustomobject]@{
            Engine = ConvertFrom-CoordinationField $values.ENGINE
            RepoIdentity = ConvertFrom-CoordinationField $values.ROOT
            Pid = [int](ConvertFrom-CoordinationField $values.PID)
            Namespace = ConvertFrom-CoordinationField $values.NAMESPACE
            IdentityKind = ConvertFrom-CoordinationField $values.IDENTITY_KIND
            Identity = ConvertFrom-CoordinationField $values.IDENTITY
            Token = ConvertFrom-CoordinationField $values.TOKEN
        }
    }
    catch { throw "The initializer coordination owner record cannot be decoded safely. Refusing recovery." }
    if ($owner.Engine -notin @('pwsh', 'bash') -or $owner.Pid -le 0 -or -not $owner.Token) {
        throw "The initializer coordination owner record contains invalid values. Refusing recovery."
    }
    if ($owner.RepoIdentity -cne $coordinationRepoIdentity) {
        throw "The initializer coordination owner belongs to a different repository. Refusing recovery."
    }
    return $owner
}

function Test-CoordinationOwnerAlive([object]$owner) {
    $currentNamespace = Get-CurrentProcessNamespace
    switch ([string]$owner.IdentityKind) {
        'dotnet-start-ticks' {
            if ($owner.Namespace -ne 'windows' -or $currentNamespace -ne 'windows') {
                throw "Cannot inspect a Windows coordination owner from process namespace '$currentNamespace'. Refusing unsafe recovery."
            }
            $process = Get-Process -Id ([int]$owner.Pid) -ErrorAction SilentlyContinue
            if ($null -eq $process) { return $false }
            return $process.StartTime.ToUniversalTime().Ticks -eq [long]$owner.Identity
        }
        'linux-proc-start' {
            $actual = $null
            if ($owner.Namespace -ceq $currentNamespace -and
                ($currentNamespace -eq 'linux' -or $currentNamespace.StartsWith('wsl:', [StringComparison]::Ordinal))) {
                $actual = Get-LinuxProcessStart ([int]$owner.Pid)
            }
            elseif ($IsWindows -and $owner.Namespace.StartsWith('wsl:', [StringComparison]::Ordinal)) {
                $distro = $owner.Namespace.Substring(4)
                if (-not $distro) { throw 'The WSL coordination namespace is malformed. Refusing unsafe recovery.' }
                $probe = 'pid=' + ([int]$owner.Pid).ToString() + '; line=$(cat "/proc/$pid/stat" 2>/dev/null) || exit 3; tail=${line##*) }; set -- $tail; [ "$#" -ge 20 ] || exit 4; printf "%s" "${20}"'
                $actual = & wsl.exe --distribution $distro --exec bash -c $probe 2>$null
                if ($LASTEXITCODE -eq 3) { return $false }
                if ($LASTEXITCODE -ne 0) { throw "Could not inspect the live-owner identity in WSL namespace '$distro'. Refusing unsafe recovery." }
                $actual = $actual.Trim()
            }
            else {
                throw "Cannot inspect Linux coordination namespace '$($owner.Namespace)' from '$currentNamespace'. Refusing unsafe recovery."
            }
            if ($null -eq $actual) { return $false }
            return [string]$actual -ceq [string]$owner.Identity
        }
        'ps-lstart' {
            if ($owner.Namespace -ne 'darwin' -or $currentNamespace -ne 'darwin') {
                throw "Cannot inspect POSIX coordination namespace '$($owner.Namespace)' from '$currentNamespace'. Refusing unsafe recovery."
            }
            $actual = (& ps -p ([int]$owner.Pid) -o lstart= 2>$null)
            if ($LASTEXITCODE -ne 0) { return $false }
            if (-not $actual) { throw 'The POSIX process-start probe returned no identity. Refusing unsafe recovery.' }
            return $actual.Trim() -ceq [string]$owner.Identity
        }
        default { throw "Unsupported initializer process identity '$($owner.IdentityKind)'. Refusing unsafe recovery." }
    }
}

function New-CoordinationRecord([string]$path) {
    $temporary = Join-Path $repoRoot ".meta-init-owner.$coordinationToken.$([guid]::NewGuid().ToString('N')).tmp"
    $lines = @(
        'VERSION|2'
        "ENGINE|$(ConvertTo-CoordinationField 'pwsh')"
        "ROOT|$(ConvertTo-CoordinationField $coordinationRepoIdentity)"
        "PID|$(ConvertTo-CoordinationField $PID.ToString())"
        "NAMESPACE|$(ConvertTo-CoordinationField $coordinationIdentity.Namespace)"
        "IDENTITY_KIND|$(ConvertTo-CoordinationField $coordinationIdentity.Kind)"
        "IDENTITY|$(ConvertTo-CoordinationField $coordinationIdentity.Value)"
        "TOKEN|$(ConvertTo-CoordinationField $coordinationToken)"
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
    $stream = [IO.FileStream]::new(
        $temporary,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($temporary, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
    try {
        [IO.File]::Move($temporary, $path, $false)
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw "Another initializer process acquired the repository coordination lock. No files were changed."
    }
}

function New-CoordinationOwner {
    New-CoordinationRecord $coordinationPath
    $script:ownsCoordination = $true
}

function New-RecoveryClaim {
    New-CoordinationRecord $coordinationRecoveryPath
    $script:ownsRecoveryClaim = $true
}

function Remove-RecoveryClaim {
    if (-not $ownsRecoveryClaim -or -not (Test-Path -LiteralPath $coordinationRecoveryPath -PathType Leaf)) { return }
    try {
        $claim = Read-CoordinationRecord $coordinationRecoveryPath
        if ($null -ne $claim -and $claim.Token -ceq $coordinationToken) {
            Remove-Item -LiteralPath $coordinationRecoveryPath -Force -ErrorAction Stop
        }
    }
    finally { $script:ownsRecoveryClaim = $false }
}

function Remove-CoordinationOwner {
    if (-not $ownsCoordination -or -not (Test-Path -LiteralPath $coordinationPath -PathType Leaf)) { return }
    try {
        $owner = Read-CoordinationRecord $coordinationPath
        if ($null -ne $owner -and $owner.Token -ceq $coordinationToken) {
            Remove-Item -LiteralPath $coordinationPath -Force -ErrorAction Stop
        }
    }
    finally { $script:ownsCoordination = $false }
}

function Restore-Transaction([object]$manifest) {
    $errors = [Collections.Generic.List[string]]::new()
    if ([string]$manifest.RepoRoot -cne $repoBoundary) {
        throw "Recovery journal '$transactionRoot' belongs to a different repository."
    }
    if ([string]$manifest.State -eq 'committed') {
        foreach ($path in @($manifest.DeferredCleanup)) {
            try {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            }
            catch { $errors.Add("deferred cleanup '$path': $($_.Exception.Message)") }
        }
    }
    elseif ([string]$manifest.State -eq 'prepared') {
        foreach ($entry in @($manifest.Cleanup)) {
            try {
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([string]$entry.Path)) | Out-Null
                [IO.File]::WriteAllBytes([string]$entry.Path, [IO.File]::ReadAllBytes([string]$entry.Backup))
                Set-FileMetadata ([string]$entry.Path) $entry.Metadata
            }
            catch { $errors.Add("cleanup restore '$($entry.Path)': $($_.Exception.Message)") }
        }
        if ($manifest.EnsureDocsDirectory) {
            try { [IO.Directory]::CreateDirectory([string]$manifest.EnsureDocsDirectory) | Out-Null }
            catch { $errors.Add("docs restore: $($_.Exception.Message)") }
        }
        if ($null -ne $manifest.Settings) {
            $entry = $manifest.Settings
            try {
                if (Test-Path -LiteralPath ([string]$entry.Destination)) {
                    if (-not (Test-FileBytesEqual ([string]$entry.Destination) ([string]$entry.Backup))) {
                        throw 'the destination does not match the transaction copy'
                    }
                    if ([Environment]::GetEnvironmentVariable('META_INIT_TEST_FAIL_ROLLBACK_SETTINGS_REMOVE') -eq '1') {
                        throw 'controlled failure removing the activated settings destination'
                    }
                    Remove-Item -LiteralPath ([string]$entry.Destination) -Force -ErrorAction Stop
                    if (Test-Path -LiteralPath ([string]$entry.Destination)) {
                        throw 'the activated settings destination still exists after removal'
                    }
                }
                [IO.File]::WriteAllBytes([string]$entry.Template, [IO.File]::ReadAllBytes([string]$entry.Backup))
                Set-FileMetadata ([string]$entry.Template) $entry.Metadata
            }
            catch { $errors.Add("settings restore: $($_.Exception.Message)") }
        }
        $renames = @($manifest.Renames)
        for ($index = $renames.Count - 1; $index -ge 0; $index--) {
            $entry = $renames[$index]
            try {
                $sourceExists = Test-Path -LiteralPath ([string]$entry.Source)
                $destinationExists = Test-Path -LiteralPath ([string]$entry.Destination)
                if ($sourceExists -and $destinationExists) { throw 'both source and destination exist' }
                if ($destinationExists) {
                    Rename-Item -LiteralPath ([string]$entry.Destination) -NewName ([IO.Path]::GetFileName([string]$entry.Source)) -ErrorAction Stop
                }
                elseif (-not $sourceExists) { throw 'neither source nor destination exists' }
            }
            catch { $errors.Add("rename restore '$($entry.Source)': $($_.Exception.Message)") }
        }
        foreach ($entry in @($manifest.Contents)) {
            try {
                [IO.File]::WriteAllBytes([string]$entry.Path, [IO.File]::ReadAllBytes([string]$entry.Backup))
                Set-FileMetadata ([string]$entry.Path) $entry.Metadata
            }
            catch { $errors.Add("content restore '$($entry.Path)': $($_.Exception.Message)") }
        }

        foreach ($entry in @($manifest.Contents) + @($manifest.Cleanup)) {
            try {
                if (-not (Test-FileBytesEqual ([string]$entry.Path) ([string]$entry.Backup)) -or
                    -not (Test-FileMetadata ([string]$entry.Path) $entry.Metadata)) {
                    throw 'bytes or metadata differ from the durable backup'
                }
            }
            catch { $errors.Add("restore verification '$($entry.Path)': $($_.Exception.Message)") }
        }
        if ($null -ne $manifest.Settings) {
            try {
                if (Test-Path -LiteralPath ([string]$manifest.Settings.Destination)) { throw 'destination still exists' }
                if (-not (Test-FileBytesEqual ([string]$manifest.Settings.Template) ([string]$manifest.Settings.Backup))) {
                    throw 'template bytes differ from the durable backup'
                }
            }
            catch { $errors.Add("settings verification: $($_.Exception.Message)") }
        }
    }
    else { $errors.Add("unsupported journal state '$($manifest.State)'") }

    if ($errors.Count -gt 0) {
        throw "Automatic recovery was incomplete. Private backups remain at '$transactionRoot'. $($errors -join ' | ')"
    }
    Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction Stop
    Write-Host '    Recovered an interrupted initialization transaction.' -ForegroundColor Yellow
}

function Invoke-BashRecoveryOnly {
    if (-not (Test-Path -LiteralPath $siblingShPath -PathType Leaf)) {
        throw 'The Bash initializer required for cross-engine recovery is unavailable.'
    }
    $saved = @{}
    foreach ($name in @(
        'META_INIT_RECOVER_ONLY', 'META_INIT_TEST_FAIL_PHASE', 'META_INIT_TEST_CRASH_PHASE',
        'META_INIT_TEST_FAIL_RENAME_SOURCE', 'META_INIT_TEST_CRASH_RENAME_SOURCE',
        'META_INIT_TEST_HOLD_AFTER_LOCK_SECONDS', 'META_INIT_TEST_HOLD_PREFLIGHT_SECONDS',
        'META_INIT_TEST_PREFLIGHT_MARKER', 'META_INIT_TEST_SKIP_CONTENT_PATH',
        'META_INIT_RECOVERY_PARENT_TOKEN'
    )) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    [Environment]::SetEnvironmentVariable('META_INIT_RECOVER_ONLY', '1')
    [Environment]::SetEnvironmentVariable('META_INIT_RECOVERY_PARENT_TOKEN', $coordinationToken)
    try {
        Push-Location $repoRoot
        try {
            $arguments = @(
                './scripts/init.sh', '--project-name', $ProjectName, '--keep-script',
                '--internal-recover-only', '--internal-recovery-parent-token', $coordinationToken
            )
            $bashRecords = @(& bash @arguments 2>&1)
            $bashExitCode = $LASTEXITCODE
            if ($bashExitCode -ne 0) {
                $bashOutput = ($bashRecords | ForEach-Object { $_.ToString() }) -join "`n"
                throw "Bash recovery exited with code $bashExitCode.`n$bashOutput"
            }
            $bashRecords | Write-Output
        }
        finally { Pop-Location }
    }
    finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}

function Invoke-NativeRecovery {
    if (Test-Path -LiteralPath $transactionRoot) {
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $existingManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
            Restore-Transaction $existingManifest
        }
        else { Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction Stop }
    }
}

function Enter-CoordinationAndRecover {
    $existingClaim = Read-CoordinationRecord $coordinationRecoveryPath
    if ($null -ne $existingClaim) {
        if (Test-CoordinationOwnerAlive $existingClaim) {
            throw 'Another initializer process owns repository recovery. No files were changed.'
        }
        $confirmedClaim = Read-CoordinationRecord $coordinationRecoveryPath
        if ($null -ne $confirmedClaim -and $confirmedClaim.Token -ceq $existingClaim.Token) {
            Remove-Item -LiteralPath $coordinationRecoveryPath -Force -ErrorAction Stop
        }
    }

    $existingOwner = Read-CoordinationRecord $coordinationPath
    if ($null -ne $existingOwner -and (Test-CoordinationOwnerAlive $existingOwner)) {
        throw 'Another initializer process owns the active repository transaction. No files were changed.'
    }
    $needsRecovery = $null -ne $existingOwner -or (Test-Path -LiteralPath $transactionRoot)
    if (-not $needsRecovery) {
        New-CoordinationOwner
        return
    }

    New-RecoveryClaim
    try {
        $confirmedOwner = Read-CoordinationRecord $coordinationPath
        if ($null -ne $existingOwner) {
            if ($null -ne $confirmedOwner -and $confirmedOwner.Token -cne $existingOwner.Token) {
                throw 'The initializer coordination owner changed during recovery acquisition. Refusing unsafe recovery.'
            }
            if ($null -ne $confirmedOwner) {
                if (Test-CoordinationOwnerAlive $confirmedOwner) {
                    throw 'Another initializer process owns the active repository transaction. No files were changed.'
                }
                Remove-Item -LiteralPath $coordinationPath -Force -ErrorAction Stop
            }
        }
        elseif ($null -ne $confirmedOwner) {
            throw 'Another initializer process acquired the repository coordination lock. No files were changed.'
        }

        New-CoordinationOwner
        if ($null -ne $existingOwner -and $existingOwner.Engine -eq 'bash') {
            Invoke-BashRecoveryOnly
        }
        Invoke-NativeRecovery
    }
    finally { Remove-RecoveryClaim }
}

if ($recoveryOnly) {
    $parentToken = if ($InternalRecoveryParentToken) {
        $InternalRecoveryParentToken
    }
    else { [Environment]::GetEnvironmentVariable('META_INIT_RECOVERY_PARENT_TOKEN') }
    if (-not $parentToken) { throw 'Recovery-only mode requires an active parent coordination token.' }
    $parentOwner = Read-CoordinationRecord $coordinationPath
    if ($null -eq $parentOwner -or $parentOwner.Token -cne $parentToken -or
        -not (Test-CoordinationOwnerAlive $parentOwner)) {
        throw 'Recovery-only mode could not validate the active parent coordination owner.'
    }
    Invoke-NativeRecovery
    return
}

try {
    Enter-CoordinationAndRecover

    # Repository-derived defaults and every source-tree snapshot are taken only after
    # this process owns the cross-engine coordination boundary and recovery has finished.
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
    # META(%%): XML-manifest languages (.NET: .csproj/.fsproj/.props) must XML-escape
    # values written into those files. Non-XML languages can use an empty extension list.
    $xmlReplacements = [ordered]@{}
    foreach ($key in $replacements.Keys) {
        $xmlReplacements[$key] = $replacements[$key].Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    }
    $hasExistingClaudeSettings = Test-Path -LiteralPath $claudeSettings

$failurePhase = [Environment]::GetEnvironmentVariable('META_INIT_TEST_FAIL_PHASE')
$validFailurePhases = @('content', 'rename', 'settings', 'cleanup', 'scripts')
if ($failurePhase -and $failurePhase -notin $validFailurePhases) {
    throw "Invalid META_INIT_TEST_FAIL_PHASE '$failurePhase'. No files were changed."
}

function Invoke-ControlledFailure([string]$phase) {
    $renameSource = [Environment]::GetEnvironmentVariable('META_INIT_TEST_FAIL_RENAME_SOURCE')
    $actualSource = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
    if ($failurePhase -eq $phase -and
        ($phase -ne 'rename' -or -not $renameSource -or $actualSource -ceq $renameSource)) {
        throw "Controlled test failure after $phase phase."
    }
}

$crashPhase = [Environment]::GetEnvironmentVariable('META_INIT_TEST_CRASH_PHASE')
if ($crashPhase -and $crashPhase -notin $validFailurePhases) {
    throw "Invalid META_INIT_TEST_CRASH_PHASE '$crashPhase'. No files were changed."
}
$crashTriggered = $false
function Invoke-ControlledCrash([string]$phase) {
    $renameSource = [Environment]::GetEnvironmentVariable('META_INIT_TEST_CRASH_RENAME_SOURCE')
    $actualSource = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
    if (-not $crashTriggered -and $crashPhase -eq $phase -and
        ($phase -ne 'rename' -or -not $renameSource -or $actualSource -ceq $renameSource)) {
        $script:crashTriggered = $true
        Stop-Process -Id $PID -Force
        [Environment]::FailFast("Controlled abrupt termination during $phase phase.")
    }
}

# Preflight computes every mutation before the source tree is touched. The complete
# content plan is kept in memory; backups and rewritten files are staged outside the
# repository after path conflicts and mandatory inputs have been checked.
if (-not (Test-Path -LiteralPath $selfPath -PathType Leaf)) {
    throw 'The PowerShell initializer is not available as a regular file. No files were changed.'
}
$holdSecondsText = [Environment]::GetEnvironmentVariable('META_INIT_TEST_HOLD_PREFLIGHT_SECONDS')
if ($holdSecondsText) {
    $holdSeconds = 0
    if (-not [int]::TryParse($holdSecondsText, [ref]$holdSeconds) -or $holdSeconds -lt 1 -or $holdSeconds -gt 60) {
        throw 'META_INIT_TEST_HOLD_PREFLIGHT_SECONDS must be an integer from 1 through 60.'
    }
    $markerPath = [Environment]::GetEnvironmentVariable('META_INIT_TEST_PREFLIGHT_MARKER')
    if ($markerPath) { [IO.File]::WriteAllText($markerPath, 'preflight', $utf8NoBom) }
    Start-Sleep -Seconds $holdSeconds
}

$contentPlan = [Collections.Generic.List[object]]::new()
$allEntries = @(Get-ChildItem -Path $repoRoot -Recurse -Force -ErrorAction Stop | Where-Object {
    -not (Test-Excluded $_.FullName)
})
foreach ($entry in $allEntries) {
    Assert-OwnedPath $entry.FullName 'source-tree' -RegularFile:(-not $entry.PSIsContainer)
}
$files = $allEntries | Where-Object {
    -not $_.PSIsContainer -and
    $_.FullName -ne $selfPath -and
    $_.FullName -ne $siblingShPath -and
    $_.FullName -ne $claudeSettings
}
foreach ($file in $files) {
    if ($binaryExtensions -contains $file.Extension) { continue }
    $text = [IO.File]::ReadAllText($file.FullName)
    $map = if ($xmlFileExtensions -contains $file.Extension) { $xmlReplacements } else { $replacements }
    # A single pass prevents a replacement value that resembles another token from
    # being interpreted as template syntax.
    $new = [regex]::Replace($text, $tokenPattern, { param($match) [string]$map[$match.Value] })
    if ($new -cne $text) {
        $contentPlan.Add([pscustomobject]@{
            Path = $file.FullName
            Content = $new
            Metadata = Get-FileMetadata $file.FullName
        })
    }
}

$renameDestinations = [Collections.Generic.HashSet[string]]::new($pathComparer)
$renamePlan = [Collections.Generic.List[object]]::new()
$named = $allEntries | Where-Object { $_.Name -like '*__ProjectName__*' } |
    Sort-Object { $_.FullName.Length } -Descending
foreach ($item in $named) {
    $newName = $item.Name.Replace('__ProjectName__', $ProjectName)
    $destination = Join-Path (Split-Path -Parent $item.FullName) $newName
    $canonicalDestination = [IO.Path]::GetFullPath($destination)
    if (-not $renameDestinations.Add($canonicalDestination)) {
        throw "Multiple template paths would be renamed to '$destination'. No files were changed."
    }
    if (Test-Path -LiteralPath $destination) {
        throw "Cannot rename '$($item.FullName)' because '$destination' already exists. No files were changed."
    }
    $renamePlan.Add([pscustomobject]@{
        Source = $item.FullName
        Destination = $destination
        OldName = $item.Name
        NewName = $newName
    })
}

$settingsWillActivate = -not $hasExistingClaudeSettings -and (Test-Path -LiteralPath $claudeTemplate)
if ($settingsWillActivate -and -not (Test-Path -LiteralPath $claudeTemplate -PathType Leaf)) {
    throw 'The settings template is not a regular file. No files were changed.'
}
if ($settingsWillActivate) { Assert-OwnedPath $claudeTemplate 'settings-template' -RegularFile }

$templateOnly = @(
    (Join-Path $repoRoot 'TEMPLATE.md'),
    (Join-Path $repoRoot 'docs/AGENT-INIT-GUIDE.md'),
    (Join-Path $repoRoot 'tests/init-metadata.tests.ps1')
)
$cleanupPlan = [Collections.Generic.List[string]]::new()
foreach ($path in $templateOnly + $(if ($KeepScript) { @() } else { @($siblingShPath, $selfPath) })) {
    if (Test-Path -LiteralPath $path) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Cannot remove '$path' because it is not a regular file. No files were changed."
        }
        Assert-OwnedPath $path 'cleanup' -RegularFile
        $cleanupPlan.Add($path)
    }
}
$stagedContent = [Collections.Generic.List[object]]::new()
$cleanupBackups = [Collections.Generic.List[object]]::new()
$transactionActive = $false
$ownsTransaction = $false
$deferredCleanup = @($cleanupPlan | Where-Object { $_ -eq $selfPath })
$scriptCleanup = @($cleanupPlan | Where-Object { $_ -eq $siblingShPath })
$transactionalCleanup = @($cleanupPlan)
$manifest = $null

    Set-PrivateTransactionDirectory $transactionRoot
    $ownsTransaction = $true
    $contentBackupDir = Join-Path $transactionRoot 'content-backup'
    $contentStageDir = Join-Path $transactionRoot 'content-stage'
    $cleanupBackupDir = Join-Path $transactionRoot 'cleanup-backup'
    foreach ($directory in @($contentBackupDir, $contentStageDir, $cleanupBackupDir)) {
        Set-PrivateTransactionDirectory $directory
    }
    for ($index = 0; $index -lt $contentPlan.Count; $index++) {
        $entry = $contentPlan[$index]
        $name = $index.ToString('D8')
        $backup = Join-Path $contentBackupDir $name
        $stage = Join-Path $contentStageDir $name
        Copy-PrivateFile $entry.Path $backup
        [IO.File]::WriteAllText($stage, $entry.Content, $utf8NoBom)
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($stage, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        $stagedContent.Add([pscustomobject]@{
            Path = $entry.Path
            Backup = $backup
            Stage = $stage
            Metadata = $entry.Metadata
        })
    }

    for ($index = 0; $index -lt $transactionalCleanup.Count; $index++) {
        $path = $transactionalCleanup[$index]
        $backup = Join-Path $cleanupBackupDir $index.ToString('D8')
        $metadata = Get-FileMetadata $path
        Copy-PrivateFile $path $backup
        $cleanupBackups.Add([pscustomobject]@{ Path = $path; Backup = $backup; Metadata = $metadata })
    }

    $settingsBackup = $null
    $settingsEntry = $null
    if ($settingsWillActivate) {
        $settingsBackup = Join-Path $transactionRoot 'settings-template'
        $settingsMetadata = Get-FileMetadata $claudeTemplate
        Copy-PrivateFile $claudeTemplate $settingsBackup
        $settingsEntry = [pscustomobject]@{
            Template = $claudeTemplate
            Destination = $claudeSettings
            Backup = $settingsBackup
            Metadata = $settingsMetadata
        }
    }

    $docsDir = Join-Path $repoRoot 'docs'
    $manifest = [pscustomobject][ordered]@{
        Version = 1
        Engine = 'pwsh'
        RepoRoot = $repoBoundary
        State = 'prepared'
        Contents = @($stagedContent)
        Renames = @($renamePlan)
        Settings = $settingsEntry
        Cleanup = @($cleanupBackups)
        EnsureDocsDirectory = $(if (Test-Path -LiteralPath $docsDir -PathType Container) { $docsDir } else { $null })
        DeferredCleanup = @($deferredCleanup)
    }
    Write-DurableText $manifestPath ($manifest | ConvertTo-Json -Depth 8 -Compress)

    Write-Host "==> Initializing template as '$ProjectName'" -ForegroundColor Cyan
    $transactionActive = $true

    # 1) Commit staged content replacements.
    foreach ($entry in $stagedContent) {
        $relativePath = [IO.Path]::GetRelativePath($repoRoot, $entry.Path).Replace('\', '/')
        $skipContentPath = [Environment]::GetEnvironmentVariable('META_INIT_TEST_SKIP_CONTENT_PATH')
        if ($skipContentPath -cne $relativePath) {
            [IO.File]::WriteAllBytes($entry.Path, [IO.File]::ReadAllBytes($entry.Stage))
        }
        Set-FileMetadata $entry.Path $entry.Metadata
        if (-not (Test-FileBytesEqual $entry.Path $entry.Stage)) {
            throw "Staged content was not applied exactly to '$relativePath'."
        }
        if (-not (Test-FileMetadata $entry.Path $entry.Metadata)) {
            throw "Metadata was not preserved for '$($entry.Path)'."
        }
        Invoke-ControlledCrash 'content'
    }
    Write-Host "    Updated contents in $($stagedContent.Count) file(s)." -ForegroundColor DarkGray
    Invoke-ControlledFailure 'content'

    # 2) Rename token-bearing paths, deepest first.
    foreach ($entry in $renamePlan) {
        Rename-Item -LiteralPath $entry.Source -NewName $entry.NewName -ErrorAction Stop
        Write-Host "    Renamed $($entry.OldName) -> $($entry.NewName)" -ForegroundColor DarkGray
        Invoke-ControlledCrash 'rename' $entry.OldName
        Invoke-ControlledFailure 'rename' $entry.OldName
    }
    Invoke-ControlledFailure 'rename'

    # META(%%): language-specific post-processing goes here if needed. Example (Kotlin):
    #   move src/main/kotlin/__PackageName__ to the real dotted package directory tree.

    # 3) Activate the Claude Code shared settings without overwriting a concurrent destination.
    if ($hasExistingClaudeSettings) {
        if (Test-Path -LiteralPath $claudeTemplate) {
            Write-Host '    Kept existing .claude/settings.json unchanged; left .claude/settings.json.template in place.' -ForegroundColor DarkGray
        }
        else {
            Write-Host '    Kept existing .claude/settings.json unchanged; no settings template needed activation.' -ForegroundColor DarkGray
        }
    }
    elseif ($settingsWillActivate) {
        [IO.File]::Copy($claudeTemplate, $claudeSettings, $false)
        Set-FileMetadata $claudeSettings $settingsEntry.Metadata
        Invoke-ControlledCrash 'settings'
        Remove-Item -LiteralPath $claudeTemplate -Force -ErrorAction Stop
        Write-Host '    Activated .claude/settings.json' -ForegroundColor DarkGray
    }
    Invoke-ControlledFailure 'settings'

    # 4) Remove template-only files only after each one has an external backup.
    foreach ($entry in @($cleanupBackups | Where-Object { $templateOnly -contains $_.Path })) {
        Remove-Item -LiteralPath $entry.Path -Force -ErrorAction Stop
        Write-Host "    Removed $($entry.Path.Substring($repoRoot.Length).TrimStart('\','/'))" -ForegroundColor DarkGray
        Invoke-ControlledCrash 'cleanup'
    }

    if ((Test-Path -LiteralPath $docsDir) -and -not (Get-ChildItem -LiteralPath $docsDir -Force)) {
        Remove-Item -LiteralPath $docsDir -Force -ErrorAction Stop
        Write-Host '    Removed docs' -ForegroundColor DarkGray
    }
    Invoke-ControlledFailure 'cleanup'

    # 5) Remove the non-running initializer while the active engine can still roll
    #    the transaction back. The running script is deleted only after commit.
    foreach ($path in $scriptCleanup) {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        Invoke-ControlledCrash 'scripts'
    }
    Invoke-ControlledFailure 'scripts'

    $manifest.State = 'committed'
    Write-DurableText $manifestPath ($manifest | ConvertTo-Json -Depth 8 -Compress)
    foreach ($path in $deferredCleanup) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    }
    $transactionActive = $false
    try {
        Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Initialization succeeded, but temporary backups could not be removed: $transactionRoot"
    }
    Remove-CoordinationOwner
}
catch {
    $originalError = $_
    if ($transactionActive -and $null -ne $manifest) {
        try {
            Restore-Transaction $manifest
            Remove-CoordinationOwner
            throw "Initialization failed; the original tree was restored. $($originalError.Exception.Message)"
        }
        catch {
            if ($_.Exception.Message.StartsWith('Initialization failed; the original tree was restored.')) { throw }
            Remove-CoordinationOwner
            throw "Initialization failed and rollback was incomplete. $($_.Exception.Message)"
        }
    }
    if ($ownsTransaction -and (Test-Path -LiteralPath $transactionRoot)) {
        Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-CoordinationOwner
    throw $originalError
}

Write-Host ''
Write-Host 'Done. Next steps:' -ForegroundColor Green
# META(%%): fill these with your build/test commands and publishing note.
Write-Host '  1. %%BuildCmd%%'
Write-Host '  2. %%TestCmd%%'
Write-Host '  3. Review LICENSE (author/year) and the package metadata in %%ManifestFile%%.'
Write-Host '  4. Publishing: add the %%PublishSecret%% repo secret, or delete'
Write-Host '     .github/workflows/release.yml and the packaging metadata.'
Write-Host '  5. Commit the initialized project.'
