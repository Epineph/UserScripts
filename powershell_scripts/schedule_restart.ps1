<#
.SYNOPSIS
    Schedule a shutdown or restart on Windows based on a specified time in seconds or minutes.

.DESCRIPTION
    This script allows you to schedule a shutdown or restart after a given time in seconds or minutes.

.PARAMETER Time
    The time value to wait before shutdown or restart (in seconds or minutes).

.PARAMETER Unit
    The unit of time, either 'seconds' or 'minutes'.

.PARAMETER Restart
    A switch to indicate if the operation should be a restart instead of a shutdown.

.EXAMPLE
    .\Schedule-Shutdown.ps1 -Time 5 -Unit minutes

.EXAMPLE
    .\Schedule-Shutdown.ps1 -Time 300 -Unit seconds -Restart
#>

param (
    [Parameter(Mandatory = $true)]
    [float]$Time,

    [Parameter(Mandatory = $true)]
    [ValidateSet("seconds", "minutes")]
    [string]$Unit,

    [switch]$Restart
)

function Schedule-Shutdown {
    param (
        [int]$TimeInSeconds,
        [switch]$Restart
    )
    # Determine the shutdown or restart command
    $action = if ($Restart) { "/r" } else { "/s" }
    $command = "shutdown $action /t $TimeInSeconds"

    # Confirm and execute
    Write-Host "Executing command: $command"
    Invoke-Expression $command
}

# Convert time to seconds if necessary
if ($Unit -eq "minutes") {
    $TimeInSeconds = [math]::Round($Time * 60)
} else {
    $TimeInSeconds = [math]::Round($Time)
}

# Confirm with the user
Write-Host "Scheduling a $([if ($Restart) { 'restart' } else { 'shutdown' }]) in $TimeInSeconds seconds."
Schedule-Shutdown -TimeInSeconds $TimeInSeconds -Restart:$Restart
