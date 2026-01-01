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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Globals
# -----------------------------
$script:LogFile = $null
$script:DeleteFailures = New-Object System.Collections.Generic.List[string]
$script:ResumeTaskName = "PkgMgrCycleResume"
$script:StateFile = $null

# -----------------------------
# Utility
# -----------------------------
function Test-IsAdministrator() {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log([string] $Level, [string] $Message) {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
  $line = "[${ts}] [$Level] $Message"
  Write-Host $line
  if ($script:LogFile) {
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
  }
}

function Ensure-Directory([string] $Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Normalize-Token([string] $s) {
  if ($null -eq $s) { return "" }
  $t = $s.Trim()
  if ($t -eq "") { return "" }
  $t = $t.TrimEnd('\')
  $t = $t -replace '/', '\'
  $t = [Environment]::ExpandEnvironmentVariables($t)
  return $t.ToLowerInvariant()
}

function Assert-SafeDeleteTarget([string] $Path) {
  $full = [IO.Path]::GetFullPath($Path)

  $bad = @(
    [IO.Path]::GetPathRoot($full),
    [IO.Path]::GetFullPath($env:SystemRoot),
    [IO.Path]::GetFullPath($env:ProgramFiles),
    [IO.Path]::GetFullPath(${env:ProgramFiles(x86)}),
    [IO.Path]::GetFullPath($env:USERPROFILE),
    [IO.Path]::GetFullPath($env:ProgramData),
    [IO.Path]::GetFullPath((Get-Location).Path)
  ) | Sort-Object -Unique

  foreach ($b in $bad) {
    if ($full -eq $b) {
      throw "Refusing to delete a high-risk path: '$full'"
    }
  }

  $leaf = (Split-Path -Leaf $full).ToLowerInvariant()
  if ($leaf -notin @('scoop', 'chocolatey', '.chocolatey', 'http-cache',
                     'cache', 'shims', 'buckets', 'apps', 'persist',
                     'choco-cache', 'chocolateytemp', 'temp')) {
    if (-not $Force) {
      throw ("Refusing to delete unexpected leaf '$leaf' at '$full'. " +
        "Use -Force if you are certain.")
    }
  }
}

function Remove-DirectorySafe([string] $Path, [switch] $TryBruteForce) {
  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Log "INFO" "Not present: $Path"
    return
  }

  Assert-SafeDeleteTarget -Path $Path

  if ($PSCmdlet.ShouldProcess($Path, "Remove directory recursively")) {
    try {
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
      Write-Log "INFO" "Removed: $Path"
    } catch {
      Write-Log "WARN" "Remove-Item failed for '$Path': $($_.Exception.Message)"
      if ($TryBruteForce) {
        if (-not $Force) {
          throw "BruteForce requested but -Force not specified. Aborting."
        }
        Write-Log "WARN" "BruteForce pass: cmd.exe rmdir /s /q `"$Path`""
        & cmd.exe /c "rmdir /s /q `"$Path`"" | Out-Null
      }

      if (Test-Path -LiteralPath $Path) {
        Write-Log "ERROR" "Still exists after deletion attempts: $Path"
        $script:DeleteFailures.Add($Path) | Out-Null
      }
    }
  }
}

function Get-EnvRegKey([ValidateSet('User', 'Machine')] [string] $Scope) {
  if ($Scope -eq 'User') {
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
      'Environment', $true
    )
  }

  return [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
    'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true
  )
}

function Get-EnvValueRaw(
  [ValidateSet('User', 'Machine')] [string] $Scope,
  [string] $Name
) {
  $k = Get-EnvRegKey -Scope $Scope
  try {
    return $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
  } finally {
    $k.Close()
  }
}

function Set-EnvValueRaw(
  [ValidateSet('User', 'Machine')] [string] $Scope,
  [string] $Name,
  [AllowNull()] [string] $Value,
  [Microsoft.Win32.RegistryValueKind] $Kind =
    [Microsoft.Win32.RegistryValueKind]::ExpandString
) {
  $k = Get-EnvRegKey -Scope $Scope
  try {
    if ($null -eq $Value) {
      if ($k.GetValueNames() -contains $Name) {
        if ($PSCmdlet.ShouldProcess("$Scope env:$Name", "Remove env var")) {
          $k.DeleteValue($Name, $false)
          Write-Log "INFO" "Removed env var ($Scope): $Name"
        }
      }
      return
    }

    if ($PSCmdlet.ShouldProcess("$Scope env:$Name", "Set env var")) {
      $k.SetValue($Name, $Value, $Kind)
      Write-Log "INFO" "Set env var ($Scope): $Name = $Value"
    }
  } finally {
    $k.Close()
  }
}

function Get-PathEntriesRaw([ValidateSet('User', 'Machine')] [string] $Scope) {
  $raw = Get-EnvValueRaw -Scope $Scope -Name 'Path'
  if ($null -eq $raw -or $raw -eq '') { return @() }
  return @($raw -split ';' | ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne '' })
}

