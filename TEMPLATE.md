<!-- META(%%): this is the GENERATED template's end-user guide (init deletes it from
     concrete projects). Fill the meta-tokens and the optional-pieces list for %%LangName%%.
     The token table and the agent-files-local recipe are neutral. See META-AUTHORING.md. -->
# %%LangName%% repository template

A starting point for %%LangName%% repositories: a pinned toolchain, a strict
formatter, cross-platform CI, an optional %%RegistryName%% release pipeline, and
conventions for agents in [CLAUDE.md](CLAUDE.md) / [AGENTS.md](AGENTS.md).

> **AI agents:** before initializing a repo from this template, read
> [docs/AGENT-INIT-GUIDE.md](docs/AGENT-INIT-GUIDE.md). It captures mistakes past
> initialization sessions made and is a living document you are expected to extend.

## Using this template

1. Create a new repository from this one (GitHub: **Use this template**), or copy
   the files into a fresh repo.
2. **Check your environment is ready.** Before initializing, confirm this machine
   has the toolchain to build and test a %%LangName%% project. Use whichever matches
   your shell — both do the same thing:

   ```pwsh
   pwsh ./scripts/check-env.ps1
   ```

   ```bash
   bash ./scripts/check-env.sh
   ```

   It checks the %%LangName%% toolchain (%%BuildTool%%) is on PATH. If anything
   required is missing it lists the install commands for your OS and exits non-zero —
   install what it names, then re-run it. **Don't run init until it reports the
   environment is ready.**
3. Run the init script once to stamp your project name in. Use whichever matches
   your shell — both do the same thing:

   ```pwsh
   pwsh ./scripts/init.ps1 -ProjectName Acme.Widgets -Author "Jane Doe" -GitHubOwner acme -Description "Widget toolkit"
   ```

   ```bash
   bash ./scripts/init.sh --project-name Acme.Widgets --author "Jane Doe" --github-owner acme --description "Widget toolkit"
   ```

   `-ProjectName` / `--project-name` is required; the rest fall back to sensible
   defaults. Author and author-email values must be single-line; quotes, backticks,
   dollar substitutions, and backslashes are serialized safely in the release
   workflow. GitHub owners must be 1-39 letters, digits, or internal hyphens. The
   script replaces the placeholder tokens in file contents, renames the token-named
   files and folders, and activates `.claude/settings.json` from its `.template` form.
   If `.claude/settings.json` already exists, the script preserves it byte-for-byte
   and leaves `.claude/settings.json.template` in place for manual comparison. It then
   deletes this `TEMPLATE.md`, `docs/AGENT-INIT-GUIDE.md`, and the template-only
   `tests/init-metadata.tests.ps1`, and (unless `-KeepScript` / `--keep-script`)
   removes **both** initializers
   (`check-env.{ps1,sh}` stay — they double as a contributor onboarding check).
4. Verify:

   ```sh
   %%BuildCmd%%
   %%TestCmd%%
   ```

5. Replace the placeholder `Greeter` type in `%%SrcLayout%%` with your real API and
   delete the sample test.
6. **Keep the agent-instruction files local.** This template tracks and ships
   `CLAUDE.md`, `AGENTS.md`, and `.claude/` on purpose — but a repo *created from*
   it should keep them out of its remote. The init script does **not** do this — it
   is a by-hand step. Before your first push, git-ignore and untrack them:

   ```bash
   printf '\n/CLAUDE.md\n/AGENTS.md\n.claude/\n' >> .gitignore
   git rm -r --cached CLAUDE.md AGENTS.md .claude
   git add .gitignore && git commit -m "Keep agent instructions local"
   # jj-colocated: jj file untrack CLAUDE.md AGENTS.md .claude
   ```

   Appending `.claude/` last makes it win over the earlier `!.claude/...` ship
   lines. The surviving copy of this recipe downstream is the "Agent instruction
   files are local-only in generated repos" section of [AGENTS.md](AGENTS.md).

## Placeholder tokens

| Token | Meaning |
|---|---|
| `__ProjectName__` | project / namespace / package id + file & folder names |
| `__Author__` | single-line author (LICENSE, package metadata, release identity) |
| `__AuthorEmail__` | single-line author email (release-commit identity in `release.yml`) |
| `__GitHubOwner__` | 1-39 character GitHub owner/org path segment in repository URLs and `CODEOWNERS` |
| `__Description__` | package description |
| `__Year__` | copyright year |
<!-- META(%%): add any extra project tokens your language needs, e.g. for JVM:
     | `__PackageName__` | dotted package, e.g. com.acme.widgets |
     | `__Group__`       | Maven group id | -->

## Optional pieces — remove what you don't need

<!-- META(%%): tailor this list to %%LangName%%. Common candidates: -->
- **%%RegistryName%% publishing** — if this is an app or internal library, delete
  `.github/workflows/release.yml` and the packaging metadata in %%ManifestFile%%.
- **Community-health files** — `SECURITY.md`, `CONTRIBUTING.md`,
  `.github/PULL_REQUEST_TEMPLATE.md`, `.github/CODEOWNERS`. Edit to taste; delete
  any you don't want. `CODEOWNERS` ships with its rule commented out.
- **YAML linting** — `.yamllint.yml` + the CI `yaml-lint` job. Run locally with
  `yamllint .`. Delete both if unwanted.

## Security hardening (on by default)

- **Pinned actions** — every GitHub Action is pinned to a full commit SHA (with a
  `# vN` comment). Dependabot bumps the SHA and rewrites the comment.
- **Dependency auditing** — TODO(meta): name the tool (cargo-deny / NuGetAudit /
  Gradle dependency-submission) and what it gates.
- **Release ordering** — the workflow publishes to %%RegistryName%% as the single
  irreversible pivot, then pushes the tag, so a blocked push can't orphan a release.

## Post-setup checklist

- [ ] Agent-instruction files (`CLAUDE.md`, `AGENTS.md`, `.claude/`) git-ignored and
      untracked (by hand, before the first push — step 5 above).
- [ ] `%%PublishSecret%%` repository secret added (only if publishing).
- [ ] LICENSE author/year reviewed; package metadata in %%ManifestFile%% filled in.
- [ ] `SECURITY.md` reporting contact reviewed; `.github/CODEOWNERS` enabled if wanted.
- [ ] GitHub **Settings → Security → Private vulnerability reporting** enabled.
- [ ] `CLAUDE.md` "Architecture" section written for your project.
- [ ] Branch protection for `main` configured; if PRs are required, set up the
      release App token (`RELEASE_APP_ID` + `RELEASE_APP_PRIVATE_KEY`; recipe:
      `release-token-bypass.md`).
