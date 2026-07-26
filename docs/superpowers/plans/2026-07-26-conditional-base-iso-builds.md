# Conditional base + ISO builds — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the base image only when its input files change, and the Anaconda ISO only when the base was rebuilt or the kickstart config changed — in both the GitLab and GitHub Actions pipelines. System images keep building on every push.

**Architecture:** Add change-detection gating to each pipeline. GitLab uses native `rules:changes` on the base component and the `build-iso` job. GitHub Actions gains a small `changes` job that diffs the push (`event.before → sha`) and exposes `base_changed` / `iso_config_changed` booleans (plus the image `tag`), which the `base`, `systems`, and `iso` jobs gate on via `needs` + `if`.

**Tech Stack:** GitLab CI YAML (shared `fsrvcorp/ci-components`), GitHub Actions YAML, POSIX shell for change detection. Static validation with `yamllint` and `actionlint` (both installed locally).

## Global Constraints

- Per-ref image tag scheme is unchanged: `$CI_COMMIT_REF_SLUG` (GitLab) / sanitized `GITHUB_REF_NAME` with `/`→`-` (GitHub). No new tag scheme.
- System images (`rtx3080ti`, `rtx4000ada`) build on **every** push — never gated.
- Base inputs: `Containerfile`, `files/**`, `sshkeys/**`, `.dockerignore`, `bib/config.toml`.
- ISO inputs: base inputs **plus** `bib/iso-config.toml`.
- Base rebuild rule: base inputs changed. ISO rebuild rule: base job ran **OR** `bib/iso-config.toml` changed.
- No external GitHub Actions for change detection — plain `git diff`.
- New branch / tag / unresolvable diff range must be treated as "all changed" so `base:<ref>` always exists before the system builds `FROM` it.

---

## File Structure

- `.gitlab-ci.yml` — add `rules` to the base build and to `build-iso`. Systems untouched.
- `.github/workflows/build-images.yml` — add `changes` job; rewire `base`/`systems`/`iso` with `needs` + `if`; move the tag derivation into `changes`.
- `README.md` — update the "Build", "CI / GitLab", and "CI / GitHub" sections to describe conditional builds.
- `/private/tmp/claude-501/-Users-florian-GIT-priv-vllm-bootc/6776b4f8-cd04-4394-a77a-651b63c017b0/scratchpad/detect_test.sh` — throwaway local harness to unit-test the GitHub detect logic (not committed).

---

### Task 1: GitLab — gate base + ISO on changed inputs

**Files:**
- Modify: `.gitlab-ci.yml`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a GitLab pipeline where the base component and `build-iso` carry `rules:changes`. No identifiers consumed by later tasks (the two pipelines are independent).

The base image is built by the first `container@0.1.0` component include (`instance_name: base`, `image_name: base`). GitLab CI components accept an optional `rules` input; pass the change rule there. If the pinned `container@0.1.0` in this project does **not** expose a `rules` input (verify in Step 1), fall back to overriding the generated job by name — the base job the component emits is named `base` (matches `instance_name`); redeclaring `base:` in the main file merges `rules:` into it.

- [ ] **Step 1: Verify whether the `container@0.1.0` component exposes a `rules` input**

Check the component's `spec:inputs`. From the repo host (which can reach ref.ci):

```bash
git ls-remote https://$CI_SERVER_FQDN/fsrvcorp/ci-components 2>/dev/null | head
# or open the component in the GitLab UI: fsrvcorp/ci-components -> templates/container.yml -> spec.inputs
```

Expected: determine if an input named `rules` exists. Record the answer; it selects Step 2a (input) vs Step 2b (job override). If you cannot reach the component, default to Step 2b (job override) — it works regardless.

- [ ] **Step 2a (if `rules` input exists): pass the change rule to the base component**

In `.gitlab-ci.yml`, in the **first** component include (the `instance_name: base` block), add a `rules` input listing the base inputs:

```yaml
  - component: $CI_SERVER_FQDN/fsrvcorp/ci-components/container@0.1.0
    inputs:
      stage: build-base
      instance_name: base
      image_name: base
      containerfile_location: ./Containerfile
      tag: $CI_COMMIT_REF_SLUG
      rules:
        - changes:
            paths:
              - Containerfile
              - files/**/*
              - sshkeys/**/*
              - .dockerignore
              - bib/config.toml
```