function Set-PathEntriesRaw(
  [ValidateSet('User', 'Machine')] [string] $Scope,
  [string[]] $Entries
) {
  $new = ($Entries | Where-Object { $_ -and $_.Trim() -ne '' }) -join ';'
  Set-EnvValueRaw -Scope $Scope -Name 'Path' -Value $new `
    -Kind ([Microsoft.Win32.RegistryValueKind]::ExpandString)
}

function Remove-PathEntry(
  [ValidateSet('User', 'Machine')] [string] $Scope,
  [string] $Entry
) {
  $want = Normalize-Token $Entry
  if ($want -eq "") { return }

  $entries = Get-PathEntriesRaw -Scope $Scope
  $kept = New-Object System.Collections.Generic.List[string]

  $removed = $false
  foreach ($e in $entries) {
    $n = Normalize-Token $e
    if ($n -eq $want) {
      $removed = $true
      continue
    }
    $kept.Add($e) | Out-Null
  }

  if ($removed) {
    if ($PSCmdlet.ShouldProcess("$Scope PATH", "Remove entry: $Entry")) {
      Set-PathEntriesRaw -Scope $Scope -Entries $kept.ToArray()
      Write-Log "INFO" "Removed PATH entry ($Scope): $Entry"
    }
  } else {
    Write-Log "INFO" "PATH entry not found ($Scope): $Entry"
  }
}

function Export-Json([string] $Path, [object] $Obj) {
  $json = $Obj | ConvertTo-Json -Depth 12
  Set-Content -LiteralPath $Path -Value $json -Encoding utf8
  Write-Log "INFO" "Wrote JSON: $Path"
}

function Get-CommandPathOrNull([string] $Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# -----------------------------
# Locations
# -----------------------------
function Get-ScoopLocations() {
  $root = $env:SCOOP
  if (-not $root) { $root = (Join-Path $env:USERPROFILE 'scoop') }

  $global = $env:SCOOP_GLOBAL
  if (-not $global) { $global = (Join-Path $env:ProgramData 'scoop') }

  $cfg = (Join-Path $env:USERPROFILE '.config\scoop')

  [pscustomobject]@{
    Root       = $root
    GlobalRoot = $global
    ConfigRoot = $cfg
    Shims      = (Join-Path $root 'shims')
  }
}

function Get-ChocoLocations() {
  $install = $env:ChocolateyInstall
  if (-not $install) { $install = (Join-Path $env:ProgramData 'chocolatey') }

  $tempCache = (Join-Path $env:TEMP 'chocolatey')
  $userDot   = (Join-Path $env:USERPROFILE '.chocolatey')

  [pscustomobject]@{
    InstallRoot = $install
    TempCache   = $tempCache
    UserDot     = $userDot
    UserHttp    = (Join-Path $userDot 'http-cache')
    Bin         = (Join-Path $install 'bin')
  }
}

# -----------------------------
# Export state (best-effort)
# -----------------------------
function Export-ScoopState([string] $Dir) {
  $loc = Get-ScoopLocations
  $apps = @()
  $buckets = @()
  $gapps = @()

  if (Test-Path -LiteralPath (Join-Path $loc.Root 'apps')) {
    Get-ChildItem -LiteralPath (Join-Path $loc.Root 'apps') -Directory `
      -ErrorAction SilentlyContinue |
      ForEach-Object {
        $name = $_.Name
        if ($name -ne 'scoop') { $apps += $name }
      }
  }

  if (Test-Path -LiteralPath (Join-Path $loc.Root 'buckets')) {
    Get-ChildItem -LiteralPath (Join-Path $loc.Root 'buckets') -Directory `
      -ErrorAction SilentlyContinue |
      ForEach-Object { $buckets += $_.Name }
  }

  if (Test-Path -LiteralPath (Join-Path $loc.GlobalRoot 'apps')) {
    Get-ChildItem -LiteralPath (Join-Path $loc.GlobalRoot 'apps') -Directory `
      -ErrorAction SilentlyContinue |
      ForEach-Object {
        $name = $_.Name
        if ($name -ne 'scoop') { $gapps += $name }
      }
  }

  $scoopExe = Get-CommandPathOrNull 'scoop'
  $exportText = $null
  if ($scoopExe) {
    try {
      $exportText = & scoop export 2>$null
      if ($exportText) {
        $p = Join-Path $Dir 'scoop-export.json'
        Set-Content -LiteralPath $p -Value $exportText -Encoding utf8
        Write-Log "INFO" "Wrote Scoop export (verbatim): $p"
      }
    } catch {
      Write-Log "WARN" "scoop export failed: $($_.Exception.Message)"
    }
  }

  $obj = [pscustomobject]@{
    Detected      = [bool]($scoopExe -or (Test-Path -LiteralPath $loc.Root))
    ScoopCommand  = $scoopExe
    Root          = $loc.Root
    GlobalRoot    = $loc.GlobalRoot
    ConfigRoot    = $loc.ConfigRoot
    Shims         = $loc.Shims
    Buckets       = ($buckets | Sort-Object)
    Apps          = ($apps | Sort-Object)
    GlobalApps    = ($gapps | Sort-Object)
    Env           = @{
      SCOOP        = $env:SCOOP
      SCOOP_GLOBAL = $env:SCOOP_GLOBAL
    }
  }

  Export-Json -Path (Join-Path $Dir 'scoop-state.json') -Obj $obj
}

