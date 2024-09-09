<#
.SYNOPSIS
    Installs and imports useful PowerShell modules.

.DESCRIPTION
    This script installs and imports a list of useful PowerShell modules.

.EXAMPLE
    .\Install-AndImportModules.ps1
#>

$modules = @(
    "PSReadLine",
    "Az",
    "Microsoft.PowerShell.Utility",
    "Microsoft.PowerShell.Management",
    "Pester",
    "7Zip4Powershell",  # Provides access to 7zip functionality
    "Microsoft.PowerShell.Archive",  # Provides access to tar, zip, etc.
    "WindowsUpdateProvider"
)

foreach ($module in $modules) {
    try {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Install-Module -Name $module -Force -AllowClobber
        }
        Import-Module -Name $module
        Write-Output "Installed and imported $module successfully."
    } catch {
        $errorMsg = $_.Exception.Message
        Write-Warning "Failed to install or import $module: $errorMsg"
    }
}

