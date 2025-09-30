#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
  Schedule a restart or shutdown after a delay OR after cumulative disk writes reach a target size.

.DESCRIPTION
  You can trigger on time (e.g., 45m, 2h, 90s) or on disk-write size (e.g., 50GB, 12MiB, 800000B).
  When the trigger condition is met, a 30-second alert is shown (sound + top-most message box),
  then the requested action (shutdown or restart) is executed via shutdown.exe.

.PARAMETER Shutdown
  Perform system shutdown when trigger fires.

.PARAMETER Restart
  Perform system restart when trigger fires.

.PARAMETER AfterTime
  Human time: integer with unit [s|m|h|d], e.g. "45m", "2h", "90s", "1d".

.PARAMETER AfterSize
  Cumulative disk writes (system-wide) to wait for, with size unit:
  Decimal (10^3):  B, KB, MB, GB
  Binary  (2^10):  KiB, MiB, GiB
  Examples: "50GB", "12MiB", "800000B".
  Uses \PhysicalDisk(_Total)\Disk Write Bytes/sec integrated over time.

.PARAMETER WarningSeconds
  Seconds of advance warning before action (default: 30).

.PARAMETER PollSeconds
  Sampling period for counters (default: 1s).

.PARAMETER WhatIf
  Simulate and print decisions without executing shutdown/restart.

.PARAMETER GetHelp
  Print inline help.

.EXAMPLES
  # Restart in 45 minutes
  .\schedule-shutdown.ps1 --restart --after-time 45m

  # Shutdown after 50 GiB of cumulative disk writes since script start
  .\schedule-shutdown.ps1 --shutdown --after-size 50GiB

  # Whichever happens first: 2 hours OR 200 GB of writes
  .\schedule-shutdown.ps1 --shutdown --after-time 2h --after-size 200GB

  # Simulate behavior only (no action)
  .\schedule-shutdown.ps1 --restart --after-time 30s -WhatIf
#>

param(
  [Alias('s')] [switch] $Shutdown,
  [Alias('r')] [switch] $Restart,
  [Parameter()] [Alias('t','after-time')] [string] $AfterTime,
  [Parameter()] [Alias('z','after-size')] [string] $AfterSize,
  [int] $WarningSeconds = 30,
  [double] $PollSeconds = 1.0,
  [switch] $WhatIf,
  [Alias('h','?','help')] [switch] $GetHelp
)

# -------------------------- Help block (here-string) --------------------------
if ($GetHelp) {
  @"
USAGE
  schedule-shutdown.ps1 -Shutdown|-Restart [-AfterTime <Ns|Nm|Nh|Nd>] [-AfterSize <N(B|KB|MB|GB|KiB|MiB|GiB)>] [-WarningSeconds 30] [-PollSeconds 1] [-WhatIf]

NOTES
- Provide at least one trigger: -AfterTime or -AfterSize (or both; earliest wins).
- Size units:
    Decimal 10^3: KB=1,000  MB=1,000,000  GB=1,000,000,000
    Binary  2^10: KiB=1,024 MiB=1,048,576 GiB=1,073,741,824
- Disk writes measured system-wide via \PhysicalDisk(_Total)\Disk Write Bytes/sec.

EXAMPLES
  .\schedule-shutdown.ps1 -Restart -AfterTime 45m
  .\schedule-shutdown.ps1 -Shutdown -AfterSize 50GiB
  .\schedule-shutdown.ps1 -Shutdown -AfterTime 2h -AfterSize 200GB
  .\schedule-shutdown.ps1 -Restart -AfterTime 30s -WhatIf
"@ | Write-Host
  exit 0
}

# -------------------------- Validation --------------------------
$hasShutdown = $PSBoundParameters.ContainsKey('Shutdown')
$hasRestart  = $PSBoundParameters.ContainsKey('Restart')
if (-not ($hasShutdown -xor $hasRestart)) {
  throw "You must specify exactly one of -Shutdown or -Restart."
}

if (-not $AfterTime -and -not $AfterSize) {
  throw "Provide at least one trigger: --after-time or --after-size."
}
if ($WarningSeconds -lt 0) { throw "WarningSeconds must be >= 0." }
if ($PollSeconds -le 0)    { throw "PollSeconds must be > 0." }

# -------------------------- Unit parsers --------------------------
function Parse-TimeSpec {
  param([string] $Spec)
  if (-not $Spec) { return $null }
  if ($Spec -notmatch '^\s*(\d+(?:\.\d+)?)\s*([smhdSMHD])\s*$') {
    throw "Invalid time spec '$Spec'. Use e.g. 90s, 45m, 2h, 1d."
  }
  $val = [double]$matches[1]
  switch ($matches[2].ToLower()) {
    's' { return [timespan]::FromSeconds($val) }
    'm' { return [timespan]::FromMinutes($val) }
    'h' { return [timespan]::FromHours($val) }
    'd' { return [timespan]::FromDays($val) }
  }
}

$DEC = @{
  'B'  =   1
  'KB' = 1e3
  'MB' = 1e6
  'GB' = 1e9
}
$BIN = @{
  'KIB' = [math]::Pow(2,10)
  'MIB' = [math]::Pow(2,20)
  'GIB' = [math]::Pow(2,30)
}