function Export-ChocoState([string] $Dir) {
  $loc = Get-ChocoLocations
  $chocoExe = Get-CommandPathOrNull 'choco'
  $pkgs = @()

  if ($chocoExe) {
    try {
      $pconfig = Join-Path $Dir 'choco-packages.config'
      & choco export --output-file-path="'$pconfig'" 2>$null | Out-Null
      if (Test-Path -LiteralPath $pconfig) {
        Write-Log "INFO" "Wrote Chocolatey export: $pconfig"
      }
    } catch {
      Write-Log "WARN" "choco export failed: $($_.Exception.Message)"
    }

    try {
      $out = & choco list --limit-output 2>$null
      if ($out) {
        $pkgs = @(
          $out | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^[A-Za-z0-9\.\-_]+\|.*$' }
        )
      }
    } catch {
      Write-Log "WARN" "choco list failed: $($_.Exception.Message)"
    }
  }

  $obj = [pscustomobject]@{
    Detected       = [bool]($chocoExe -or (Test-Path -LiteralPath $loc.InstallRoot))
    ChocoCommand   = $chocoExe
    InstallRoot    = $loc.InstallRoot
    Bin            = $loc.Bin
    TempCache      = $loc.TempCache
    UserDot        = $loc.UserDot
    UserHttpCache  = $loc.UserHttp
    PackagesRaw    = $pkgs
    Env            = @{
      ChocolateyInstall        = $env:ChocolateyInstall
      ChocolateyToolsLocation  = $env:ChocolateyToolsLocation
      ChocolateyLastPathUpdate = $env:ChocolateyLastPathUpdate
    }
  }

  Export-Json -Path (Join-Path $Dir 'choco-state.json') -Obj $obj
}

# -----------------------------
# Detection: services/tasks/processes referencing roots
# -----------------------------
function Get-ServicesReferencingPaths([string[]] $Needles) {
  $need = @($Needles | ForEach-Object { Normalize-Token $_ } |
    Where-Object { $_ -ne "" })

  $hits = @()
  try {
    $svcs = Get-CimInstance Win32_Service -ErrorAction Stop
    foreach ($s in $svcs) {
      $p = $s.PathName
      if (-not $p) { continue }
      $pn = Normalize-Token $p
      foreach ($n in $need) {
        if ($pn -like "*$n*") {
          $hits += [pscustomobject]@{
            Name     = $s.Name
            State    = $s.State
            StartMode= $s.StartMode
            PathName = $s.PathName
            Match    = $n
          }
          break
        }
      }
    }
  } catch {
    Write-Log "WARN" "Service scan failed: $($_.Exception.Message)"
  }
  return $hits
}

function Stop-ServicesIfRunning($ServiceHits) {
  $failed = @()
  foreach ($h in $ServiceHits) {
    if ($h.State -ne 'Running') { continue }
    try {
      Write-Log "WARN" "Stopping service: $($h.Name) (matches $($h.Match))"
      Stop-Service -Name $h.Name -Force -ErrorAction Stop
    } catch {
      Write-Log "ERROR" "Failed to stop service $($h.Name): $($_.Exception.Message)"
      $failed += $h
    }
  }
  return $failed
}

