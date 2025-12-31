#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Export, remove, verify, and (optionally) reinstall Scoop/Chocolatey and
  repair WinGet. Includes a verification checklist and optional scheduled
  reboot/shutdown + auto-resume.

.DESCRIPTION
  This script aims to make package-manager removal/reinstall *repeatable* by:
    1) exporting what you had installed,
    2) removing (properly and/or by nuking directories),
    3) verifying no paths/env/PATH entries remain,
    4) optionally rebooting only if verification suggests locks/remnants,
    5) optionally reinstalling and repairing WinGet.

  Actions:
    Export  - write exports only (JSON + logs); no changes.
    Verify  - run checklist only (no changes).
    Remove  - remove managers per -Target and -Mode. Optional verify + reboot.
    Install - preflight verify (must be clean), then install managers and
              optionally repair WinGet.
    Cycle   - Export -> Remove -> Verify -> (reboot if needed) -> Install.
              If reboot is scheduled, a one-shot Scheduled Task can resume
              the Install phase at next logon.

  Targets:
    Scoop        - affects per-user Scoop (and optionally the default global
                   root under %ProgramData%\scoop if present).
    Chocolatey   - affects Chocolatey under %ProgramData%\chocolatey and
                   per-user caches under %USERPROFILE%\.chocolatey.
    Both         - do both.

  Modes:
    Proper          - attempt manager-driven uninstall where applicable,
                      then clean PATH/env.
    Nuke            - skip manager uninstall; directly delete known dirs and
                      clean PATH/env.
    ProperThenNuke  - attempt Proper, then always do the Nuke pass.

  Reboot/shutdown policy:
    Never             - never schedule power actions.
    IfNeeded          - schedule only if verification indicates it helps
                        (e.g., locked remnants, failed deletions, services
                        that could not be stopped).
    AlwaysAfterRemove - always schedule after removal (rarely justified).

  Notes on WinGet:
    WinGet is part of Microsoft "App Installer". Repair is attempted via:
      - Add-AppxPackage -RegisterByFamilyName ... Microsoft.DesktopAppInstaller...
      - Repair-WinGetPackageManager (Microsoft.WinGet.Client module)
    (Both are best-effort; availability depends on Windows edition/state.)

  Logging / artifacts:
    - A timestamped -ExportDir is created by default.
    - Logs and JSON exports are written there:
        pkgmgr-purge.log
        scoop-state.json
        scoop-export.json (verbatim, if scoop export works)
        choco-state.json
        choco-packages.config (if choco export works)
        verify-*.json reports

  SAFETY:
    - Destructive by design. Use -WhatIf first.
    - Use -Force to skip the interactive "YES" prompt.
    - -BruteForce uses cmd.exe rmdir /s /q as a fallback and therefore
      requires -Force.

.PARAMETER Action
  Export | Verify | Remove | Install | Cycle

.PARAMETER Target
  Scoop | Chocolatey | Both

.PARAMETER Mode
  Proper | Nuke | ProperThenNuke

.PARAMETER ExportDir
  Output directory for logs/exports/reports. Created if missing.

.PARAMETER BruteForce
  Adds a second deletion pass using cmd.exe rmdir /s /q if Remove-Item fails.
  Requires -Force.

.PARAMETER Force
  Skips the interactive safety prompt. Also required for -BruteForce.

.PARAMETER RebootPolicy
  Never | IfNeeded | AlwaysAfterRemove

.PARAMETER PowerAction
  Reboot | Shutdown

.PARAMETER PowerDelaySeconds
  Delay before reboot/shutdown is executed (shutdown.exe /t).

.PARAMETER VerifyAfterRemoval
  After removal, run the verification checklist and write verify-after-remove.json.
  If verification suggests, schedule reboot/shutdown per -RebootPolicy.

.PARAMETER AutoResumeAfterReboot
  If Action=Cycle and a reboot/shutdown is scheduled, create a one-shot
  Scheduled Task that resumes with -Action Install at next logon.

