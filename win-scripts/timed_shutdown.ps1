<#
.SYNOPSIS
    Schedule a timed reboot or shutdown.

.DESCRIPTION
    This script lets you schedule a Windows reboot or shutdown either:
      • After a specified delay (in minutes), or
      • At a specified clock time (today or tomorrow if the time has already passed).

.PARAMETER Action
    The operation to perform. Accepted values are 'Reboot' or 'Shutdown'.

.PARAMETER DelayMinutes
    The delay, in minutes, before executing the action. Mutually exclusive with -Time.

.PARAMETER Time
    The clock time (in HH:mm or HH:mm:ss format) at which to perform the action.
    If the time has already passed today, it will schedule for the same time tomorrow.

.PARAMETER Force
    Switch. If provided, force-close running applications without warning.

.EXAMPLE
    .\Schedule-RebootShutdown.ps1 -Action Reboot -DelayMinutes 15
    Schedules a reboot in 15 minutes.

.EXAMPLE
    .\Schedule-RebootShutdown.ps1 -Action Shutdown -Time "23:30"
    Schedules a shutdown tonight at 11:30 PM (or tomorrow if already past 23:30).

.NOTES
    Tested on Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Reboot','Shutdown')]
    [string]$Action,

    [Parameter(Mandatory=$false, ParameterSetName='Delay')]
    [ValidateRange(1, 1440)]
    [int]$DelayMinutes,

    [Parameter(Mandatory=$false, ParameterSetName='AtTime')]
    [string]$Time,

    [switch]$Force
)

function Convert-ToSeconds {
    param([int]$minutes)
    return $minutes * 60
}

function Calculate-WaitSeconds {
    param([string]$targetTime)
    # Parse the target clock time
    try {
        $today = Get-Date
        $target = [DateTime]::ParseExact($targetTime, ('HH:mm','HH:mm:ss'), $null)
        # Ensure the date component is today
        $target = Get-Date -Hour $target.Hour -Minute $target.Minute -Second $target.Second
    } catch {
        Write-Error "Invalid time format. Use 'HH:mm' or 'HH:mm:ss'."
        exit 1
    }
    # If already past, schedule for tomorrow
    if ($target -le (Get-Date)) {
        $target = $target.AddDays(1)
    }
    return [math]::Round(($target - (Get-Date)).TotalSeconds)
}

# Determine shutdown parameters
$switch = if ($Action -eq 'Reboot') { '/r' } else { '/s' }
$forceSwitch = if ($Force) { '/f' } else { '' }

# Compute total wait seconds
if ($PSCmdlet.ParameterSetName -eq 'Delay') {
    if (-not $DelayMinutes) {
        Write-Error "-DelayMinutes is required when using the Delay parameter set."
        exit 1
    }
    $waitSeconds = Convert-ToSeconds -minutes $DelayMinutes
} elseif ($PSCmdlet.ParameterSetName -eq 'AtTime') {
    if (-not $Time) {
        Write-Error "-Time is required when using the AtTime parameter set."
        exit 1
    }
    $waitSeconds = Calculate-WaitSeconds -targetTime $Time
} else {
    Write-Error "You must specify either -DelayMinutes or -Time."
    exit 1
}

Write-Host "Scheduling $Action in $waitSeconds seconds..." -ForegroundColor Cyan

# Sleep until the scheduled time
Start-Sleep -Seconds $waitSeconds

# Execute the shutdown command
Write-Host "Executing $Action now." -ForegroundColor Green
& shutdown.exe $switch $forceSwitch /t 0

