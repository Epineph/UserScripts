#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fully resets Windows Update caches and related state (safe rename strategy).

.DESCRIPTION
  This script attempts a clean Windows Update reset by:
    - Stopping update/orchestration services and related processes
    - Clearing BITS queue (best-effort)
    - Renaming cache directories:
        %windir%\SoftwareDistribution
        %windir%\System32\catroot2
    - Optionally clearing Delivery Optimization cache (cmdlet if available)
    - Restoring original service start modes
    - Optionally triggering a new scan, DISM, and SFC

  The script escalates automatically if wuauserv refuses to stop, unless
  -NoAggressive is provided.

.NOTES
  Run in an elevated PowerShell.

.PARAMETER StopTimeoutSec
  Seconds to wait for services to stop (per service) before escalating.

.PARAMETER NoAggressive
  Do not temporarily disable UsoSvc/WaaSMedicSvc if wuauserv refuses to stop.

.PARAMETER SkipScan
  Do not trigger a post-reset scan.

.PARAMETER ClearDeliveryOptimization
  Attempt to clear Delivery Optimization cache using
  Delete-DeliveryOptimizationCache if available (best-effort).

.PARAMETER PurgeRenamedCaches
  Delete any *.old_* caches created by this script (only after a successful run).

.PARAMETER RunDism
  Run DISM /RestoreHealth after resetting caches.

.PARAMETER RunSfc
  Run SFC /scannow after resetting caches.

.PARAMETER LogPath
  If set, starts a transcript at this path.

.EXAMPLE
  .\Reset-WindowsUpdate.ps1

.EXAMPLE
  .\Reset-WindowsUpdate.ps1 -RunDism -RunSfc -ClearDeliveryOptimization -Verbose
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidateRange(5, 600)]
  [int]$StopTimeoutSec = 45,

  [switch]$NoAggressive,

  [switch]$SkipScan,

  [switch]$ClearDeliveryOptimization,

  [switch]$PurgeRenamedCaches,

  [switch]$RunDism,

  [switch]$RunSfc,

  [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in an elevated PowerShell (Administrator)."
  }
}

function Write-Info([string]$Msg) {
  Write-Host ("[INFO]  {0}" -f $Msg)
}

function Write-Warn([string]$Msg) {
  Write-Warning $Msg
}

function Get-ServiceIfExists([string]$Name) {
  Get-Service -Name $Name -ErrorAction SilentlyContinue
}

function Get-ServiceCim([string]$Name) {
  Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name) `
    -ErrorAction SilentlyContinue
}

function Stop-ServiceWithTimeout {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][int]$TimeoutSec
  )

  $svc = Get-ServiceIfExists $Name
  if ($null -eq $svc) { return }

  if ($svc.Status -eq "Stopped") { return }

  Write-Verbose ("Stopping service: {0}" -f $Name)
  try {
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
  } catch { }

  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $svc = Get-ServiceIfExists $Name
    if ($null -eq $svc -or $svc.Status -eq "Stopped") { return }
    Start-Sleep -Milliseconds 500
  }

  throw ("Timeout stopping service '{0}' after {1}s." -f $Name, $TimeoutSec)
}

function Try-Stop-ServiceNoThrow {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][int]$TimeoutSec
  )
  try { Stop-ServiceWithTimeout -Name $Name -TimeoutSec $TimeoutSec }
  catch { Write-Verbose $_.Exception.Message }
}

function Try-Kill-Process([string[]]$Names) {
  foreach ($n in $Names) {
    try {
      Get-Process -Name $n -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    } catch { }
  }
}

function Get-ServiceStartState {
  param([Parameter(Mandatory = $true)][string]$Name)

  $cim = Get-ServiceCim $Name
  if ($null -eq $cim) { return $null }

  # StartMode: "Auto", "Manual", "Disabled"
  # DelayedAutoStart: bool (may be null on some systems)
  [pscustomobject]@{
    Name            = $Name
    StartMode       = $cim.StartMode
    DelayedAuto     = [bool]($cim.DelayedAutoStart -as [bool])
  }
}

function Set-ServiceStartState {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$StartMode,
    [Parameter(Mandatory = $true)][bool]$DelayedAuto
  )

  $svc = Get-ServiceIfExists $Name
  if ($null -eq $svc) { return }

  $mode = $StartMode.ToLowerInvariant()

  # sc.exe expects a space after "start="; do not remove it.
  switch ($mode) {
    "disabled" {
      sc.exe config $Name start= disabled | Out-Null
    }
    "manual" {
      sc.exe config $Name start= demand | Out-Null
    }
    "auto" {
      if ($DelayedAuto) {
        # Not all Windows versions accept delayed-auto for all services.
        # Best-effort: attempt delayed-auto; fall back to auto.
        try {
          sc.exe config $Name start= delayed-auto | Out-Null
        } catch {
          sc.exe config $Name start= auto | Out-Null
        }
      } else {
        sc.exe config $Name start= auto | Out-Null
      }
    }
    default {
      # Conservative fallback.
      sc.exe config $Name start= demand | Out-Null
    }
  }
}

function Rename-DirSafely {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Suffix
  )

  if (-not (Test-Path -LiteralPath $Path)) { return $null }

  $parent = Split-Path -Parent $Path
  $leaf   = Split-Path -Leaf $Path

  $target = Join-Path $parent ("{0}.old_{1}" -f $leaf, $Suffix)

  if (Test-Path -LiteralPath $target) {
    $rand = Get-Random -Minimum 1000 -Maximum 9999
    $target = Join-Path $parent ("{0}.old_{1}_{2}" -f $leaf, $Suffix, $rand)
  }

  if ($PSCmdlet.ShouldProcess($Path, ("Rename to '{0}'" -f $target))) {
    Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $target) -Force
    return $target
  }

  return $null
}

function Clear-BitsQueue {
  # Best-effort; may fail if BITS cmdlets are unavailable.
  try {
    Get-BitsTransfer -AllUsers -ErrorAction Stop |
      Remove-BitsTransfer -Confirm:$false -ErrorAction SilentlyContinue
  } catch { }

  try {
    Remove-Item -Path "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader\qmgr*.dat" `
      -Force -ErrorAction SilentlyContinue
  } catch { }
}

