<#
.SYNOPSIS
A script to perform application searches using Winget, enumerate results, and install applications by selection.

.DESCRIPTION
This script facilitates searching for applications using Windows Package Manager (winget), displaying the search results in an enumerated list, and allowing users to install selected applications by specifying their numbers. Users can also select multiple applications for batch installation.

.PARAMETER SearchTerm
Specifies the term to search for in the Winget repository. If not provided as an argument, the script prompts the user for input during execution.

.EXAMPLE
PS> .\WingetSearchInstaller.ps1 -SearchTerm "notepad"

Searches for applications related to "notepad," lists the results, and allows the user to install one or more selected applications.

.EXAMPLE
PS> .\WingetSearchInstaller.ps1

Prompts the user to input a search term, displays matching results, and allows selection for installation.

.EXAMPLE
PS> .\WingetSearchInstaller.ps1 -SearchTerm "python"

Searches for "python," enumerates matching applications, and enables the user to install them by selecting their numbers.

.NOTES
Author: Epineph
Date: 2024-12-27
Requirements:
  - Windows Package Manager (winget) must be installed and configured on the system.
  - Sufficient permissions to install applications.

.LIMITATIONS
  - Relies on the output format of `winget search`. Changes to this format may break the script.
  - Requires an active internet connection for Winget operations.

.TIPS
  - Use commas to specify multiple application numbers for batch installation, e.g., "1,2,3".
  - Ensure you run the script with appropriate privileges (e.g., as an administrator) to avoid installation failures.

#>

param (
    [string]$SearchTerm
)

function Show-Help {
    Get-Help -Name $MyInvocation.MyCommand.Name -Full
}

function Winget-SearchAndInstall {
    param (
        [string]$SearchTerm
    )

    if (-not $SearchTerm) {
        $SearchTerm = Read-Host "Enter the search term for Winget"
    }

    Write-Output "Searching for '$SearchTerm'..."

    # Perform the winget search and parse the results
    $searchResults = winget search $SearchTerm | Out-String

    if (-not $searchResults) {
        Write-Output "No results found for '$SearchTerm'."
        return
    }

    # Parse results and remove header lines
    $lines = $searchResults -split "`r?`n"
    $headerIndex = $lines | ForEach-Object { $_ -match "^Name\s+Id\s+Version" } | Where-Object { $_ } | Select-Object -First 1

    if (-not $headerIndex) {
        Write-Output "No valid entries found for '$SearchTerm'."
        return
    }

    $results = $lines | Select-Object -Skip ($lines.IndexOf($headerIndex) + 2) | Where-Object { $_ -match "\S" }

    if (-not $results) {
        Write-Output "No valid entries found for '$SearchTerm'."
        return
    }

    $results | ForEach-Object -Begin { $i = 0 } -Process {
        Write-Output "[$i] $_"
        $i++
    }

    $selectedIndexes = Read-Host "Enter the numbers of the applications to install (comma-separated, or 'q' to quit)"

    if ($selectedIndexes -eq 'q') {
        Write-Output "Exiting the script."
        return
    }

    $indexes = $selectedIndexes -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "^\d+$" }

    foreach ($index in $indexes) {
        if ($index -lt 0 -or $index -ge $results.Count) {
            Write-Output "Invalid selection: $index. Skipping."
            continue
        }

        $selectedApp = $results[$index]
        $appId = ($selectedApp -split "\s{2,}")[1]

        Write-Output "Installing '$appId'..."
        winget install --id $appId
    }
}

# Main script logic
if ($args -contains "-Help") {
    Show-Help
} else {
    Winget-SearchAndInstall -SearchTerm $SearchTerm
}
