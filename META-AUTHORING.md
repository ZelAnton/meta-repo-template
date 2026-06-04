# META-AUTHORING — building a new `<lang>-repo-template`

This guide is for whoever (human **or** AI agent) is turning `meta-repo-template`
into a concrete per-language template such as `go-repo-template` or
`python-repo-template`. Read it before touching files.

> **This file and `BUILD-SYSTEM.TODO.md` are meta-only.** Delete both from the
> generated template when you finish — they describe the authoring step, not the
> shipped template.

## 1. What this is, and the two-token model

`meta-repo-template` mirrors the file tree of a real language template
(`.github/`, `src/`, `tests/`, `scripts/`, …). Every file is one of: shipped
verbatim, mostly-shipped with a few fill-in slots, a stub to author, or optional.
Section 4 classifies each.

There are **two** kinds of placeholder, and keeping them straight is the whole
trick:

- **Project tokens** — `__ProjectName__`, `__Author__`, `__AuthorEmail__`,
  `__GitHubOwner__`, `__Description__`, `__Year__`. These belong to the *generated*
  template's own `scripts/init.*` and are resolved later, when someone stamps a
  concrete project. **Leave them exactly as-is** while authoring — they must pass
  through untouched.
- **Meta tokens** — `%%Something%%`. These describe the target language and **you**
  fill them in, once, now. When you are done, no `%%...%%` should remain.

`%%...%%` was chosen because it collides with nothing in the files: not the
`__Xxx__` project tokens, not GitHub Actions `${{ ... }}` expressions, not bash
`<<HEREDOC` / `[[ ... ]]`. A plain `grep -n '%%' .` over the finished template must
return zero hits.

Meta-guidance lives in three marker forms, all of which you **remove** when done:
a `META(%%):` banner at the top of a fill-in file, `<!-- META: keep/author … -->`
tags marking sections inside `AGENTS.md`, and the `<!-- META:start … META:end -->`
block in `README.md`. A finished template has none of them — the verification grep
in section 8 (`%%`, `META:`, `TODO(meta`) is the safety net. **Never edit the four
sibling templates** (`rust-repo-template`, `cSharp-repo-template`,
`fSharp-repo-template`, `kotlin-repo-template`) — they are read-only worked examples.

## 2. The happy path