function Get-ScheduledTasksReferencingPaths([string[]] $Needles) {
  $need = @($Needles | ForEach-Object { Normalize-Token $_ } |
    Where-Object { $_ -ne "" })

  $hits = @()
  try {
    $tasks = Get-ScheduledTask -ErrorAction Stop
    foreach ($t in $tasks) {
      foreach ($a in $t.Actions) {
        $blob = ($a.Execute + " " + $a.Arguments)
        $bn = Normalize-Token $blob
        foreach ($n in $need) {
          if ($bn -like "*$n*") {
            $hits += [pscustomobject]@{
              TaskName = $t.TaskName
              TaskPath = $t.TaskPath
              Execute  = $a.Execute
              Args     = $a.Arguments
              Match    = $n
            }
            break
          }
        }
      }
    }
  } catch {
    Write-Log "WARN" "Scheduled task scan failed: $($_.Exception.Message)"
  }
  return $hits
}

function Get-ProcessesWithPathsLike([string[]] $Needles) {
  $need = @($Needles | ForEach-Object { Normalize-Token $_ } |
    Where-Object { $_ -ne "" })

  $hits = @()
  try {
    $procs = Get-Process -ErrorAction Stop
    foreach ($p in $procs) {
      $path = $null
      try { $path = $p.Path } catch { $path = $null }
      if (-not $path) { continue }
      $pn = Normalize-Token $path
      foreach ($n in $need) {
        if ($pn -like "*$n*") {
          $hits += [pscustomobject]@{
            Name = $p.ProcessName
            Id   = $p.Id
            Path = $path
            Match= $n
          }
          break
        }
      }
    }
  } catch {
    Write-Log "WARN" "Process scan failed: $($_.Exception.Message)"
  }
  return $hits
}

# -----------------------------
# Verify checklist
# -----------------------------
function Invoke-PkgMgrVerify([string] $Which) {
  $needles = @()
  $pathsMustBeGone = @()
  $envMustBeGone = @()
  $pathEntriesMustBeGone = @()

  if ($Which -in @('Scoop','Both')) {
    $s = Get-ScoopLocations
    $pathsMustBeGone += @($s.ConfigRoot, $s.Root, $s.GlobalRoot)
    $envMustBeGone   += @(
      @{ Scope='User';    Name='SCOOP'        },
      @{ Scope='User';    Name='SCOOP_GLOBAL' },
      @{ Scope='Machine'; Name='SCOOP'        },
      @{ Scope='Machine'; Name='SCOOP_GLOBAL' }
    )
    $pathEntriesMustBeGone += @(
      @{ Scope='User';    Entry=$s.Shims },
      @{ Scope='Machine'; Entry=$s.Shims }
    )
    $needles += @($s.Root, $s.GlobalRoot, $s.Shims, $s.ConfigRoot)
  }

  if ($Which -in @('Chocolatey','Both')) {
    $c = Get-ChocoLocations
    $pathsMustBeGone += @($c.TempCache, $c.UserDot, $c.InstallRoot)
    $envMustBeGone   += @(
      @{ Scope='User';    Name='ChocolateyInstall'        },
      @{ Scope='User';    Name='ChocolateyToolsLocation'  },
      @{ Scope='User';    Name='ChocolateyLastPathUpdate' },
      @{ Scope='Machine'; Name='ChocolateyInstall'        },
      @{ Scope='Machine'; Name='ChocolateyToolsLocation'  },
      @{ Scope='Machine'; Name='ChocolateyLastPathUpdate' }
    )
    $pathEntriesMustBeGone += @(
      @{ Scope='User';    Entry=$c.Bin },
      @{ Scope='Machine'; Entry=$c.Bin }
    )
    $needles += @($c.InstallRoot, $c.Bin, $c.UserDot)
  }

  $presentPaths = @()
  foreach ($p in ($pathsMustBeGone | Sort-Object -Unique)) {
    if ($p -and (Test-Path -LiteralPath $p)) {
      $presentPaths += $p
    }
  }

  $presentEnv = @()
  foreach ($e in $envMustBeGone) {
    $v = Get-EnvValueRaw -Scope $e.Scope -Name $e.Name
    if ($null -ne $v -and $v -ne '') {
      $presentEnv += [pscustomobject]@{
        Scope = $e.Scope
        Name  = $e.Name
        Value = $v
      }
    }
  }

  $presentPathEntries = @()
  foreach ($pe in $pathEntriesMustBeGone) {
    $entries = Get-PathEntriesRaw -Scope $pe.Scope
    $want = Normalize-Token $pe.Entry
    if ($entries | Where-Object { (Normalize-Token $_) -eq $want }) {
      $presentPathEntries += [pscustomobject]@{
        Scope = $pe.Scope
        Entry = $pe.Entry
      }
    }
  }

  $svcHits  = Get-ServicesReferencingPaths -Needles $needles
  $taskHits = Get-ScheduledTasksReferencingPaths -Needles $needles
  $procHits = Get-ProcessesWithPathsLike -Needles $needles

  $ok = ($presentPaths.Count -eq 0 -and
         $presentEnv.Count -eq 0 -and
         $presentPathEntries.Count -eq 0 -and
         $script:DeleteFailures.Count -eq 0)

  [pscustomobject]@{
    Ok = $ok
    PresentPaths = $presentPaths
    PresentEnvVars = $presentEnv
    PresentPathEntries = $presentPathEntries
    ServicesReferencingRoots = $svcHits
    TasksReferencingRoots = $taskHits
    ProcessesFromRoots = $procHits
    DeleteFailures = $script:DeleteFailures.ToArray()
  }
}

