<#
.SYNOPSIS
    Finds and views a script from known directories.

.DESCRIPTION
    This script searches for a specified script name in known directories and displays it.

.PARAMETER ScriptName
    The name of the script to find and view.

.EXAMPLE
    .\View-Script.ps1 -ScriptName "myScript.ps1"
#>

param (
    [string]$ScriptName
)

$searchPaths = @(
    "$HOME\powershell_scripts",
    "C:\Users\heini\repos\vcpkg"
    # Add any other paths where you store scripts
)

foreach ($path in $searchPaths) {
    $fullPath = Join-Path -Path $path -ChildPath $ScriptName
    if (Test-Path -Path $fullPath) {
        bat $fullPath
        return
    }
}

Write-Warning "Script '$ScriptName' not found in specified search paths."

