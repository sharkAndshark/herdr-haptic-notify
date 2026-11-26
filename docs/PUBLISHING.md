# Publishing this plugin

Everything a maintainer needs; end users never need this page.

## How herdr discovery works

[herdr.dev/plugins](https://herdr.dev/plugins/) is an **automatic, unreviewed index** of **public** GitHub
repositories that:

1. carry the GitHub topic **`herdr-plugin`**, and
2. have at least one `herdr-plugin.toml` on the **default branch** — at the repo root or in a subdirectory —
   whose required metadata parses.

The index records `id`, `name`, `version`, `platforms` and `min_herdr_version`, refreshes every **~30 minutes**, and
rescans when the default-branch head changes. One card per repository; each valid manifest is listed as a separately
installable plugin. Forks and archived repositories are skipped.

Nothing is vetted, so herdr's own trust guidance applies to whoever installs it.

## Checklist for this repo

| Requirement | Status |
|---|---|
| `herdr-plugin.toml` at the repository root | yes |
| `min_herdr_version` declared (install/link fails without it) | `0.9.0` |
| top-level `platforms` (absence only warns on local link) | `["macos"]` |
| action ids without dots | `test-done`, `test-blocked`, `tail-log`, `open-lab`, `print-config`, `doctor` |
| `[[build]]` works from a clean clone without a Swift toolchain | downloads a checksummed prebuilt asset |
| licence | MIT |

## Going public

```sh
gh repo edit --visibility public --accept-visibility-change-consequences
gh repo edit --add-topic herdr-plugin
```

Then wait up to 30 minutes, or push any commit to the default branch to trigger a rescan.

After that, `herdr plugin install sharkAndshark/herdr-haptic-notify` works for anyone, and prebuilt release assets can
be fetched anonymously with `curl` (before publishing they need `gh` auth, which is what
`scripts/build-taptic.sh` tries first anyway).

## Cutting a release

```sh
make release-assets     # dist/taptic-macos-{arm64,x86_64} + .sha256
git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z
gh release create vX.Y.Z dist/taptic-macos-* \
  --title "vX.Y.Z" --notes "…"
```

`scripts/build-taptic.sh` downloads `taptic-macos-<arch>` and its `.sha256` from
`releases/latest/download`, verifies the checksum **before** running it, then re-signs it ad-hoc. Keep both files in
every release: a missing `.sha256` only warns, but a mismatch aborts the install.

## Re-authoring commits

Commit metadata is public in a public repository. This repo's history was re-authored to the GitHub noreply address:

```sh
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter '
export GIT_AUTHOR_NAME="Lucas"
export GIT_AUTHOR_EMAIL="42399654+sharkAndshark@users.noreply.github.com"
export GIT_COMMITTER_NAME="Lucas"
export GIT_COMMITTER_EMAIL="42399654+sharkAndshark@users.noreply.github.com"
' -- --all
```

A force-push is **not** enough to remove the old objects: GitHub keeps them reachable by SHA. To truly purge, delete
and recreate the repository (or rename the old one and keep it private) — that is what was done here, and the old SHAs
return HTTP 422 afterwards.