function Write-VerifyReport([string] $Dir, [object] $Report, [string] $Name) {
  $p = Join-Path $Dir $Name
  Export-Json -Path $p -Obj $Report
}

# -----------------------------
# Remove operations
# -----------------------------
function Uninstall-Scoop([string] $How, [switch] $TryBruteForce) {
  $loc = Get-ScoopLocations
  $scoopExe = Get-CommandPathOrNull 'scoop'

  Write-Log "INFO" "Scoop mode: $How"
  Write-Log "INFO" "Scoop root: $($loc.Root)"
  Write-Log "INFO" "Scoop global root: $($loc.GlobalRoot)"
  Write-Log "INFO" "Scoop config root: $($loc.ConfigRoot)"

  if ($How -in @('Proper', 'ProperThenNuke') -and $scoopExe) {
    try {
      Write-Log "INFO" "Attempting: scoop uninstall scoop"
      if ($PSCmdlet.ShouldProcess("scoop", "Uninstall Scoop via Scoop")) {
        & scoop uninstall scoop
      }
    } catch {
      Write-Log "WARN" "scoop uninstall scoop failed: $($_.Exception.Message)"
    }
  }

  if ($How -in @('Nuke', 'ProperThenNuke')) {
    Remove-PathEntry -Scope User    -Entry $loc.Shims
    Remove-PathEntry -Scope Machine -Entry $loc.Shims

    Set-EnvValueRaw -Scope User    -Name 'SCOOP'        -Value $null
    Set-EnvValueRaw -Scope User    -Name 'SCOOP_GLOBAL' -Value $null
    Set-EnvValueRaw -Scope Machine -Name 'SCOOP'        -Value $null
    Set-EnvValueRaw -Scope Machine -Name 'SCOOP_GLOBAL' -Value $null

    Remove-DirectorySafe -Path $loc.ConfigRoot -TryBruteForce:$TryBruteForce
    Remove-DirectorySafe -Path $loc.Root       -TryBruteForce:$TryBruteForce
    Remove-DirectorySafe -Path $loc.GlobalRoot -TryBruteForce:$TryBruteForce
  }
}

function Uninstall-Chocolatey(
  [string] $How,
  [switch] $TryBruteForce,
  [switch] $RemovePackages
) {
  $loc = Get-ChocoLocations
  $chocoExe = Get-CommandPathOrNull 'choco'

  Write-Log "INFO" "Chocolatey mode: $How"
  Write-Log "INFO" "Chocolatey install root: $($loc.InstallRoot)"

  if ($How -in @('Proper', 'ProperThenNuke') -and $RemovePackages -and $chocoExe) {
    try {
      Write-Log "WARN" "Requested uninstall of Chocolatey-managed packages."
      if ($PSCmdlet.ShouldProcess("Chocolatey packages", "Uninstall all packages")) {
        $lines = & choco list --limit-output 2>$null
        $names = @()
        foreach ($l in $lines) {
          $s = $l.Trim()
          if ($s -match '^([A-Za-z0-9\.\-_]+)\|') { $names += $Matches[1] }
        }
        $names = $names | Sort-Object -Unique
        foreach ($n in $names) {
          if ($n -eq 'chocolatey') { continue }
          Write-Log "INFO" "choco uninstall $n -y"
          & choco uninstall $n -y | Out-Null
        }
      }
    } catch {
      Write-Log "WARN" "Package uninstall pass failed: $($_.Exception.Message)"
    }
  }

  if ($How -in @('Nuke', 'ProperThenNuke')) {
    Remove-PathEntry -Scope Machine -Entry $loc.Bin
    Remove-PathEntry -Scope User    -Entry $loc.Bin

    foreach ($scope in @('Machine', 'User')) {
      Set-EnvValueRaw -Scope $scope -Name 'ChocolateyInstall'        -Value $null
      Set-EnvValueRaw -Scope $scope -Name 'ChocolateyToolsLocation'  -Value $null
      Set-EnvValueRaw -Scope $scope -Name 'ChocolateyLastPathUpdate' -Value $null
    }

    Remove-DirectorySafe -Path $loc.TempCache   -TryBruteForce:$TryBruteForce
    Remove-DirectorySafe -Path $loc.UserDot     -TryBruteForce:$TryBruteForce
    Remove-DirectorySafe -Path $loc.InstallRoot -TryBruteForce:$TryBruteForce
  }
}