function Trigger-UpdateScan {
  # Best-effort. UsoClient exists on Win10/11; may behave differently.
  $uso = Join-Path $env:SystemRoot "System32\UsoClient.exe"
  if (Test-Path -LiteralPath $uso) {
    try {
      Start-Process -FilePath $uso -ArgumentList "StartScan" -WindowStyle Hidden
      return
    } catch { }
  }

  # Legacy fallback (often a no-op on modern Windows, but harmless).
  $wuauclt = Join-Path $env:SystemRoot "System32\wuauclt.exe"
  if (Test-Path -LiteralPath $wuauclt) {
    try {
      Start-Process -FilePath $wuauclt -ArgumentList "/detectnow" -WindowStyle Hidden
      Start-Process -FilePath $wuauclt -ArgumentList "/reportnow" -WindowStyle Hidden
    } catch { }
  }
}

function Purge-OldCaches {
  param([string]$Root)

  if (-not (Test-Path -LiteralPath $Root)) { return }

  Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '\.old_\d{8}_\d{6}(_\d{4})?$' } |
    ForEach-Object {
      if ($PSCmdlet.ShouldProcess($_.FullName, "Remove directory recursively")) {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

Assert-Admin

if ($LogPath) {
  try { Start-Transcript -Path $LogPath -Append | Out-Null } catch { }
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Services relevant to update reset. Some may not exist on all SKUs.
$svcCore = @(
  "WaaSMedicSvc",     # Windows Update Medic
  "UsoSvc",           # Update Orchestrator
  "DoSvc",            # Delivery Optimization
  "wuauserv",         # Windows Update
  "bits",             # BITS
  "cryptsvc",         # Cryptographic Services
  "msiserver",        # Windows Installer
  "TrustedInstaller"  # Windows Modules Installer
)

# Processes that commonly pin update state.
$procPin = @(
  "MoUsoCoreWorker",
  "USOClient",
  "WaaSMedicAgent",
  "TiWorker",
  "TrustedInstaller",
  "wuauclt"
)

# Capture original start states for services we might toggle.
$origStart = @{}
foreach ($s in @("UsoSvc", "WaaSMedicSvc")) {
  $st = Get-ServiceStartState $s
  if ($null -ne $st) { $origStart[$s] = $st }
}

$renamed = @()

try {
  Write-Info "Stopping update-related processes (best-effort)."
  Try-Kill-Process -Names $procPin

  Write-Info "Attempting to stop update-related services (best-effort)."
  foreach ($s in $svcCore) {
    Try-Stop-ServiceNoThrow -Name $s -TimeoutSec $StopTimeoutSec
  }

  $wu = Get-ServiceIfExists "wuauserv"
  if ($null -ne $wu -and $wu.Status -ne "Stopped") {
    if ($NoAggressive) {
      throw "wuauserv refused to stop. Re-run without -NoAggressive to escalate."
    }

    Write-Warn "wuauserv is still running; escalating (temporary disable of UsoSvc/WaaSMedicSvc)."

    foreach ($s in @("UsoSvc", "WaaSMedicSvc")) {
      $svc = Get-ServiceIfExists $s
      if ($null -ne $svc) {
        try { sc.exe config $s start= disabled | Out-Null } catch { }
        try { sc.exe stop   $s | Out-Null } catch { }
      }
    }

    # Re-kill pinned processes and re-stop services.
    Try-Kill-Process -Names $procPin
    foreach ($s in $svcCore) {
      Try-Stop-ServiceNoThrow -Name $s -TimeoutSec $StopTimeoutSec
    }

    $wu = Get-ServiceIfExists "wuauserv"
    if ($null -ne $wu -and $wu.Status -ne "Stopped") {
      throw "wuauserv still refused to stop after escalation."
    }
  }

  Write-Info "Clearing BITS queue (best-effort)."
  Clear-BitsQueue

  Write-Info "Renaming Windows Update caches (safe strategy; creates *.old_* backups)."
  $sd = Rename-DirSafely -Path (Join-Path $env:SystemRoot "SoftwareDistribution") -Suffix $stamp
  if ($sd) { $renamed += $sd }

  $cr = Rename-DirSafely -Path (Join-Path $env:SystemRoot "System32\catroot2") -Suffix $stamp
  if ($cr) { $renamed += $cr }

  if ($ClearDeliveryOptimization) {
    Write-Info "Clearing Delivery Optimization cache (best-effort)."
    $doCmd = Get-Command -Name "Delete-DeliveryOptimizationCache" `
      -ErrorAction SilentlyContinue
    if ($null -ne $doCmd) {
      try {
        if ($PSCmdlet.ShouldProcess("DeliveryOptimizationCache", "Delete")) {
          Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
        }
      } catch { }
    } else {
      Write-Warn "Delete-DeliveryOptimizationCache not available; skipping."
    }
  }

  Write-Info "Restoring service start modes (if modified) and starting core services."
  foreach ($k in $origStart.Keys) {
    $st = $origStart[$k]
    Set-ServiceStartState -Name $st.Name -StartMode $st.StartMode -DelayedAuto $st.DelayedAuto
  }

  # Start services in a sane order (best-effort).
  foreach ($s in @("cryptsvc", "bits", "wuauserv", "UsoSvc")) {
    try { Start-Service -Name $s -ErrorAction SilentlyContinue } catch { }
  }

  if (-not $SkipScan) {
    Write-Info "Triggering a Windows Update scan (best-effort)."
    Trigger-UpdateScan
  }

  if ($RunDism) {
    Write-Info "Running DISM /RestoreHealth."
    if ($PSCmdlet.ShouldProcess("DISM", "RestoreHealth")) {
      & dism.exe /Online /Cleanup-Image /RestoreHealth
    }
  }

  if ($RunSfc) {
    Write-Info "Running SFC /scannow."
    if ($PSCmdlet.ShouldProcess("SFC", "ScanNow")) {
      & sfc.exe /scannow
    }
  }

  if ($PurgeRenamedCaches) {
    Write-Info "Purging renamed cache directories created by this script."
    Purge-OldCaches -Root $env:SystemRoot
    Purge-OldCaches -Root (Join-Path $env:SystemRoot "System32")
  }

  Write-Info "Done."
  if ($renamed.Count -gt 0) {
    Write-Info ("Renamed caches: {0}" -f ($renamed -join "; "))
  }
}
finally {
  # Always attempt to restore original start modes (best-effort).
  foreach ($k in $origStart.Keys) {
    $st = $origStart[$k]
    try {
      Set-ServiceStartState -Name $st.Name -StartMode $st.StartMode `
        -DelayedAuto $st.DelayedAuto
    } catch { }
  }

  if ($LogPath) {
    try { Stop-Transcript | Out-Null } catch { }
  }
}
