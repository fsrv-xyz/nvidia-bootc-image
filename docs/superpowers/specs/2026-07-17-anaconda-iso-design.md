# Anaconda installer ISO for the base image — Design

**Date:** 2026-07-17
**Status:** Approved (Design)

## Goal

Build an **Anaconda installer ISO** for the **base image** in both CIs, each ISO
referencing its own registry (GitLab → ref.ci base, GitHub → ghcr base). The ISO does
an **unattended** install of the base image; the user later `bootc switch`es to a
system image (rtx3080ti / rtx4000ada). Then test the ISO by installing a fresh VM.

## Decisions

| Topic | Decision |
|---|---|
| ISO source | **base image only**, per registry (ref.ci base for GitLab, ghcr base for GitHub) |
| Tool | `bootc-image-builder --type anaconda-iso` (privileged container; a custom CI job — the `container` component can't build ISOs) |
| Unattended | kickstart baked in: `text --non-interactive`, `zerombr`, `clearpart --all`, `autopart`, `reboot`. BIB auto-adds the `ostreecontainer` install line. root password + SSH key come from the image. |
| Installed system reference | the registry image ref passed to BIB → the installed system tracks that registry for `bootc upgrade` |
| Storage | GitLab: generic package registry; GitHub: workflow artifact (+ release asset on tags) |
| Test | fresh VM (111) installed from the ISO; VM 110 untouched. Verify the installed system is the base (nvidia driver, no vLLM, root password, IPv4-DHCP + IPv6). |

## Architecture

### Kickstart (`bib/iso-config.toml`)

```toml
[customizations.installer.kickstart]
contents = """
text --non-interactive
zerombr
clearpart --all --initlabel --disklabel=gpt
autopart --noswap --type=plain
reboot
"""
```

BIB appends the `ostreecontainer` command that installs the source image, so it must
not be listed here. `anaconda-iso` installs to the first disk found; the kickstart
makes it fully unattended and reboots into the installed system.

### Local helper (`make-iso.sh`)

Analogous to `make-disk.sh` but `--type anaconda-iso`. Pulls the registry base image
into the Docker host's containers-storage (podman-in-docker), then runs BIB `--local`
against that ref with `bib/iso-config.toml`. Output: `<docker-host>:/root/bib-output/bootiso/install.iso`.
Uses your local Docker (set `DOCKER_HOST` for a remote engine). `IMAGE_REF` defaults
to the ref.ci base.

### GitLab CI (`.gitlab-ci.yml`)

New stage `build-iso` after `build-base`. A custom job (`image: docker:cli`, same
remote-Docker env as the `container` component) runs BIB `--type anaconda-iso` against
`$CI_REGISTRY_IMAGE/base:$CI_COMMIT_REF_SLUG`, then uploads the ISO to the project's
generic package registry (`.../packages/generic/anaconda-iso/<ref>/...`).

### GitHub Actions (`.github/workflows/build-images.yml`)

New job `iso` (`needs: base`) runs BIB `--type anaconda-iso` (privileged) against
`ghcr.io/${{ github.repository }}/base:<tag>`, uploads the ISO as a workflow artifact
(and as a release asset on tag builds).

## Validation

1. Local: build the ISO (ref.ci base), verify `install.iso` exists.
2. Transfer to Proxmox `node2` ISO storage; create VM 111 (q35, SeaBIOS, serial) with
   the ISO attached + an empty disk; boot → unattended install → reboot.
3. Verify the installed VM 111 booted the **base** image: `bootc status` shows the
   ref.ci base ref; nvidia driver present; **no** vLLM quadlet; root password + SSH
   key work; IPv4-DHCP + IPv6.
4. VM 110 remains untouched.
5. Both CI ISO jobs build green.

## Notes / out of scope

- ISOs for system images (would embed vLLM) — not built; users switch post-install.
- The ISO/installer environment needs network only if BIB references (not embeds) the
  image; `anaconda-iso` embeds the image, so install is offline.
- GPU passthrough is not required for the base install/boot test; a GPU + `bootc switch`
  to a system image is the separate, already-validated path.