# -----------------------------
# Install / Repair operations
# -----------------------------
function Install-Scoop() {
  # Scoop install guidance: the ScoopInstaller/Install project describes
  # downloading install.ps1 and running it; it also notes admin install is
  # disabled by default unless -RunAsAdmin is used. :contentReference[oaicite:5]{index=5}
  if (Test-IsAdministrator) {
    throw ("Refusing to install Scoop from an elevated session by default. " +
      "Run as standard user (recommended), or explicitly use the advanced " +
      "installer with -RunAsAdmin per ScoopInstaller/Install.")
  }

  if (Get-CommandPathOrNull 'scoop') {
    Write-Log "INFO" "Scoop already present."
    return
  }

  $tmp = Join-Path $env:TEMP ("scoop-install-" + [guid]::NewGuid().ToString())
  Ensure-Directory -Path $tmp
  $ps1 = Join-Path $tmp "install.ps1"

  Write-Log "INFO" "Downloading Scoop installer from get.scoop.sh ..."
  irm get.scoop.sh -OutFile $ps1

  if ($PSCmdlet.ShouldProcess("Scoop", "Install via installer script")) {
    & $ps1
  }
}

function Install-Chocolatey() {
  # Chocolatey recommends using an administrative shell for default installs.
  # :contentReference[oaicite:6]{index=6}
  if (-not (Test-IsAdministrator)) {
    throw "Chocolatey install (default path) requires elevation."
  }

  if (Get-CommandPathOrNull 'choco') {
    Write-Log "INFO" "Chocolatey already present."
    return
  }

  $cmd = @"
Set-ExecutionPolicy Bypass -Scope Process -Force;
[System.Net.ServicePointManager]::SecurityProtocol =
  [System.Net.ServicePointManager]::SecurityProtocol -bor 3072;
iex ((New-Object System.Net.WebClient).DownloadString(
  'https://community.chocolatey.org/install.ps1'
));
"@

  # install.ps1 is the official install script endpoint. :contentReference[oaicite:7]{index=7}
  if ($PSCmdlet.ShouldProcess("Chocolatey", "Install via official install.ps1")) {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd
  }
}

