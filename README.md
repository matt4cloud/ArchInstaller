# ArchInstaller

Public snapshot of a private, four-stage Arch Linux installation workflow.
This repository is a code publication boundary, not a complete project backup
or a general-purpose Arch Linux installer.

Current snapshot: `2.6.0`.

The workflow builds an opinionated system based on:

```text
UEFI + UKI + LUKS2 + Btrfs + Secure Boot-ready + Wayland + sway
```

Installation order:

1. `archinstall.sh` — live ISO stage
2. `archconfig1.sh` — configuration inside `arch-chroot`
3. `archconfig2.sh` — package installation after the first boot
4. `archconfig3.sh` — finalization after the second boot

The public repository contains only these installation stages. Hardware data,
internal documentation, generated deployment artifacts, recovery material,
and maintainer working files are intentionally kept outside this Git boundary.

The scripts are tailored to a fixed maintainer-controlled environment and are
published as a reference implementation. They perform destructive disk and
system operations and must not be run without reviewing the source and
adapting the workflow to the target environment.