- [ ] **Step 2b (if no `rules` input): override the generated base job**

Leave the `instance_name: base` component include as-is and append a job override after the `include:` block (top level of `.gitlab-ci.yml`):

```yaml
# Rebuild the base image only when its build inputs change. On a new branch the push
# delta is "all changed", so base still builds and base:<ref> exists for the system FROM.
base:
  rules:
    - changes:
        paths:
          - Containerfile
          - files/**/*
          - sshkeys/**/*
          - .dockerignore
          - bib/config.toml
```

- [ ] **Step 3: Add the ISO change rule to `build-iso`**

Add a `rules` block to the existing `build-iso:` job (base inputs **or** the kickstart config). A single `changes.paths` list is an OR, so one rule covers both sets:

```yaml
build-iso:
  stage: build-iso
  image: docker:cli
  rules:
    - changes:
        paths:
          - Containerfile
          - files/**/*
          - sshkeys/**/*
          - .dockerignore
          - bib/config.toml
          - bib/iso-config.toml
  variables:
    # ...unchanged...
```

- [ ] **Step 4: Lint the file**

Run: `yamllint -d '{extends: relaxed, rules: {line-length: disable}}' .gitlab-ci.yml`
Expected: no errors (warnings acceptable). Fix any syntax issues.

- [ ] **Step 5: Sanity-check the rule shape by eye**

Confirm: `build-systems` includes have **no** `rules` (still always build); the base gating (Step 2a or 2b) lists exactly the 5 base inputs; `build-iso` lists those 5 **plus** `bib/iso-config.toml`.

