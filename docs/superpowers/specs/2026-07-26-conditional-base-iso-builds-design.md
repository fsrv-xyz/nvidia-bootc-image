# Conditional base + ISO builds — Design

**Date:** 2026-07-26
**Status:** Approved (Design)

## Goal

Stop rebuilding the base image and the Anaconda ISO on every push. Rebuild the base
image **only** when files that actually feed the base container image change, and build
the ISO **only** when a new base image was built (or the ISO's own kickstart config
changed). Applies to **both** pipelines: GitLab (`.gitlab-ci.yml`, primary) and GitHub
Actions (`.github/workflows/build-images.yml`, ghcr mirror). System images keep building
on every push.

## Input file sets

| Set | Files | Feeds |
|---|---|---|
| **Base inputs** | `Containerfile`, `files/**`, `sshkeys/**`, `.dockerignore`, `bib/config.toml` | the base container image build |
| **ISO inputs** | Base inputs **plus** `bib/iso-config.toml` (kickstart) | the Anaconda installer ISO |

`bib/config.toml` is included in the base set by explicit choice, so an image-config
change also refreshes base + ISO. `bib/iso-config.toml` is kickstart-only and never
rebuilds the base — it only re-triggers the ISO.

## Job rules

| Job | Runs when |
|---|---|
| `base` | any **base input** changed in the push |
| `systems` (rtx3080ti, rtx4000ada) | **always** |
| `iso` | the `base` job ran **OR** `bib/iso-config.toml` changed |

### Why the system images never break on a skipped base

System images build `FROM base:<ref>` where `<ref>` is the per-branch tag
(`$CI_COMMIT_REF_SLUG` / sanitized `GITHUB_REF_NAME`). `base` and `systems` share that
tag, so `FROM` must resolve even when `base` is skipped:

- **First push of a branch:** the push delta is "everything changed" → `base` runs →
  `base:<ref>` is created. Both GitLab `rules:changes` (branch pipelines) and GitHub's
  `event.before → sha` diff treat a brand-new branch as all-changed.
- **Later pushes without base changes:** `base` is skipped, but `base:<ref>` already
  exists from the previous pipeline on the same ref, so `FROM` resolves.

## GitLab (`.gitlab-ci.yml`)

- **`base` component:** add a `rules: changes` condition on the base inputs. Preferred
  mechanism is a `rules` input on the `container@0.1.0` component; if the component does
  not expose one, override the generated job by redeclaring a job of the same name in the
  main file and merging `rules:` into it. Which mechanism applies is verified during
  implementation.
- **`systems` components:** unchanged — always run.
- **`build-iso` (custom job):** add `rules: changes` matching the base inputs **or**
  `bib/iso-config.toml`.

Change detection uses GitLab's default branch-pipeline behaviour: `rules:changes`
compares against the previous commit of the branch (the push delta).

## GitHub Actions (`.github/workflows/build-images.yml`)

Workflow keeps triggering on every push/tag (no workflow-level `paths:` filter — that
would skip the system builds too). Gating is per-job:

- **New `changes` job:** computes booleans from `git diff --name-only`
  `${{ github.event.before }} → ${{ github.sha }}`, with a fallback treating a new branch
  or tag (all-zero `before`, or unresolvable range) as all-changed. Outputs:
  `base_changed`, `iso_config_changed`. Uses `actions/checkout` with `fetch-depth: 0`.
  Plain git diff, no external action.
- **`base`:** `needs: changes`; `if: needs.changes.outputs.base_changed == 'true'`.
- **`systems`:** `needs: [changes, base]`;
  `if: ${{ !cancelled() && needs.base.result != 'failure' }}` — runs even when `base` is
  skipped, but not if `base` actually failed.
- **`iso`:** `needs: [changes, base]`;
  `if: ${{ !cancelled() && (needs.base.result == 'success' || needs.changes.outputs.iso_config_changed == 'true') }}`.

`base.outputs.tag` (the sanitized ref used as the image tag) currently comes from the
`base` job's `meta` step. `systems` and `iso` need that tag even when `base` is skipped,
so the tag derivation moves to (or is duplicated in) the `changes` job and is consumed
from there, keeping it available regardless of whether `base` ran.

## Known limitation (documented, not handled)

A force-push or rebase that leaves the base inputs unchanged but for which `base:<ref>`
has since been evicted by registry retention would skip `base` while `FROM base:<ref>`
no longer resolves, failing the system build. Rare; the fix (a registry-existence probe)
is intentionally out of scope. Recovery is a trivial empty/base-touching commit to force
a base rebuild.

## Out of scope

- Content-addressed base tags (hash-of-inputs tagging). Considered and rejected: it would
  change the public `base:<ref>` tag contract and force the GitLab `base` job out of the
  shared `container` component into a custom job — disproportionate to the goal.
- Any change to the system-image build cadence — they always build.
