<#
.SYNOPSIS
A script to perform application searches using Winget, enumerate results, and install applications by selection.

.DESCRIPTION
This script allows the user to search for applications using Winget, displays the results with an enumeration, and
installs the selected application based on the user's choice. The script is interactive and helps streamline the process
of finding and installing applications from the Winget repository.

.PARAMETER SearchTerm
The term to search for in the Winget repository. The script uses this term to find matching applications.

.EXAMPLE
PS> .\WingetSearchInstaller.ps1 -SearchTerm "notepad"

Searches for applications related to "notepad," lists the results, and allows the user to install one of the matches.

.EXAMPLE
PS> .\WingetSearchInstaller.ps1

Prompts the user to input a search term, displays matching results, and allows selection for installation.

.NOTES
Author: Epineph
Date: 2024-12-27
Requires: Windows Package Manager (winget)
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

    # Split the search results into lines
    $lines = $searchResults -split "`r?`n"

    # Locate the header line (the one that starts with "Name" and contains other headers like "Id")
    $headerIndex = $lines | ForEach-Object { $_ } | Select-String -Pattern "^\s*Name\s+Id\s+Version" | Select-Object -First 1

    if (-not $headerIndex) {
        Write-Output "No valid entries found for '$SearchTerm'."
        return
    }

    # Get the actual index of the header in the array
    $headerIndexPosition = $lines.IndexOf($headerIndex.Line)

    # Skip header and separator line, and process remaining lines
    $results = $lines[($headerIndexPosition + 2)..($lines.Length - 1)] | Where-Object { $_ -match "\S" }

    if (-not $results) {
        Write-Output "No valid entries found for '$SearchTerm'."
        return
    }

    $results | ForEach-Object -Begin { $i = 0 } -Process {
        Write-Output "[$i] $_"
        $i++
    }

    $selectedIndexes = Read-Host "Enter the numbers of the applications to install (comma-separated, space-separated, ranges like 1-3, or 'q' to quit)"

    if ($selectedIndexes -eq 'q') {
        Write-Output "Exiting the script."
        return
    }

    # Parse the input to handle commas, spaces, and ranges
    $indexes = @()
    $selectedIndexes -split "[ ,]+" | ForEach-Object {
        if ($_ -match "^(\d+)-(\d+)$") {
            $indexes += ($matches[1]..$matches[2])
        } elseif ($_ -match "^\d+$") {
            $indexes += [int]$_
        }
    }

    $indexes = $indexes | Sort-Object -Unique

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
