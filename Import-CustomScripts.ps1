<#
.SYNOPSIS
    Imports all .ps1 scripts from a specified directory.

.DESCRIPTION
    This script imports all PowerShell scripts from a given directory.

.PARAMETER scriptDirectory
    The directory from which to import .ps1 scripts. Defaults to "$HOME\powershell_scripts".

.EXAMPLE
    .\Import-CustomScripts.ps1 -scriptDirectory "C:\Scripts"
#>

param (
    [string]$scriptDirectory = "$HOME\powershell_scripts"
)

if (Test-Path $scriptDirectory) {
    $scriptFiles = Get-ChildItem -Path $scriptDirectory -Filter *.ps1
    foreach ($script in $scriptFiles) {
        try {
            . $script.FullName
            Write-Output "Imported $($script.Name) successfully."
        } catch {
            $errorMsg = $_.Exception.Message
            Write-Warning "Failed to import $($script.Name): $errorMsg"
        }
    }
} else {
    Write-Warning "Directory $scriptDirectory does not exist."
}

