<#
.SYNOPSIS
    This script lists the top 40 installed programs by disk space usage and allows the user to remove selected programs.

.DESCRIPTION
    The script retrieves the list of installed programs on the system, ranks them by the amount of disk space they consume,
    and displays the top 40 programs. The user can input the numbers corresponding to the programs they want to remove.
    The script then calculates the total space that will be freed and prompts the user for confirmation before proceeding
    with the uninstallation.

.PARAMETER None
    The script does not take any parameters. It interacts with the user through prompts.

.EXAMPLE
    PS C:\> .\ListAndRemovePrograms.ps1
    1. Google Chrome - 2.34 GB
    2. Microsoft Office - 1.56 GB
    3. Adobe Reader - 1.23 GB
    ...
    Enter the program numbers to remove (e.g., 1,3,5-9): 1,3
    You are about to remove the following programs:
    - Google Chrome
    - Adobe Reader
    Total space to be freed: 3.57 GB
    Are you sure you want to proceed? (yes/no): yes

.NOTES
    The script uses the Win32_Product class, which may take some time to retrieve all installed programs on the system.
    Ensure that you run the script with administrative privileges.

#>

# Get the list of installed programs with their sizes
$programs = Get-WmiObject -Class Win32_Product | Select-Object Name, @{Name="SizeGB";Expression={[math]::Round($_.InstallSize / 1GB, 2)}} | Sort-Object -Property SizeGB -Descending

# Display the top 40 programs
$topPrograms = $programs | Select-Object -First 40
$topPrograms | ForEach-Object { $i = [array]::indexof($topPrograms, $_) + 1; Write-Output "$i. $($_.Name) - $($_.SizeGB) GB" }

# Ask the user to input the program numbers to remove
$removeList = Read-Host "Enter the program numbers to remove (e.g., 1,3,5-9)"

# Parse the input into an array of numbers
$indices = @()
$removeList -split ',' | ForEach-Object {
    if ($_ -match "-") {
        $range = $_ -split "-"
        $indices += $range[0]..$range[1]
    } else {
        $indices += $_
    }
}

# Calculate the total size to be removed
$totalSize = 0
$programsToRemove = @()
foreach ($index in $indices) {
    $program = $topPrograms[$index - 1]
    $totalSize += $program.SizeGB
    $programsToRemove += $program.Name
}

# Prompt the user for confirmation
Write-Host "You are about to remove the following programs:"
$programsToRemove | ForEach-Object { Write-Host "- $_" }
Write-Host "Total space to be freed: $totalSize GB"

$confirmation = Read-Host "Are you sure you want to proceed? (yes/no)"
if ($confirmation -eq "yes") {
    foreach ($program in $programsToRemove) {
        $product = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -eq $program }
        $product.Uninstall()
    }
    Write-Host "Selected programs have been removed."
} else {
    Write-Host "Operation cancelled."
}

