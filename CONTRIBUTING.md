<!-- META(%%): fill the meta-tokens (prerequisites, build/test commands). The prose and
     the Changelog/Pull-requests sections are language-neutral. See META-AUTHORING.md. -->
# Contributing to __ProjectName__

Thanks for your interest in improving **__ProjectName__**.

## Prerequisites

- %%LangVersion%% (the exact toolchain is pinned in the build manifest).

## Build and test

```sh
%%BuildCmd%%
%%TestCmd%%
```

The build treats **warnings as errors**, so a clean local build is required
before opening a pull request.

## Conventions

- **Formatting** is governed by the language formatter (`%%FmtCmd%%`) and/or
  [`.editorconfig`](.editorconfig). Do not reformat code you are not changing.
- **Dependencies** are pinned in the build manifest — add them there, not ad hoc.
- See [`AGENTS.md`](AGENTS.md) for the full, authoritative set of conventions.

## Changelog

Every user-visible change ships its [`CHANGELOG.md`](CHANGELOG.md) entry in the
same change set, under `## [Unreleased]`. Write the bullet for a consumer of the
library, not the implementer. Pure internal refactors are exempt.

## Pull requests

- Keep changes focused; unrelated cleanups belong in their own PR.
- Ensure CI (build/test on Linux, Windows, macOS) passes.
- Fill in the pull-request checklist.