function Repair-WinGet() {
  # Supported guidance: WinGet is part of App Installer; Microsoft documents
  # re-registration by family name and Repair-WinGetPackageManager usage.
  # :contentReference[oaicite:8]{index=8}

  $winget = Get-CommandPathOrNull 'winget'
  if ($winget) {
    Write-Log "INFO" "winget already present: $winget"
    return
  }

  Write-Log "WARN" "winget not found; attempting App Installer re-registration..."
  try {
    Add-AppxPackage -RegisterByFamilyName -MainPackage `
      Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
    Write-Log "INFO" "Requested App Installer registration."
  } catch {
    Write-Log "WARN" "App Installer registration failed: $($_.Exception.Message)"
  }

  if (Get-CommandPathOrNull 'winget') {
    Write-Log "INFO" "winget now present after registration."
    return
  }

  Write-Log "WARN" "Attempting Repair-WinGetPackageManager via Microsoft.WinGet.Client..."
  try {
    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery
    Repair-WinGetPackageManager -AllUsers
  } catch {
    Write-Log "ERROR" "Repair-WinGetPackageManager failed: $($_.Exception.Message)"
  }
}

# -----------------------------
# Power actions + resume orchestration
# -----------------------------
function Invoke-SafetyPrompt() {
  if ($Force) { return }

  $msg = @(
    "DESTRUCTIVE OPERATION WARNING",
    "",
    "This script can remove Scoop/Chocolatey directories and caches.",
    "Type exactly:  YES  to continue."
  ) -join "`r`n"

  Write-Host $msg
  $ans = Read-Host "Confirm"
  if ($ans -ne 'YES') {
    throw "Aborted by user."
  }
}

function Save-ResumeState([string] $NextAction) {
  $script:StateFile = Join-Path $ExportDir "cycle-state.json"
  Export-Json -Path $script:StateFile -Obj ([pscustomobject]@{
    NextAction = $NextAction
    Target     = $Target
    Mode       = $Mode
    ExportDir  = $ExportDir
    Timestamp  = (Get-Date).ToString("o")
  })
}

function Register-ResumeTask([string] $ScriptPath, [string] $Args) {
  if (-not $AutoResumeAfterReboot) { return }
  if (-not $ScriptPath) {
    Write-Log "WARN" "No script path; cannot register resume task."
    return
  }

  $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $Args"
  Write-Log "WARN" "Registering one-shot resume task: $($script:ResumeTaskName)"

  try {
    # Per-user task at next logon (no admin required for current user).
    & schtasks.exe /Create /F /TN $script:ResumeTaskName /SC ONLOGON `
      /RL LIMITED /TR $cmd | Out-Null
  } catch {
    Write-Log "WARN" "Failed to create resume task: $($_.Exception.Message)"
  }
}

function Unregister-ResumeTaskIfPresent() {
  try {
    & schtasks.exe /Query /TN $script:ResumeTaskName 2>$null | Out-Null
    & schtasks.exe /Delete /F /TN $script:ResumeTaskName | Out-Null
    Write-Log "INFO" "Removed resume task: $($script:ResumeTaskName)"
  } catch {
    # ignore
  }
}

function Schedule-PowerAction([string] $Why) {
  $exe = "shutdown.exe"
  $args = @()
  if ($PowerAction -eq 'Reboot') {
    $args = @("/r","/t",$PowerDelaySeconds,"/c",$Why)
  } else {
    $args = @("/s","/t",$PowerDelaySeconds,"/c",$Why)
  }

  if ($PSCmdlet.ShouldProcess("System", "$PowerAction in $PowerDelaySeconds seconds")) {
    Write-Log "WARN" "Scheduling $PowerAction in $PowerDelaySeconds seconds: $Why"
    & $exe @args | Out-Null
  }
}

function Should-RebootFromReport([object] $Report, [object] $SvcStopFailures) {
  if ($RebootPolicy -eq 'Never') { return $false }
  if ($RebootPolicy -eq 'AlwaysAfterRemove') { return $true }

  if ($SvcStopFailures -and $SvcStopFailures.Count -gt 0) { return $true }
  if ($Report.PresentPaths.Count -gt 0) { return $true }
  if ($Report.DeleteFailures.Count -gt 0) { return $true }

  return $false
}

# -----------------------------
# Main
# -----------------------------
Ensure-Directory -Path $ExportDir
$script:LogFile = Join-Path $ExportDir 'pkgmgr-purge.log'
Write-Log "INFO" "ExportDir: $ExportDir"
Write-Log "INFO" "Action: $Action"
Write-Log "INFO" "Target: $Target"
Write-Log "INFO" "Mode: $Mode"
Write-Log "INFO" "Elevated: $(Test-IsAdministrator)"

if ($BruteForce -and -not $Force) {
  throw "-BruteForce requires -Force (explicit acknowledgement)."
}

# Resume mode: if the resume task calls us after reboot.
if ($Action -eq 'Install' -and $script:ResumeTaskName) {
  Unregister-ResumeTaskIfPresent
}

# Always export first (cheap and useful).
Export-ScoopState -Dir $ExportDir
Export-ChocoState -Dir $ExportDir

if ($Action -eq 'Export') {
  Write-Log "INFO" "Export complete."
  return
}

if ($Action -eq 'Verify') {
  $r = Invoke-PkgMgrVerify -Which $Target
  Write-VerifyReport -Dir $ExportDir -Report $r -Name "verify-report.json"
  if (-not $r.Ok) { exit 2 }
  exit 0
}

