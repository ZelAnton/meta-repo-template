<!-- META:start — this block documents meta-repo-template itself. DELETE it (down to
     META:end) when you author a concrete <lang>-repo-template, leaving the README body
     below as the generated template's README. See META-AUTHORING.md. -->
> ## You are looking at `meta-repo-template`
>
> This repository is a **template for building per-language repo templates**
> (`rust-repo-template`, `cSharp-repo-template`, `fSharp-repo-template`,
> `kotlin-repo-template`, …). It is **not** a project template you initialize
> directly.
>
> To create a new `<lang>-repo-template`, **start with
> [META-AUTHORING.md](META-AUTHORING.md)** — it explains the two-token model
> (`__ProjectName__`-style project tokens pass through untouched; `%%`-style
> meta-tokens get filled in once), lists every file to touch, and walks the
> happy path.
>
> Everything below this block is the README the *generated* template ships.
<!-- META:end -->

# __ProjectName__

__Description__

## Requirements

- %%LangVersion%% or later

## Installation

Available on [%%RegistryName%%](%%RegistryUrl%%).

<!-- META(%%): replace with the real add-dependency command for %%LangName%%. -->
```sh
%%InstallCmd%%
```

## Usage

<!-- META(%%): replace with the smallest real example of __ProjectName__'s public API. -->
```%%LangCodeFence%%
TODO: show the smallest real usage of __ProjectName__.
```

## Verifying the package

> Applies when the GitHub Release attaches downloadable artifacts. Remove this
> section for apps, internal libraries, or source-only registries (e.g. crates.io)
> whose releases carry notes but no attached files.

Each GitHub Release ships a `SHA256SUMS` file alongside the published artifacts.
Download them into the same directory, then:

```sh
sha256sum -c SHA256SUMS
```

<!-- META(%%): optionally document the registry's own signature/verification
     command here (e.g. dotnet nuget verify / cargo / gradle signature check). -->

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the version history.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build/test instructions and
conventions. To report a security issue, follow [SECURITY.md](SECURITY.md) —
please do not open a public issue.

## License

This project is licensed under the [MIT License](LICENSE).
