<#
.SYNOPSIS
    Sets up the PowerShell repository and installs required modules.

.DESCRIPTION
    This script registers the PowerShell Gallery if it's not already registered, and installs
    the PowerShellGet and NuGet providers if they are not already installed.

.EXAMPLE
    .\Setup-PowerShellRepositories.ps1
#>

try {
    if (-not (Get-PSRepository | Where-Object { $_.Name -eq "PSGallery" })) {
        Register-PSRepository -Name "PSGallery" -SourceLocation "https://www.powershellgallery.com/api/v2" -InstallationPolicy Trusted
    }

    if (-not (Get-Module -ListAvailable -Name PowerShellGet)) {
        Install-Module -Name PowerShellGet -Force -AllowClobber
    }

    if (-not (Get-PackageProvider -ListAvailable -Name NuGet)) {
        Install-PackageProvider -Name NuGet -Force -Verbose
        Install-Module -Name PackageManagement -Force
    }

    Import-Module -Name PowerShellGet
} catch {
    $errorMsg = $_.Exception.Message
    Write-Warning "Failed to set up repositories or install PowerShellGet/NuGet: $errorMsg"
}