if ($Action -in @('Remove','Cycle')) {
  Invoke-SafetyPrompt

  # Pre-stop services that clearly reference Scoop/Choco roots (best effort).
  $needles = @()
  if ($Target -in @('Scoop','Both')) {
    $s = Get-ScoopLocations
    $needles += @($s.Root, $s.GlobalRoot, $s.ConfigRoot)
  }
  if ($Target -in @('Chocolatey','Both')) {
    $c = Get-ChocoLocations
    $needles += @($c.InstallRoot, $c.UserDot)
  }

  $svcHits = Get-ServicesReferencingPaths -Needles $needles
  $svcStopFailures = Stop-ServicesIfRunning -ServiceHits $svcHits

  # Uninstall
  $needChoco = ($Target -in @('Chocolatey','Both'))
  $needScoop = ($Target -in @('Scoop','Both'))

  if ($needChoco -and -not (Test-IsAdministrator) -and $AutoElevateForChocolatey) {
    if ($needScoop) {
      Uninstall-Scoop -How $Mode -TryBruteForce:$BruteForce
    }

    if (-not $PSCommandPath) {
      throw ("Chocolatey removal needs elevation and AutoElevate requires " +
        "running from a saved .ps1 file.")
    }

    $args = @(
      "-Target", "Chocolatey",
      "-Mode", $Mode,
      "-ExportDir", "`"$ExportDir`"",
      "-Action", "Remove",
      "-RebootPolicy", $RebootPolicy,
      "-PowerAction", $PowerAction,
      "-PowerDelaySeconds", $PowerDelaySeconds
    )
    if ($Force) { $args += "-Force" }
    if ($BruteForce) { $args += "-BruteForce" }
    if ($VerifyAfterRemoval) { $args += "-VerifyAfterRemoval" }
    if ($UninstallChocolateyPackages) { $args += "-UninstallChocolateyPackages" }

    Write-Log "INFO" "Re-launching elevated for Chocolatey removal..."
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass",
      "-File", "`"$PSCommandPath`""
    ) + $args
    return
  }

  if ($needScoop) {
    Uninstall-Scoop -How $Mode -TryBruteForce:$BruteForce
  }

  if ($needChoco) {
    Uninstall-Chocolatey -How $Mode -TryBruteForce:$BruteForce `
      -RemovePackages:$UninstallChocolateyPackages
  }

  if ($VerifyAfterRemoval) {
    $r = Invoke-PkgMgrVerify -Which $Target
    Write-VerifyReport -Dir $ExportDir -Report $r -Name "verify-after-remove.json"

    $reboot = Should-RebootFromReport -Report $r -SvcStopFailures $svcStopFailures
    if ($reboot) {
      if ($Action -eq 'Cycle') {
        Save-ResumeState -NextAction "Install"
        Register-ResumeTask -ScriptPath $PSCommandPath `
          -Args ("-Action Install -Target $Target -ExportDir `"$ExportDir`" " +
                 "-Mode $Mode -Force")
      }
      Schedule-PowerAction -Why "PkgMgr cleanup: reboot suggested (locks/remnants)."
      return
    }

    if (-not $r.Ok) {
      Write-Log "ERROR" "Verification failed; see verify-after-remove.json."
      exit 2
    }
  }
}

if ($Action -in @('Install','Cycle')) {
  # Preflight: ensure clean (no lingering paths/env/PATH).
  $r0 = Invoke-PkgMgrVerify -Which $Target
  Write-VerifyReport -Dir $ExportDir -Report $r0 -Name "verify-pre-install.json"
  if (-not $r0.Ok) {
    throw ("Pre-install verification failed (remnants exist). " +
      "Fix or re-run with -Action Remove/-Mode ProperThenNuke.")
  }

  if ($Target -in @('Scoop','Both')) {
    Install-Scoop
  }

  if ($Target -in @('Chocolatey','Both')) {
    if (-not (Test-IsAdministrator) -and $AutoElevateForChocolatey) {
      if (-not $PSCommandPath) {
        throw "Chocolatey install needs elevation and requires a saved .ps1 file."
      }
      Write-Log "INFO" "Re-launching elevated for Chocolatey install..."
      Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
        "-NoProfile","-ExecutionPolicy","Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Action", "Install",
        "-Target", "Chocolatey",
        "-ExportDir", "`"$ExportDir`"",
        "-Mode", $Mode,
        "-Force"
      )
      return
    }
    Install-Chocolatey
  }

  if ($RepairWinGetOnInstall) {
    Repair-WinGet
  }

  $r1 = Invoke-PkgMgrVerify -Which $Target
  Write-VerifyReport -Dir $ExportDir -Report $r1 -Name "verify-post-install.json"
  Write-Log "INFO" "Install phase complete."
}

Write-Log "INFO" "Done."

