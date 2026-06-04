<!-- META(%%): the prose is language-neutral. Fill %%RegistryName%% and adjust the
     "Automated scanning" paragraph to match the tools your template ships (CodeQL only
     where supported; the dependency-audit tool varies per ecosystem). See META-AUTHORING.md. -->
# Security Policy

## Supported versions

Security fixes are applied to the latest released version of **__ProjectName__**.
Older versions are not maintained — upgrade to the latest release to receive
fixes.

## Reporting a vulnerability

**Do not open a public issue for security vulnerabilities.**

Report privately through GitHub's
[private vulnerability reporting](https://github.com/__GitHubOwner__/__ProjectName__/security/advisories/new)
(repository **Security → Advisories → Report a vulnerability**). If that is
unavailable, contact the maintainer listed on the
[__GitHubOwner__](https://github.com/__GitHubOwner__) profile.

Please include:

- a description of the vulnerability and its impact;
- steps to reproduce (a minimal proof of concept is ideal);
- affected version(s).

You can expect an initial acknowledgement within a few days. Once a fix is
ready, a patched release is published to %%RegistryName%% and the advisory is
disclosed.

## Automated scanning

<!-- META(%%): describe the scanning this template actually ships. Keep the lines
     that apply, delete the rest.
     - CodeQL: only where GitHub supports the language (C#, Kotlin = yes; Rust, F# = no).
     - Dependency auditing: cargo-deny (Rust) / NuGetAudit (.NET) / Gradle
       dependency-submission (Kotlin) / your ecosystem's equivalent.
     - Dependabot keeps Actions and packages current in every template. -->
Dependencies are audited against the advisory database for %%LangName%%, and
[Dependabot](.github/dependabot.yml) keeps GitHub Actions and packages current.
