<#
.SYNOPSIS
    Installs a package using winget and adds its installation path to the PATH environment variable.

.DESCRIPTION
    This script allows you to search for a package using winget, select the correct package, and install it.
    After installation, the script locates the installation directory and adds it to the PATH environment variable.

.PARAMETER PackageName
    The name or ID of the package you wish to install using winget.

.EXAMPLE
    .\InstallAndAddToPath.ps1 -PackageName "Node.js"
    Installs Node.js using winget and adds its installation directory to the PATH environment variable.

.EXAMPLE
    .\InstallAndAddToPath.ps1 -PackageName "git"
    Searches for "git" using winget, prompts the user to select the correct package, installs it, and adds its installation directory to PATH.

.NOTES
    Author: Your Name
    Date: YYYY-MM-DD
    Version: 1.0
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, Position=0)]
    [string]$PackageName
)

function Install-AndAddToPath {
    param (
        [string]$wingetId
    )

    # Install the package using winget
    winget install --id $wingetId --silent --accept-package-agreements --accept-source-agreements

    # Wait for the installation to complete
    Start-Sleep -Seconds 10

    # Find the installation path (example for common install locations)
    $installPath = Get-ChildItem "C:\Program Files", "C:\Program Files (x86)", "$HOME\AppData\Local\Programs" -Recurse -Directory | 
                   Where-Object { $_.Name -like "*$wingetId*" } | 
                   Select-Object -First 1 -ExpandProperty FullName

    if ($installPath) {
        # Add the install path to PATH
        $currentPath = [System.Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::User)
        if ($currentPath -notcontains $installPath) {
            [System.Environment]::SetEnvironmentVariable('Path', "$currentPath;$installPath", [System.EnvironmentVariableTarget]::User)
            Write-Host "Added $installPath to PATH."
        } else {
            Write-Host "$installPath is already in PATH."
        }
    } else {
        Write-Host "Installation path not found for $wingetId."
    }
}

function Search-AndInstallPackage {
    param (
        [string]$packageName
    )

    # Search for the package using winget
    $searchResults = winget search $packageName | Select-Object -Skip 1 | ConvertFrom-Csv

    if ($searchResults.Count -eq 0) {
        Write-Host "No packages found for '$packageName'."
        return
    }

    # Display search results and prompt user for selection
    $searchResults | Format-Table -Property Id, Name, Source

    $selectedPackage = Read-Host "Enter the ID of the package you want to install"

    if ($selectedPackage -and ($searchResults.Id -contains $selectedPackage)) {
        Install-AndAddToPath -wingetId $selectedPackage
    } else {
        Write-Host "Invalid selection. Exiting."
    }
}

# Main script execution
Search-AndInstallPackage -packageName $PackageName

