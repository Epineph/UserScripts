<#
.SYNOPSIS
    Grants full control permissions to a specified path.

.DESCRIPTION
    This script takes ownership and grants full control permissions for a specified path
    to the current user.

.PARAMETER Path
    The path to the directory or file where full control should be granted.

.EXAMPLE
    .\Grant-FullControl.ps1 -Path "C:\MyDirectory"
#>

param (
    [string]$Path
)

try {
    takeown /F $Path /R /D Y | Out-Null
    icacls $Path /grant "$($env:USERNAME):(OI)(CI)F" /T | Out-Null
    Write-Output "Successfully granted full control to $Path."
} catch {
    Write-Warning "Failed to grant full control to $Path: $($_.Exception.Message)"
}