1. **Copy** `meta-repo-template` to `…/<lang>-repo-template` (a fresh copy; do not
   reuse the meta repo's `.git`/`.jj`).
2. **Pick the closest sibling** as your reference: JVM/Gradle → Kotlin; .NET → C#
   (or F# for ML-family); native/Cargo-like → Rust.
3. **Author the build manifest** — see `BUILD-SYSTEM.TODO.md` and section 5. This is
   the part that is genuinely per-language; do it first so the rest has something to
   build against.
4. **Replace the stubs**: `src/__ProjectName__/Greeter.%%FileExt%%` and the test
   stub with a trivial real API + test that builds and passes. **Author the
   environment preflight** `scripts/check-env.{ps1,sh}` at the same time — fill the
   required-tool check(s), any pinned-version floor, and the per-OS install commands
   (the skeleton is neutral; the sibling's filled version is the worked example).
5. **Fill every `%%token%%`** (section 3), the `TODO(meta:)` placeholders in
   `ci.yml` / `release.yml` / `scripts/check-env.{ps1,sh}`, and strip every
   meta-marker — the `META(%%):` banners,
   the `<!-- META: keep/author … -->` tags in `AGENTS.md`, and the
   `<!-- META:start … META:end -->` block in `README.md`.
   `grep -rnE '%%|META:|TODO\(meta' .` finds them all.
6. **Resolve the toggles** (section 6): CodeQL, supply-chain tool, extra project
   tokens, formatter config.
7. **Delete the meta-only files**: this `META-AUTHORING.md` and
   `BUILD-SYSTEM.TODO.md`.
8. **Verify** (section 7), commit, and you have a new sibling template.

## 3. Meta-token reference

Fill each `%%token%%` consistently across the repo. The four columns are the
canonical reference — read the matching sibling file to see the real value in
context.

| Token | Meaning | Rust | C# | F# | Kotlin |
|---|---|---|---|---|---|
| `%%LangName%%` | display name | Rust | C# | F# | Kotlin |
| `%%LangSlug%%` | lowercase id — the `<lang>` in the repo/dir name; not a file slot | rust | csharp | fsharp | kotlin |
| `%%FileExt%%` | primary source extension (no dot) | rs | cs | fs | kt |
| `%%LangCodeFence%%` | Markdown code-fence language | rust | csharp | fsharp | kotlin |
| `%%LangVersion%%` | README/Contributing requirement | Rust 1.85 | .NET 10.0 | .NET 10.0 | JDK 25 |
| `%%BuildTool%%` | build CLI (for `.claude` allow-rule) | cargo | dotnet | dotnet | gradle |
| `%%BuildCmd%%` | build command | `cargo build` | `dotnet build __ProjectName__.slnx` | `dotnet build __ProjectName__.slnx` | `./gradlew build` |
| `%%TestCmd%%` | test command | `cargo test` | `dotnet test __ProjectName__.slnx` | `dotnet test __ProjectName__.slnx` | `./gradlew test` |
| `%%FmtCmd%%` | format command | `cargo fmt` | `dotnet format` | `dotnet fantomas .` | `./gradlew ktlintFormat` |
| `%%LintCmd%%` | lint command (blank if none) | `cargo clippy --all-targets -- -D warnings` | _(blank)_ | _(blank)_ | `./gradlew ktlintCheck` |
| `%%ManifestFile%%` | build manifest (display) | Cargo.toml | the `.csproj` | the `.fsproj` | build.gradle.kts |
| `%%ManifestPath%%` | manifest path for `git add` / sed | Cargo.toml | src/__ProjectName__/__ProjectName__.csproj | src/__ProjectName__/__ProjectName__.fsproj | build.gradle.kts |
| `%%VersionSeedCmd%%` | first-release version extractor (shell) | `grep -oP '(?<=^version = ")[^"]+' Cargo.toml \| head -n1` | `grep -oP '(?<=<Version>)[^<]+' %%ManifestPath%% \| head -n1` | same as C# | read the `version` gradle property |
| `%%InstallCmd%%` | README add-dependency line | `cargo add __ProjectName__` | `dotnet add package __ProjectName__` | `dotnet add package __ProjectName__` | (Gradle dependency snippet) |
| `%%RegistryName%%` | package registry | crates.io | NuGet.org | NuGet.org | Maven Central |
| `%%RegistryUrl%%` | registry index/package URL | https://crates.io | https://www.nuget.org | https://www.nuget.org | https://central.sonatype.com |
| `%%PublishSecret%%` | release credential secret name | CARGO_REGISTRY_TOKEN | NUGET_API_KEY | NUGET_API_KEY | MAVEN_CENTRAL_PASSWORD (+ SIGNING_KEY/…) |
| `%%PublishCmd%%` | idempotent publish command | `cargo publish --locked` | `dotnet nuget push "./artifacts/*.nupkg" --source … --api-key "$PUBLISH_SECRET" --skip-duplicate` | same as C# | `./gradlew publish` |
| `%%PackageEcosystem%%` | Dependabot ecosystem | cargo | nuget | nuget | gradle |
| `%%BuildArtifactDirs%%` | `.gitignore` build outputs | `/target` | `[Bb]in/` + `[Oo]bj/` (+ `*.nupkg`) | same as C# | `build/` + `.gradle/` |
| `%%CodeqlLanguage%%` | CodeQL id (only if supported) | _(n/a — delete codeql.yml)_ | csharp | _(n/a — delete)_ | java-kotlin |
| `%%SrcLayout%%` | source layout (prose) | `src/` | `src/__ProjectName__/` | `src/__ProjectName__/` | `src/main/kotlin/__PackageName__/` |

Values that vary by registry (`%%PublishCmd%%`, `%%VersionSeedCmd%%`) are shell
commands — copy them from the sibling's `release.yml` rather than retyping.

Caveats:

- **`.claude/settings.json.template`** ships one allow-rule, `Bash(%%BuildTool%% *)`.
  That is correct for `cargo`/`dotnet`, but Gradle drives the build through the
  **wrapper** — replace it with `Bash(./gradlew *)` (and add `Bash(./gradlew.bat *)`
  if Windows clones need it). List whatever build commands the project actually runs.
- **`scripts/check-env.{ps1,sh}`** ship a baseline check that `%%BuildTool%%` is on
  PATH. That is right for `cargo`/`dotnet`, but Gradle runs through the **wrapper**
  (`./gradlew`), not a PATH `gradle` — for Kotlin replace the baseline with a
  launcher-JDK check (`java` ≥ 17), as the Kotlin sibling does. Add any pinned-version
  floor (e.g. the .NET SDK major from `global.json`) and fill the per-OS install lines.
- **Registries needing more than one secret** (e.g. Maven Central:
  `MAVEN_CENTRAL_USERNAME` + `MAVEN_CENTRAL_PASSWORD` + `SIGNING_KEY` +
  `SIGNING_PASSWORD`) — `%%PublishSecret%%` only stamps the single name used by the
  preflight/`env`. Add the remaining secrets to the publish step's `env:` and extend
  the preflight check to match.

## 4. File classification

**V** = ships verbatim (already correct; carries only project tokens) ·
**S** = a few `%%slots%%` to fill · **STUB** = author the content ·
**OPT** = keep only if applicable.

| File | Class | Note |
|---|---|---|
| `META-AUTHORING.md` | meta | **delete when done** |
| `BUILD-SYSTEM.TODO.md` | meta | **delete when done** |
| `LICENSE` | V | MIT + project tokens |
| `.gitattributes` | V | LF normalization, CRLF for batch |
| `.yamllint.yml` | V | Actions-tuned yamllint |
| `cliff.toml` | V | git-cliff changelog buckets |
| `.github/CODEOWNERS` | V | rule shipped commented-out |
| `release-token-bypass.md` | V | GitHub App bypass recipe |
| `CHANGELOG.md` | S | neutral; empty `[Unreleased]` is correct |
| `README.md` | S | delete the `META:start…end` block; fill slots |
| `.editorconfig` | S | source-indent + `[*.%%FileExt%%]` block |
| `.gitignore` | S | `%%BuildArtifactDirs%%` |
| `CONTRIBUTING.md` | S | build/test/version slots |
| `SECURITY.md` | S | registry + scanning paragraph |
| `.github/dependabot.yml` | S | `%%PackageEcosystem%%` |
| `.github/PULL_REQUEST_TEMPLATE.md` | S | build/test commands |
| `.claude/settings.json.template` | S | `%%BuildTool%%` allow-rule |
| `.github/workflows/ci.yml` | S | keep `yaml-lint`; fill `test` steps |
| `.github/workflows/release.yml` | S | keep all neutral machinery; fill marked steps |
| `.github/workflows/codeql.yml` | OPT | delete unless CodeQL supports the language |
| `AGENTS.md` | S | "neutral — keep" vs "language-specific — author" |
| `CLAUDE.md` | S | command quick-ref + Architecture pointer |
| `TEMPLATE.md` | S | generated template's end-user guide |
| `docs/AGENT-INIT-GUIDE.md` | S | keep structure + failure-log; fill stack facts |
| `scripts/check-env.ps1` | S | toolchain-presence preflight; fill tool/version checks + per-OS install commands |
| `scripts/check-env.sh` | S | POSIX counterpart of check-env.ps1 |
| `scripts/init.ps1` | S | fill next-steps; adapt XML/extra-token blocks |
| `scripts/init.sh` | S | POSIX counterpart of init.ps1 |
| `src/__ProjectName__/Greeter.%%FileExt%%` | STUB | real sample API; rename `%%FileExt%%` |
| `tests/__ProjectName__.Tests/GreeterTests.%%FileExt%%` | STUB | real sample test |
| build manifest + config | STUB | see `BUILD-SYSTEM.TODO.md` |

## 5. The build-manifest step

See `BUILD-SYSTEM.TODO.md` for the per-ecosystem file list. Key points:

- **Versioning is single-source.** One place holds the version (`Cargo.toml`
  `version`, `.csproj` `<Version>`, the Gradle `version` property). `release.yml`
  reads it for the first release (`%%VersionSeedCmd%%`) and writes it back on bump
  (the "Bump version in manifest" step) — wire both to that one place.
- **Warnings are errors** everywhere (`-D warnings` / `TreatWarningsAsErrors` /
  `allWarningsAsErrors`). Match the sibling.
- **Pin the toolchain** (rust-toolchain.toml / global.json / Gradle wrapper +
  toolchain) so CI and contributors build identically.
- Rename the token-named dirs only if your layout differs — the init scripts rename
  anything containing `__ProjectName__`, so keep that token in folder names you want
  stamped.
- **Release artifact model.** `release.yml` defaults to the *artifact-producing* shape
  (.NET/Kotlin): the package step writes downloadable files into `./artifacts`, the
  `SHA256SUMS` step hashes them, and the GitHub Release attaches them. For a registry
  that publishes **source directly** (crates.io / Rust) there are no downloadable
  artifacts — **delete the `Generate SHA256SUMS` step**; the Release step's empty-array
  guard then attaches release notes only, no other edits needed. The Rust sibling is
  the worked example.
- **Optional per-language extras** the meta-template omits (add from the sibling if you
  want them): Rider settings (`<PROJ>.sln.DotSettings`) and the Linux-container test
  helper (`scripts/test-linux.ps1` + `docs/linux-testing.md`) for .NET; the Gradle
  `dependency-submission.yml` workflow for Kotlin.

## 6. Toggle checklist

- [ ] **CodeQL** — keep `.github/workflows/codeql.yml` and fill `%%CodeqlLanguage%%`
      only if GitHub supports the language (C#, Kotlin/Java, JS/TS, Python, Go,
      Ruby, C/C++, Swift). For Rust, F#, and anything unsupported, **delete the
      file** and trim the CodeQL line from `SECURITY.md` / `AGENTS.md`.
- [ ] **Supply-chain audit** — wire the ecosystem's tool: cargo-deny (Rust, with
      `deny.toml` + a CI job), NuGetAudit (.NET, in `Directory.Build.props`), or
      Gradle dependency-submission (Kotlin, its own workflow). Mention it in
      `SECURITY.md` and `AGENTS.md` → "Security Scanning".
- [ ] **Extra project tokens** — if the language needs more than the six standard
      tokens (e.g. JVM's `__PackageName__` dotted package and `__Group__` Maven
      group), add them to **both** init scripts (`$replacements` / the `${var//}`
      list **and** params), to the rename/post-processing step (Kotlin moves
      `src/main/kotlin/__PackageName__`), and to `TEMPLATE.md`'s token table.
- [ ] **Formatter config** — add the formatter's config/tool file (rustfmt is
      built-in; Fantomas needs `.config/dotnet-tools.json`; ktlint is a Gradle
      plugin) and make sure `%%FmtCmd%%` matches.
- [ ] **MSRV / minimum runtime job** — Rust verifies its `rust-version` in a CI job;
      add an equivalent if your ecosystem has a minimum-version contract.

## 7. Invariants you must not break

- **Release pivot ordering.** In `release.yml` the registry publish is the single
  irreversible step: secret-preflight → build/test/package → *local* commit+tag →
  **publish** → atomic push of commit+tag → idempotent GitHub Release. Never move
  the publish after the tag push; keep every post-pivot step idempotent and retried.
- **Project tokens stay literal.** Filling `%%...%%` must not touch any `__Xxx__`.
- **Neutral sections stay neutral.** The jujutsu workflow, changelog rules, and the
  "agent files are local-only" recipe are shared verbatim across all siblings —
  don't fork them per language.
- **Actions stay SHA-pinned** with a `# vN` comment; Dependabot maintains them.

## 8. Verification

1. **No stray meta-tokens, markers, or TODOs:** `grep -rnE '%%|META:|TODO\(meta' .`
   over the finished template returns nothing (ignore `.git`/`.jj`). This single
   pattern catches the `%%Token%%` slots, the `META(%%):` banners, the
   `<!-- META: keep/author … -->` / `<!-- META:start/end -->` markers, and the
   `TODO(meta:)` steps. Separately, `grep -rn '__[A-Za-z]' .` should show *only* the
   intended project tokens — the generated template's init script resolves those.
2. **Workflows intact:** `release.yml`/`ci.yml` still contain their `${{ ... }}`
   expressions and `<<'PY'` heredocs unaltered.
3. **It builds:** run the generated template's own `scripts/init.ps1`
   (`-ProjectName Acme.Widgets`) in a throwaway copy, then `%%BuildCmd%%` +
   `%%TestCmd%%` — the sample API and test must build and pass.
4. **Regression check (optional but recommended):** author "C# from meta", fill the
   slots from the table above, add the manifest, and confirm `git diff` against
   `cSharp-repo-template` is empty except for intentional differences. If the guide
   plus slots can regenerate a known-good sibling, it can author a new one.