function Parse-SizeSpec {
  param([string] $Spec)
  if (-not $Spec) { return $null }
  if ($Spec -notmatch '^\s*(\d+)\s*([A-Za-z]+)\s*$') {
    throw "Invalid size spec '$Spec'. Use e.g. 50GB, 12MiB, 800000B."
  }
  $n = [int64]$matches[1]
  $u = $matches[2].ToUpper()
  if ($DEC.ContainsKey($u)) { return [int64]($n * $DEC[$u]) }
  if ($BIN.ContainsKey($u)) { return [int64]($n * $BIN[$u]) }
  throw "Unknown unit '$u'. Valid: B, KB, MB, GB, KiB, MiB, GiB."
}

$timeSpan = Parse-TimeSpec $AfterTime
$sizeBytes = Parse-SizeSpec $AfterSize

# -------------------------- Alert helpers --------------------------
Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing        | Out-Null

function Show-TopMostAlert {
  param(
    [string] $Title,
    [string] $Message
  )
  try {
    $hostForm = New-Object System.Windows.Forms.Form
    $hostForm.StartPosition = 'CenterScreen'
    $hostForm.TopMost = $true
    $hostForm.ShowInTaskbar = $false
    $hostForm.Size = New-Object System.Drawing.Size(0,0)
    $hostForm.Show()
    [System.Windows.Forms.SystemSounds]::Exclamation.Play()
    [void][System.Windows.Forms.MessageBox]::Show($hostForm, $Message, $Title,
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning)
    $hostForm.Close()
    $hostForm.Dispose()
  } catch {
    # Fallback: console bell + write host
    1..3 | ForEach-Object { Write-Host "`a"; Start-Sleep -Milliseconds 250 }
    Write-Warning "$Title - $Message"
  }
}

# -------------------------- Trigger evaluation --------------------------
$deadline = $null
if ($timeSpan) { $deadline = (Get-Date).Add($timeSpan) }

# Prepare counter if size-trigger is requested
$needSize = $sizeBytes -ne $null
$counterPath = '\PhysicalDisk(_Total)\Disk Write Bytes/sec'
$accum = [int64]0
$lastSample = $null

Write-Host "[*] Action:      " ($Shutdown ? 'Shutdown' : 'Restart')
if ($deadline)  { Write-Host "[*] Time target: " $deadline.ToString('yyyy-MM-dd HH:mm:ss') }
if ($needSize)  { Write-Host "[*] Size target: " ("{0:N0} bytes" -f $sizeBytes) }
Write-Host "[*] Warning:     " "$WarningSeconds seconds prior to action"
Write-Host "[*] Poll every:  " "$PollSeconds s"

# Loop until earliest trigger fires
$warned = $false
while ($true) {
  $now = Get-Date

  $timeDue = $false
  if ($deadline) {
    $remaining = $deadline - $now
    if ($remaining.TotalSeconds -le $WarningSeconds -and -not $warned) {
      $warned = $true
      $msg = if ($Shutdown) { "System will SHUT DOWN in $WarningSeconds seconds." } else { "System will RESTART in $WarningSeconds seconds." }
      Show-TopMostAlert -Title "Impending action" -Message $msg
      if ($WhatIf) { Write-Host "[WhatIf] Would wait $WarningSeconds s then execute action."; break }
      Start-Sleep -Seconds $WarningSeconds
      $timeDue = $true
    } elseif ($remaining.TotalSeconds -le 0) {
      $timeDue = $true
    }
  }

  $sizeDue = $false
  if ($needSize) {
    try {
      $val = (Get-Counter $counterPath -ErrorAction Stop).CounterSamples[0].CookedValue
    } catch {
      throw "Failed to read performance counter $counterPath. Try running PowerShell as admin."
    }
    # Integrate bytes/sec over PollSeconds
    $delta = [int64]([double]$val * $PollSeconds)
    $accum += $delta
    if ($accum -ge $sizeBytes -and -not $warned) {
      $warned = $true
      $msg = if ($Shutdown) { "Disk-write target reached. System will SHUT DOWN in $WarningSeconds seconds." } else { "Disk-write target reached. System will RESTART in $WarningSeconds seconds." }
      Show-TopMostAlert -Title "Impending action" -Message $msg
      if ($WhatIf) {
        Write-Host "[WhatIf] Would wait $WarningSeconds s then execute action. (Accumulated: $accum bytes)"
        break
      }
      Start-Sleep -Seconds $WarningSeconds
      $sizeDue = $true
    }
  }

  if ($timeDue -or $sizeDue) { break }
  Start-Sleep -Seconds $PollSeconds
}

# -------------------------- Execute action --------------------------
if ($WhatIf) { Write-Host "[WhatIf] Done. No action executed."; exit 0 }

if ($Shutdown) {
  Write-Host "[*] Executing shutdown..."
  Start-Process -FilePath shutdown.exe -ArgumentList '/s','/t','0' -WindowStyle Hidden
} else {
  Write-Host "[*] Executing restart..."
  Start-Process -FilePath shutdown.exe -ArgumentList '/r','/t','0' -WindowStyle Hidden
}
