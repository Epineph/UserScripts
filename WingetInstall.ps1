<#
.SYNOPSIS
    Helper script for searching and installing packages using Winget.

.DESCRIPTION
    This script allows users to search for packages using Winget and interactively select which packages to install based on search results.
    The results are displayed in a formatted table using `bat` for improved readability if installed.

.PARAMETER searchTerm
    The term to search for using Winget.

.PARAMETER logDir
    The directory where search results will be saved. Defaults to "$HOME\winget_logs".

.EXAMPLE
    .\WingetInstall.ps1 -searchTerm "nodejs"

    Searches for packages related to "nodejs" and allows the user to select and install the desired packages.

.EXAMPLE
    .\WingetInstall.ps1 -searchTerm "python" -logDir "C:\Users\heini\Documents\winget_logs"

    Searches for packages related to "python", saves the log in the specified directory, and allows the user to select and install the desired packages.

.NOTES
    This script assumes that `bat` is installed and available in the system PATH. If not installed, the script will display results using a standard PowerShell table format.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$searchTerm,

    [string]$logDir = "$HOME\winget_logs"
)

# Ensure the log directory exists
if (-not (Test-Path -Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

# Define the log file path
$logFilePath = Join-Path -Path $logDir -ChildPath "winget_search_results.csv"

# Run the winget search command and capture the output
$wingetResults = winget search $searchTerm

# Filter and format the output to capture only the relevant lines
$filteredResults = $wingetResults | Where-Object { $_ -match "^[^\s]+" }

# Parse the filtered output into a custom object for easier handling
$parsedResults = $filteredResults | ForEach-Object {
    $fields = $_ -split "\s{2,}"
    [PSCustomObject]@{
        Name    = $fields[0]
        Id      = $fields[1]
        Version = $fields[2]
        Match   = $fields[3]
        Source  = $fields[4]
    }
}

# Add an index column
$global:index = 1
$indexedResults = $parsedResults | ForEach-Object {
    $_ | Add-Member -MemberType NoteProperty -Name Index -Value $global:index
    $global:index++
    $_
}

# Save the results to a CSV file
$indexedResults | Export-Csv -Path $logFilePath -NoTypeInformation

# Check if bat is installed and available in PATH
$batInstalled = Get-Command "bat" -ErrorAction SilentlyContinue

if ($batInstalled) {
    # Display the results using bat
    bat --style=grid --color=always --paging=never $logFilePath
} else {
    # Fallback to displaying results in a PowerShell table if bat is not available
    Write-Host "Bat not found, displaying results in PowerShell table."
    $indexedResults | Format-Table -AutoSize
}

# Prompt user to input row numbers for installation
$selection = Read-Host "Enter the numbers of the packages you want to install, separated by commas (e.g., 2, 5, 7-10)"

# Parse the selection input
$selectedIndices = @()
$selection.Split(',') | ForEach-Object {
    if ($_ -match '-') {
        $range = $_ -split '-'
        $selectedIndices += ($range[0]..$range[1])
    } else {
        $selectedIndices += [int]$_
    }
}

# Filter selected packages
$packagesToInstall = $indexedResults | Where-Object { $selectedIndices -contains $_.Index } | Select-Object -ExpandProperty Id

# Install the selected packages
if ($packagesToInstall.Count -gt 0) {
    foreach ($package in $packagesToInstall) {
        winget install $package -e
    }
} else {
    Write-Host "No valid packages selected."
}
