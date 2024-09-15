<#
.SYNOPSIS
    Performs system maintenance tasks and allows the user to list and install Windows capabilities.

.DESCRIPTION
    This script checks for pending Windows updates, repairs the Windows Component Store, cleans the Windows Update cache, and optimizes the system disk.
    It then lists all available Windows capabilities (excluding language and font-related ones) and allows the user to select and install them.
    After the installation, the script re-enables any temporarily disabled services.

.PARAMETER None
    This script does not take any parameters.

.EXAMPLE
    .\OptimizeAndInstallCapabilities.ps1
    Performs system maintenance tasks and then lists Windows capabilities for the user to choose and install.

.NOTES
    Author: Your Name
    Date: YYYY-MM-DD
    Version: 1.0
#>

# Function to check for pending Windows updates
function Check-PendingUpdates {
    Write-Host "Checking for pending Windows updates..."
    $updates = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0").Updates
    if ($updates.Count -gt 0) {
        Write-Host "There are pending updates. Installing them now..."
        Install-WindowsUpdate -AcceptAll -AutoReboot
    } else {
        Write-Host "No pending updates found."
    }
}

# Function to run DISM commands to check and repair Windows Component Store
function Repair-WindowsComponentStore {
    Write-Host "Checking and repairing the Windows Component Store..."
    DISM /Online /Cleanup-Image /ScanHealth
    DISM /Online /Cleanup-Image /CheckHealth
    DISM /Online /Cleanup-Image /RestoreHealth
}

# Function to clean up Windows Update cache
function Clean-WindowsUpdateCache {
    Write-Host "Cleaning up Windows Update cache..."
    Stop-Service -Name wuauserv -Force
    Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force
    Start-Service -Name wuauserv
    Write-Host "Windows Update cache cleaned."
}

# Function to optimize system disk (defrag for HDD, optimize for SSD)
function Optimize-SystemDisk {
    $drives = Get-Volume -DriveLetter C
    foreach ($drive in $drives) {
        if ($drive.DriveType -eq 'Fixed') {
            Write-Host "Optimizing disk $($drive.DriveLetter)..."
            Optimize-Volume -DriveLetter $drive.DriveLetter -ReTrim -Verbose
        }
    }
}

# Function to disable unnecessary services temporarily
function Disable-BackgroundServices {
    Write-Host "Disabling unnecessary background services..."
    Stop-Service -Name "BITS" -Force
    Stop-Service -Name "Superfetch" -Force
    Stop-Service -Name "WindowsSearch" -Force
    Write-Host "Background services disabled."
}

# Function to re-enable background services
function Enable-BackgroundServices {
    Write-Host "Re-enabling background services..."
    Start-Service -Name "BITS"
    Start-Service -Name "Superfetch"
    Start-Service -Name "WindowsSearch"
    Write-Host "Background services re-enabled."
}

# Function to list and install Windows capabilities
function List-AndInstallCapabilities {
    Write-Host "Listing all available Windows capabilities..."

    # Get all Windows capabilities, filter out those related to languages and fonts
    $capabilities = Get-WindowsCapability -Online | Where-Object {
        $_.Name -notmatch 'Language' -and $_.Name -notmatch 'Font'
    }

    # Enumerate and display the capabilities
    $capabilities | ForEach-Object { 
        $i = [array]::IndexOf($capabilities, $_) + 1
        Write-Host "$i. $($_.Name) - $($_.State)"
    }

    # Prompt user to select capabilities to install
    $selectedIndices = Read-Host "Enter the numbers of the capabilities you want to install, separated by commas"
    $selectedIndices = $selectedIndices -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }

    if ($selectedIndices.Count -gt 0) {
        foreach ($index in $selectedIndices) {
            $capability = $capabilities[$index - 1]
            if ($capability) {
                Write-Host "Installing $($capability.Name)..."
                Add-WindowsCapability -Online -Name $capability.Name
            } else {
                Write-Host "Invalid selection: $index"
            }
        }
    } else {
        Write-Host "No valid capabilities selected for installation."
    }
}

# Main script execution
function Main {
    # Check for pending Windows updates
    Check-PendingUpdates

    # Repair Windows Component Store
    Repair-WindowsComponentStore

    # Clean Windows Update cache
    Clean-WindowsUpdateCache

    # Optimize system disk
    Optimize-SystemDisk

    # Disable unnecessary background services before installing optional features
    Disable-BackgroundServices

    # List and install Windows capabilities
    List-AndInstallCapabilities

    # Re-enable background services after installation
    Enable-BackgroundServices
}

Main

