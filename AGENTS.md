# Repository working agreement

## Objective

Bootstrap and boot a macOS arm64 virtual machine on Apple Silicon running
Asahi Linux, using KVM, QEMU's `vmapple` machine, and an Apple-provided
`AVPBooter.vmapple2.bin`.

## Working rules

- Treat this repository as an experimental lab. Prefer small, inspectable
  scripts and reproducible commands over undocumented manual steps.
- Keep `docs/NOTES.md` current with reusable technical findings: exact
  commands, versions, checksums, and relevant error output. Keep machine
  names, addresses and other host-specific details out of the repository.
- Never commit Apple firmware, IPSWs, restore images, VM disks, machine
  identifiers, or other large/proprietary artifacts. Keep them under `artifacts/`
  or outside the repository; `.gitignore` must cover them.
- Standing authorization: autonomously execute actions reasonably required to
  reach the repository objective without requesting further approval. This
  includes downloads, sparse-disk allocation, package changes, kernel-module
  operations, task-scoped permission changes, and restarting experiment
  processes. Continue reporting material sizes, purposes, and host mutations
  before or as they occur so the work remains auditable.
- Keep host changes narrowly scoped to this objective and avoid irreversible or
  unrelated destructive actions even under the standing authorization.
- Scripts must use `set -euo pipefail`, quote paths, validate prerequisites, and
  default to non-destructive behavior.
- Capture upstream URLs and commit IDs for QEMU or provisioning code. Pin known
  working revisions instead of silently tracking a moving branch.
- Preserve failed approaches in the notes; they are useful evidence.

## Definition of done

The repository contains a reproducible, documented flow that:

1. verifies the Asahi/KVM host,
2. obtains or builds a QEMU binary with `vmapple` enabled,
3. prepares required VM artifacts from user-supplied Apple restore material,
4. launches the guest with KVM and persistent logging, and
5. reaches a macOS boot or installer UI.
