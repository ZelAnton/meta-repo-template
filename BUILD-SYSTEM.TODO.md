# BUILD-SYSTEM.TODO — author the build manifest, then delete this file

This placeholder marks the one part of authoring a `<lang>-repo-template` that
**cannot** be reduced to token substitution: the build manifest and its companion
config files. Create them by hand, using the closest sibling template as a worked
reference, then **delete this file**.

The repo deliberately has **no** working build until you add this. `src/` and
`tests/` ship `Greeter.%%FileExt%%` / `GreeterTests.%%FileExt%%` stubs you must
replace, and the CI/release workflows have `TODO(meta:)` steps that intentionally
`exit 1` until the build is wired.

## What to create (by ecosystem — see the sibling repos for exact contents)

- **Rust** (`rust-repo-template`): `Cargo.toml` (edition, `rust-version` MSRV, inline
  "why" comment per dep) + committed `Cargo.lock` + `rust-toolchain.toml` +
  `deny.toml` (cargo-deny). Source `src/main.rs` or `src/lib.rs`; tests in `tests/`.
- **.NET — C#/F#** (`cSharp-repo-template` / `fSharp-repo-template`):
  `__ProjectName__.csproj`/`.fsproj` + `Directory.Build.props` +
  `Directory.Packages.props` (Central Package Management) + `global.json` (SDK pin) +
  `nuget.config` + `__ProjectName__.slnx` (with `BuildDependency`). F# also needs
  `.config/dotnet-tools.json` for Fantomas and an explicit `<Compile>` order.
- **Kotlin** (`kotlin-repo-template`): `build.gradle.kts` + `settings.gradle.kts` +
  `gradle/libs.versions.toml` (version catalog) + `gradle.properties` + the Gradle
  wrapper (`gradlew`, `gradlew.bat`, `gradle/wrapper/`). Source under
  `src/main/kotlin/__PackageName__/`, tests under `src/test/kotlin/__PackageName__/`.

## After the manifest exists

1. Replace the `Greeter` / `GreeterTests` stubs with a real trivial API + test.
2. Fill the `TODO(meta:)` steps in `.github/workflows/ci.yml` and `release.yml`
   (toolchain setup, build/test, package, version-bump, publish).
3. Fill every meta-token across the repo (`grep -rn '%%' .`).
4. Resolve the toggles in `META-AUTHORING.md` (CodeQL, supply-chain tool, extra
   project tokens, formatter config).
5. Verify per `META-AUTHORING.md` → "Verification", then **delete this file**.