- [ ] **Step 6: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci(gitlab): build base only on input changes, ISO only after base or kickstart change"
```

---

### Task 2: GitHub Actions — add `changes` job and rewire base/systems/iso

**Files:**
- Modify: `.github/workflows/build-images.yml`
- Test (local, not committed): `/private/tmp/claude-501/-Users-florian-GIT-priv-vllm-bootc/6776b4f8-cd04-4394-a77a-651b63c017b0/scratchpad/detect_test.sh`

**Interfaces:**
- Consumes: nothing from Task 1 (independent pipeline).
- Produces (job outputs consumed within this file):
  - `changes.outputs.tag` — sanitized ref used as the image tag (replaces `base.outputs.tag`).
  - `changes.outputs.base_changed` — `'true'`/`'false'`.
  - `changes.outputs.iso_config_changed` — `'true'`/`'false'`.

- [ ] **Step 1: Write a local test for the detect logic**

The detect logic is a `changed_all`/regex classifier. Write a standalone harness that exercises it against sample file lists, in the scratchpad:

```bash
cat > /private/tmp/claude-501/-Users-florian-GIT-priv-vllm-bootc/6776b4f8-cd04-4394-a77a-651b63c017b0/scratchpad/detect_test.sh <<'EOF'
#!/usr/bin/env bash
set -u
# Mirror of the workflow's classifier (changed_all=0 path). Reads a newline file list on
# stdin, prints "base_changed=<b> iso_config_changed=<i>".
classify() {
  local files base_re iso_re base_changed iso_config_changed
  files="$(cat)"
  base_re='^(Containerfile|files/|sshkeys/|\.dockerignore$|bib/config\.toml$)'
  iso_re='^bib/iso-config\.toml$'
  base_changed=false; iso_config_changed=false
  echo "$files" | grep -qE "$base_re" && base_changed=true
  echo "$files" | grep -qE "$iso_re" && iso_config_changed=true
  echo "base_changed=$base_changed iso_config_changed=$iso_config_changed"
}
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got [$3] want [$2]"; fail=1; fi
}
check "containerfile"   "base_changed=true iso_config_changed=false"  "$(printf 'Containerfile\n' | classify)"
check "files nested"    "base_changed=true iso_config_changed=false"  "$(printf 'files/usr/lib/x\n' | classify)"
check "sshkeys"         "base_changed=true iso_config_changed=false"  "$(printf 'sshkeys/root.keys\n' | classify)"
check "dockerignore"    "base_changed=true iso_config_changed=false"  "$(printf '.dockerignore\n' | classify)"
check "bib config"      "base_changed=true iso_config_changed=false"  "$(printf 'bib/config.toml\n' | classify)"
check "iso config only" "base_changed=false iso_config_changed=true"  "$(printf 'bib/iso-config.toml\n' | classify)"
check "system only"     "base_changed=false iso_config_changed=false" "$(printf 'systems/rtx4000ada/Containerfile\n' | classify)"
check "readme only"     "base_changed=false iso_config_changed=false" "$(printf 'README.md\n' | classify)"
check "base + iso cfg"  "base_changed=true iso_config_changed=true"   "$(printf 'Containerfile\nbib/iso-config.toml\n' | classify)"
exit $fail
EOF
chmod +x /private/tmp/claude-501/-Users-florian-GIT-priv-vllm-bootc/6776b4f8-cd04-4394-a77a-651b63c017b0/scratchpad/detect_test.sh
```

- [ ] **Step 2: Run the test to verify the regexes are correct**

Run: `/private/tmp/claude-501/-Users-florian-GIT-priv-vllm-bootc/6776b4f8-cd04-4394-a77a-651b63c017b0/scratchpad/detect_test.sh`
Expected: every line `ok:`, exit 0. This proves the exact `base_re`/`iso_re` you will paste into the workflow classify a representative path set correctly. If any FAIL, fix the regex before touching the workflow.

- [ ] **Step 3: Add the `changes` job**

Insert a new job as the first job under `jobs:` in `.github/workflows/build-images.yml`, before `base:`:

```yaml
  # Detect which build inputs changed in this push so downstream jobs can skip.
  # New branch / tag / unresolvable range -> treat everything as changed, so the
  # per-ref base tag is always built before the system images FROM it.
  changes:
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.meta.outputs.tag }}
      base_changed: ${{ steps.detect.outputs.base_changed }}
      iso_config_changed: ${{ steps.detect.outputs.iso_config_changed }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: meta
        run: echo "tag=${GITHUB_REF_NAME//\//-}" >> "$GITHUB_OUTPUT"
      - id: detect
        run: |
          set -eu
          before='${{ github.event.before }}'
          if [ -z "$before" ] \
             || [ "$before" = "0000000000000000000000000000000000000000" ] \
             || ! git cat-file -e "${before}^{commit}" 2>/dev/null; then
            base_changed=true; iso_config_changed=true
          else
            files="$(git diff --name-only "$before" "$GITHUB_SHA")"
            base_re='^(Containerfile|files/|sshkeys/|\.dockerignore$|bib/config\.toml$)'
            iso_re='^bib/iso-config\.toml$'
            base_changed=false; iso_config_changed=false
            echo "$files" | grep -qE "$base_re" && base_changed=true
            echo "$files" | grep -qE "$iso_re" && iso_config_changed=true
          fi
          echo "base_changed=$base_changed" >> "$GITHUB_OUTPUT"
          echo "iso_config_changed=$iso_config_changed" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 4: Gate the `base` job on `changes` and drop its own meta step**

Change the `base` job header from:

```yaml
  base:
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.meta.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
      - id: meta
        # Ref name as the image tag; sanitize '/' from branch names.
        run: echo "tag=${GITHUB_REF_NAME//\//-}" >> "$GITHUB_OUTPUT"
      - name: Free disk space
```

to:

```yaml
  base:
    needs: changes
    if: ${{ needs.changes.outputs.base_changed == 'true' }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Free disk space
```

Then in the base job's `build-push-action` step, change the tag reference:

```yaml
          tags: ${{ env.IMAGE_BASE }}/base:${{ needs.changes.outputs.tag }}
```

(was `${{ steps.meta.outputs.tag }}`).

- [ ] **Step 5: Rewire the `systems` job to always run and read the tag from `changes`**

Change the `systems` job header from:

```yaml
  systems:
    needs: base
    runs-on: ubuntu-latest
    strategy:
```

to:

```yaml
  systems:
    needs: [changes, base]
    # Always build the system images; run even when `base` was skipped (base:<ref>
    # already exists from a prior pipeline), but not if `base` actually failed.
    if: ${{ !cancelled() && needs.base.result != 'failure' }}
    runs-on: ubuntu-latest
    strategy:
```

In the `systems` `build-push-action` step, replace both `needs.base.outputs.tag` references with `needs.changes.outputs.tag`:

```yaml
          build-args: |
            BASE=${{ env.IMAGE_BASE }}/base:${{ needs.changes.outputs.tag }}
          tags: ${{ env.IMAGE_BASE }}/${{ matrix.system }}:${{ needs.changes.outputs.tag }}
```

- [ ] **Step 6: Rewire the `iso` job — run after base ran OR kickstart changed**

Change the `iso` job header from:

```yaml
  iso:
    needs: base
    runs-on: ubuntu-latest
    steps:
```

to:

```yaml
  iso:
    needs: [changes, base]
    if: ${{ !cancelled() && (needs.base.result == 'success' || needs.changes.outputs.iso_config_changed == 'true') }}
    runs-on: ubuntu-latest
    steps:
```

In the `iso` job's script and the `upload-artifact` `name:`, replace every `needs.base.outputs.tag` with `needs.changes.outputs.tag`:

```yaml
          IMG="${IMAGE_BASE}/base:${{ needs.changes.outputs.tag }}"
```

```yaml
          name: nvidia-bootc-base-installer-${{ needs.changes.outputs.tag }}
```

- [ ] **Step 7: Lint the workflow**

Run: `actionlint .github/workflows/build-images.yml`
Expected: no errors. `actionlint` validates `needs`/`if`/expression syntax and shellchecks the `run:` scripts — fix anything it reports (quote-safety in the detect script especially).

- [ ] **Step 8: Grep for stale tag references**

Run: `grep -n 'needs.base.outputs.tag\|steps.meta.outputs.tag' .github/workflows/build-images.yml`
Expected: **no matches** — all tag references now go through `needs.changes.outputs.tag`.

- [ ] **Step 9: Commit**

```bash
git add .github/workflows/build-images.yml
git commit -m "ci(github): gate base/ISO on changed inputs via a changes job"
```

---

### Task 3: Update README + verify end-to-end on real pushes

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the behavior implemented in Tasks 1–2.
- Produces: documentation matching the new behavior; real pipeline evidence.

- [ ] **Step 1: Update the "Build" section**

Replace lines 46–47 (`**Builds run primarily in CI**...`) with text reflecting conditional base/ISO builds:

```markdown
**Builds run primarily in CI** (`.gitlab-ci.yml`) — every push builds the **system**
images. The **base** image rebuilds only when its build inputs change (`Containerfile`,
`files/`, `sshkeys/`, `.dockerignore`, `bib/config.toml`); the installer **ISO** builds
only when the base was rebuilt or the kickstart (`bib/iso-config.toml`) changed. See the
CI section below.
```

- [ ] **Step 2: Update the "CI / GitLab" section**

In the `container@0.1.0 (×3)` bullet (around line 152–158), replace the "always, on every ref, no rules needed" clause with the conditional behavior:

```markdown
- `container@0.1.0` (×3) — builds with `docker buildx` on the remote Docker host and
  pushes to the project registry. Stage `build-base` builds the base (`.../base`) **only
  when its inputs change** (`rules:changes` on `Containerfile`, `files/`, `sshkeys/`,
  `.dockerignore`, `bib/config.toml`); stage `build-systems` builds the system images
  (`.../rtx3080ti`, `.../rtx4000ada`) `FROM` the base **on every push**. All jobs tag
  with `$CI_COMMIT_REF_SLUG`; when the base is skipped, `base:<ref>` still exists from
  the prior pipeline on that ref (a new branch's first push has an "all changed" delta,
  so the base is built). The base tag is passed to the system builds via
  `--build-arg BASE=...`.
```

Add a sentence to the `build-iso` description (it lives in the file, not the README bullet list — add a short note after the `semver` bullet, around line 160):

```markdown
- `build-iso` — a custom job (not a component) that validates the Anaconda ISO builds
  from the current base. It runs only when the base inputs **or** `bib/iso-config.toml`
  change (`rules:changes`).
```

- [ ] **Step 3: Update the "CI / GitHub" section**

After the `Job base ...` / `Job systems ...` bullets (around line 176–181), reflect the `changes` gating:

```markdown
- Job `changes` diffs the push and decides what to build: `base` runs only when the base
  inputs changed; `systems` (matrix, `needs: [changes, base]`) runs on **every** push,
  even when `base` was skipped; `iso` runs only when `base` was rebuilt **or**
  `bib/iso-config.toml` changed. A new branch / tag is treated as "all changed" so
  `base:<ref>` always exists before the system images build `FROM` it.
```

- [ ] **Step 4: Commit the docs**

```bash
git add README.md
git commit -m "docs: describe conditional base + ISO CI builds"
```

- [ ] **Step 5: Push the branch and observe the pipelines**

```bash
git push -u origin feat/conditional-base-iso-builds
```

The very first push of this branch has an "all changed" delta (new branch), so **base builds** in both pipelines and `base:feat-conditional-base-iso-builds` is created. Confirm in the GitLab pipeline UI and the GitHub Actions run:
- GitLab: `build-base` ran, `build-systems` ran, `build-iso` ran.
- GitHub: `changes` → `base_changed=true`; `base`, `systems`, `iso` all ran.

- [ ] **Step 6: Verify the skip path — system-only change**

Make a trivial system-only change and push:

```bash
printf '\n' >> systems/rtx4000ada/README.md
git commit -am "test: system-only change (base should skip)"
git push
```

Expected:
- GitHub: `changes` → `base_changed=false`, `iso_config_changed=false`; `base` **skipped**, `systems` **ran** (`FROM base:feat-...` resolves to the prior build), `iso` **skipped**.
- GitLab: `build-base` **skipped/not created**, `build-systems` **ran**, `build-iso` **skipped**.

If `systems` did not run on GitHub, the `if: ${{ !cancelled() && needs.base.result != 'failure' }}` guard is wrong — a skipped `base` must not block it. Fix and re-push.

- [ ] **Step 7: Verify the ISO path — kickstart-only change**

```bash
printf '\n' >> bib/iso-config.toml
git commit -am "test: kickstart-only change (ISO should build, base should skip)"
git push
```

Expected:
- GitHub: `base_changed=false`, `iso_config_changed=true`; `base` **skipped**, `systems` **ran**, `iso` **ran**.
- GitLab: `build-base` **skipped**, `build-iso` **ran**.

- [ ] **Step 8: Clean up the test commits**

Drop the two throwaway test commits (Steps 6–7) before opening the PR:

```bash
git reset --hard HEAD~2
git push --force-with-lease
```

(The pushes already produced the pipeline evidence; the commits themselves are not kept.)

---

## Self-Review

**Spec coverage:**
- "Base only on input changes" → Task 1 (GitLab), Task 2 Steps 3–4 (GitHub). ✓
- "ISO only when base built OR iso-config changed" → Task 1 Step 3, Task 2 Step 6. ✓
- "Systems always build" → Task 1 (systems untouched), Task 2 Step 5. ✓
- Base-input file set (5 files incl. `bib/config.toml`) → used verbatim in both tasks. ✓
- ISO-input adds `bib/iso-config.toml` → Task 1 Step 3, Task 2 Step 3 (`iso_re`). ✓
- New-branch / missing-tag safety → Task 2 Step 3 all-changed fallback; verified Task 3 Step 5. ✓
- Both pipelines → Task 1 (GitLab) + Task 2 (GitHub). ✓
- Known limitation (retention eviction) → documented in the spec; not a task (intentional). ✓

**Placeholder scan:** No TBD/TODO; all code blocks concrete; the one genuine unknown (GitLab `rules` input support) is resolved by Task 1 Step 1 with a concrete fallback (Step 2b) that works regardless. ✓

**Type/name consistency:** `changes.outputs.tag`, `changes.outputs.base_changed`, `changes.outputs.iso_config_changed` are defined in Task 2 Step 3 and consumed with identical names in Steps 4–6; `base_re`/`iso_re` identical between the Task 2 test (Step 1) and the workflow (Step 3). ✓
