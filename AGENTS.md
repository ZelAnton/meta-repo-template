<!-- META(%%): the sections marked "neutral — keep" are language-agnostic; reproduce
     them as-is in the generated template. Fill the "language-specific — author" sections
     for %%LangName%% using the sibling templates as worked examples. See META-AUTHORING.md. -->
# AGENTS.md

## Project

<!-- META: author (language-specific — fill for the target language) -->
- This repository contains `__ProjectName__`, a %%LangName%% project.
- The public API lives in `%%SrcLayout%%`.
- Tests live in `tests/__ProjectName__.Tests` (adjust to your language's layout).
- Keep the repository focused; do not introduce CLI, UI, hosting, logging, or dependency injection infrastructure unless explicitly requested.

## Agent instruction files are local-only in generated repos

<!-- META: keep (neutral — reproduce as-is) -->
> **Scope:** this section is for a repository **created from a template**, not the
> template itself. In the template, `CLAUDE.md`, `AGENTS.md`, and `.claude/` stay
> **tracked and pushed** — that is how the guidance ships. If you are reading this
> in the template repo, leave them tracked and do nothing.

In a generated repo, `CLAUDE.md`, `AGENTS.md`, and `.claude/` are local guidance for whoever (human or agent) works in the clone — not project source. Keep them **git-ignored and untracked** so they stay on disk for tooling but never reach the remote; each developer keeps their own. This is a **by-hand step — the init script does not do it** — done **before the first push**:

```bash
# Append last so `.claude/` overrides the earlier `!.claude/...` ship lines.
printf '\n/CLAUDE.md\n/AGENTS.md\n.claude/\n' >> .gitignore
git rm -r --cached CLAUDE.md AGENTS.md .claude
git add .gitignore && git commit -m "Keep agent instructions local"   # commit the ignore rule *and* the removals together
```

`git rm --cached` keeps the files on disk; an ignore rule alone won't untrack already-committed files. `init` deletes `TEMPLATE.md` and `docs/AGENT-INIT-GUIDE.md`, so this section is the surviving copy of the recipe downstream — consult that guide while it exists for precedence details and the caveat that a repo created via GitHub's *Use this template* already carries these files in its initial commit's history (untracking drops them from the tip only).

## Runtime

<!-- META: author (language-specific — fill for the target language) -->
- Use %%LangName%% (%%LangVersion%%). Do not change the language/runtime version unless explicitly asked.
- Use the repository-wide settings from the build manifest (%%ManifestFile%%).

## Dependencies

<!-- META: author (language-specific — fill for the target language) -->
- Do not introduce new dependencies without explicit approval.
- Pin dependency versions in the build manifest, not ad hoc.
- TODO(meta): document the dependency model (e.g. Central Package Management for
  .NET, `Cargo.toml` + committed `Cargo.lock` for Rust, `gradle/libs.versions.toml`
  version catalog for Kotlin) and the supply-chain audit tool.

## Architecture

<!-- META: keep (neutral — reproduce as-is) -->
- Keep all functionality available as reusable library APIs.
- Keep implementation details (helpers, platform-specific code, internal types) internal to the library.
- Do not expose implementation types publicly unless explicitly requested.
- Prefer simple, direct code over new abstractions.
- Minimize public API surface area; public API changes must be intentional and documented.
- Do not add dependency injection unless there is a concrete need.

## Build, references, and repository structure

<!-- META: author (language-specific — fill for the target language) -->
- Keep source under `src/`, tests under `tests/` (or your language's idiom), helper scripts under `scripts/`.
- TODO(meta): document cross-project reference rules and build ordering for your
  build system. Examples from the siblings:
  - **.NET** — `Reference` + `AssemblySearchPaths` (never `ProjectReference`/`HintPath`); build order from `BuildDependency` in the `.slnx`; canonical MSBuild path props `$(RepoRoot)` / `$(MainProjectDir)` instead of `..\..\`.
  - **Rust** — workspace members in `Cargo.toml`; cargo resolves order.
  - **Kotlin** — Gradle modules in `settings.gradle.kts`.

## Build And Test

<!-- META: author (language-specific — fill for the target language) -->
- Use `%%BuildCmd%%` to validate compilation (warnings are errors).
- Use `%%TestCmd%%` to run tests after a successful build.
- A successful test run must execute the discovered tests, not only complete build targets.

## Formatting

<!-- META: author the formatter line; the LF / Markdown / batch rules are neutral -->
- `.editorconfig` is the source of truth for indentation and line endings — follow it.
- The language formatter is `%%FmtCmd%%`; CI / the conventions expect formatted code.
- Preserve LF line endings, except Windows batch files (`.cmd`/`.bat`) which require CRLF.

## %%LangName%% Style

<!-- META: author (language-specific — fill for the target language) -->
- TODO(meta): list the enforced language idioms (e.g. file-scoped namespaces +
  nullable + implicit usings for C#; `explicitApi()` + `allWarningsAsErrors` for
  Kotlin; rustfmt/clippy clean for Rust; Fantomas + `--warnon:1182` for F#).
- Treat warnings as errors. Prefer simple, direct code. Minimize public API surface.

### Exception / error handling style

<!-- META: keep the rule (neutral); author the example for the target language -->
- Prefer multi-line, braced handlers over collapsed one-liners.
- An empty/ignored error branch must carry a comment explaining **what** is being
  swallowed and **why** ignoring is correct here. "// ignored" alone is not enough.
- TODO(meta): replace this paragraph's example with idiomatic %%LangName%% code if
  the language has a distinct error model (Result/Option, exceptions, etc.).

## Documentation

<!-- META: keep (neutral — reproduce as-is) -->
- All documentation and code comments must be written in English.
- Functional changes must include corresponding README updates when behavior, requirements, usage, or public API changes.
- Do not leave changed behavior undocumented.

## Changelog

<!-- META: keep (neutral — reproduce as-is) -->
- `CHANGELOG.md` is the single source of truth for release notes.
- The release workflow reads `## [Unreleased]` automatically to populate the GitHub Release body (and, where applicable, the package's release-notes field).
- **Every user-visible change must be accompanied by a `CHANGELOG.md` update in the same change set.** Non-negotiable for new/modified public API, behavioural changes, bug fixes, deprecations, removals. Pure internal refactors are the only exemption.
- Add a manual bullet under `## [Unreleased]` in the appropriate subsection (`### Added` / `### Changed` / `### Fixed` / `### Removed` / `### Deprecated`). Write it for a consumer, not the implementer. Replace the placeholder `-`.
- Do not modify versioned sections (`## [1.0.0]`, etc.) — those are managed by the release workflow.

### Auto-fill fallback

<!-- META: keep (neutral — reproduce as-is) -->
- If `## [Unreleased]` has no real bullets at release time, the workflow auto-generates entries from commits since the previous tag using `git-cliff` (config: `cliff.toml`). Manual entries always win.
- The first word of the commit subject decides the bucket (case-insensitive): `Add`/`Feat` → Added; `Fix`/`Bug` → Fixed; `Remove`/`Delete`/`Drop` → Removed; `Refactor`/`Update`/`Change`/`Rename`/`Perf`/`CI`/`Cleanup` → Changed; `Doc`/`Chore`/`Test`/`Style` and `Release v...`/merges → skipped; anything else → Changed (fallback).

## Release

<!-- META: keep the ordering invariant (neutral); author registry/secret specifics -->
- The release workflow (`.github/workflows/release.yml`) publishes to %%RegistryName%% and attaches a `SHA256SUMS` manifest plus the built artifacts to the GitHub Release.
- Publishing requires the `%%PublishSecret%%` repository secret.
- **Step ordering invariant:** the registry publish is the only irreversible step, so it is the pivot. A secret preflight runs first; build/test/package and a *local* (unpushed) commit+tag run before the pivot; the publish runs next; the atomic commit+tag push to `main` and the idempotent GitHub Release run after. A failure before or at the publish leaves no remote/registry trace — re-run freely. **Once the tag is pushed to `main`, do not re-run the whole workflow** — finish the GitHub Release manually using the command the failing step prints. When editing `release.yml`, never move the publish after the tag push, and keep the post-pivot steps idempotent.

## Security Scanning

<!-- META: author (language-specific — fill for the target language) -->
- TODO(meta): describe the scanning this template ships. Keep `codeql.yml` only
  where CodeQL supports the language (C#, Kotlin = yes; Rust, F# = no). Document the
  dependency-audit tool (cargo-deny / NuGetAudit / Gradle dependency-submission).

## Comments

<!-- META: keep (neutral — reproduce as-is) -->
- Minimize comments. Write them only to explain why something exists, an architectural decision, or non-obvious platform/runtime behavior.
- Do not write comments describing what the code already says.

## Version control (Git)

<!-- META: keep (neutral — reproduce as-is) -->
This repository uses Git directly. Do not initialize or colocate another version-control system in the working tree.

### Starting work

- Before editing, run `git status --short --branch` and inspect the current branch and any existing changes.
- Keep refinements and follow-ups for the same task on the current feature branch.
- Do not mix unrelated work into the same branch or commit. If the working tree is clean, create a short kebab-case feature branch from `origin/main`. If unrelated work arrives while changes are still in progress, ask before stashing, switching branches, or creating another worktree.
- Preserve user-authored changes and do not amend or rewrite their commits without explicit agreement.

### Pushing to remote

The user signals "synchronise with remote" with a short trigger word (typically `pull` or `push`). On that signal, run the full sync:
1. `git fetch origin` — pull down remote movement before doing anything else.
2. Rebase the feature branch onto `origin/main` when the remote branch has advanced: `git rebase origin/main`.
3. Push the feature branch, never local `main`: use `git push --set-upstream origin HEAD` on the first push and `git push` afterwards.
4. Open or update a pull request into `main` (`gh pr create --base main --head <topic> --fill`). `main` advances only when the pull request merges; afterwards, fetch, update local `main` with a fast-forward-only pull, and delete the merged feature branch.

Never push without an explicit signal from the user. **Direct-push fallback:** where `main` is unprotected, `git push origin HEAD:main` remains available; once pull requests are required this is rejected for everyone except the release workflow's GitHub App, which sits in the ruleset's bypass list (`RELEASE_APP_ID` + `RELEASE_APP_PRIVATE_KEY`; see `release-token-bypass.md`).

### Undoing work

- **`git restore <path>`** discards selected unstaged changes; use `git restore --staged <path>` to unstage without deleting work.
- **`git revert <commit>`** reverses a published commit without rewriting shared history.
- **`git reflog`** locates earlier branch and `HEAD` positions when recovery is needed.
- Do not use `git reset --hard`, force-push, or rewrite published history without explicit approval.

Never hide a deliberate undo. Tell the user exactly which files or commits were reverted.

### Branches & safety

- Work is published through a **feature branch per pull request** (short kebab-case topic name), merged into `main` via pull request.
- Do not revert or amend changes the user authored without explicit agreement.
- Do not rewrite unrelated files when making a focused change.

## Command Conventions

<!-- META: keep (neutral — reproduce as-is) -->
- Commands and APIs should be idempotent where possible.
- Output should remain concise and script-friendly.
- Breaking changes must be explicit.
