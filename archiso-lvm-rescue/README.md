# Heini Arch LVM Rescue ISO

This directory contains a custom ArchISO profile based on the official
`releng` profile. The first purpose is simple: boot an Arch rescue/live ISO
with the local LVM resize helpers already available.

## Layout

- `profile/`: source ArchISO profile.
- `build-lvm-rescue-iso.sh`: repeatable build wrapper.
- `out/`: generated ISO output directory, created during build.

The build wrapper stages the current top-level files from `../lvm_scripts`
into the live ISO at:

- `/root/lvm-scripts/`
- `/usr/local/bin/lvm-math-inspect`
- `/usr/local/bin/lvm-move-space-safe`

Files ending in `.sh`, executable files, and files with a shebang are made
executable inside `/root/lvm-scripts/`. Plain notes remain non-executable.
Only the safer inspection/move helpers are placed on `PATH`.

## Build

From this directory:

```bash
sudo ./build-lvm-rescue-iso.sh
```

The ISO is written to:

```text
./out/
```

To stage the build profile without running `mkarchiso`:

```bash
sudo ./build-lvm-rescue-iso.sh --prepare-only
```

To clean the temporary build tree:

```bash
sudo ./build-lvm-rescue-iso.sh --clean
```

## Add More Files Later

For files that should exist inside the live system, add them under:

```text
profile/airootfs/
```

Example:

```text
profile/airootfs/root/my-notes.txt
profile/airootfs/usr/local/bin/my-helper
```

If a new file needs executable permissions or restricted ownership, add it to
`profile/profiledef.sh` in the `file_permissions` array.