.PARAMETER AutoElevateForChocolatey
  If Chocolatey is targeted and the session is not elevated, this script can
  relaunch itself elevated for Chocolatey actions (requires running from a saved
  .ps1 file, i.e. $PSCommandPath exists).

.PARAMETER UninstallChocolateyPackages
  If set, attempts to uninstall all Chocolatey-managed packages before removing
  Chocolatey itself. WARNING: This can remove applications installed outside
  Chocolatey's own directory (e.g., under Program Files).

.PARAMETER RepairWinGetOnInstall
  If set (default), attempts to repair WinGet during Install/Cycle.

.EXAMPLE
  # 1) Scoop only: "nuke" removal (direct deletion), verify afterward
  .\nuke-install-managers.ps1 -Action Remove -Target Scoop -Mode Nuke

.EXAMPLE
  # 2) Chocolatey only: proper then nuke, with elevation if needed, verify, and
  #    schedule reboot only if verification suggests locks/remnants.
  .\nuke-install-managers.ps1 -Action Remove -Target Chocolatey -Mode ProperThenNuke `
    -RebootPolicy IfNeeded

.EXAMPLE
  # 3) Both: export + remove + verify; no install; do not reboot.
  .\nuke-install-managers.ps1 -Action Remove -Target Both -Mode ProperThenNuke `
    -RebootPolicy Never

.EXAMPLE
  # 4) Full cycle for both: export -> remove -> verify -> reboot if needed -> install
  #    (resume automatically after reboot). Non-interactive.
  .\nuke-install-managers.ps1 -Action Cycle -Target Both -Mode ProperThenNuke -Force

.EXAMPLE
  # 5) Verify only: fails with exit code 2 if remnants are detected
  .\nuke-install-managers.ps1 -Action Verify -Target Both

.EXAMPLE
  # 6) Export only (inventory): creates state files without changing anything
  .\nuke-install-managers.ps1 -Action Export -Target Both -ExportDir C:\temp\pm-backup

.EXAMPLE
  # 7) Dry run: show what would be deleted/changed
  .\nuke-install-managers.ps1 -Action Remove -Target Both -Mode ProperThenNuke -WhatIf

.EXAMPLE
  # 8) "Triple-tap" removal: ProperThenNuke + BruteForce fallback, non-interactive
  #    WARNING: this is intentionally aggressive.
  .\nuke-install-managers.ps1 -Action Remove -Target Both -Mode ProperThenNuke `
    -Force -BruteForce

.EXAMPLE
  # 9) Chocolatey removal AND uninstall all choco packages first (very destructive)
  .\nuke-install-managers.ps1 -Action Remove -Target Chocolatey -Mode ProperThenNuke `
    -UninstallChocolateyPackages -Force

.OUTPUTS
  Exit codes:
    0  - success
    2  - verification failed (remnants detected) in Verify mode, or after removal

#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [ValidateSet('Export','Verify','Remove','Install','Cycle')]
  [string] $Action = 'Remove',

  [ValidateSet('Scoop', 'Chocolatey', 'Both')]
  [string] $Target = 'Both',

  [ValidateSet('Proper', 'Nuke', 'ProperThenNuke')]
  [string] $Mode = 'ProperThenNuke',

  [Parameter()]
  [string] $ExportDir = (Join-Path -Path (Get-Location) `
    -ChildPath ("pkgmgr-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))),

  [switch] $BruteForce,
  [switch] $Force,

  [ValidateSet('Never','IfNeeded','AlwaysAfterRemove')]
  [string] $RebootPolicy = 'IfNeeded',

  [ValidateSet('Reboot','Shutdown')]
  [string] $PowerAction = 'Reboot',

  [int] $PowerDelaySeconds = 30,

  [switch] $VerifyAfterRemoval = $true,

  [switch] $AutoResumeAfterReboot = $true,

  [switch] $AutoElevateForChocolatey = $true,

  [switch] $UninstallChocolateyPackages,

  [switch] $RepairWinGetOnInstall = $true
)

# ...rest of your script unchanged...

