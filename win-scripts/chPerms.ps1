<#
.SYNOPSIS
    Modifies permissions and/or ownership of files and directories.
.DESCRIPTION
    Uses icacls and takeown to modify permissions and ownership recursively if specified.
.PARAMETER Path
    Target directory path (mandatory, alias: -D)
.PARAMETER Permissions
    Permissions to set (alias: -P)
.PARAMETER Ownership
    Take ownership (alias: -O)
.PARAMETER Recursive
    Apply changes recursively (alias: -R)
.EXAMPLE
    .\Set-Permissions.ps1 -Path "C:\Target" -Permissions "F" -Recursive
    Grants Full Control permissions recursively (verbose output)
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [Alias("D")]
    [string]$Path,

    [Alias("P")]
    [string]$Permissions,

    [Alias("O")]
    [switch]$Ownership,

    [Alias("R")]
    [switch]$Recursive
)

begin {
    # Validate path exists
    if (-not (Test-Path -Path $Path)) {
        Write-Error "Path '$Path' does not exist"
        exit 1
    }

    # Get current user for permissions
    $currentUser = whoami
}

process {
    try {
        # Take ownership if requested
        if ($Ownership) {
            Write-Host "Taking ownership of $Path..."
            $takeownArgs = "/F `"$Path`""
            if ($Recursive) { $takeownArgs += " /R" }
            $takeownArgs += " /A /D Y"
            
            Start-Process "takeown.exe" -ArgumentList $takeownArgs -Wait -NoNewWindow
        }

        # Set permissions if requested
        if ($Permissions) {
            Write-Host "Setting permissions on $Path..."
            $icaclsArgs = "`"$Path`" /grant `"$($currentUser):(OI)(CI)$Permissions`""
            if ($Recursive) { $icaclsArgs += " /T" }
            $icaclsArgs += " /C"  # Removed /Q for verbose output
            
            Start-Process "icacls.exe" -ArgumentList $icaclsArgs -Wait -NoNewWindow
        }

        Write-Host "Operation completed successfully." -ForegroundColor Green
    }
    catch {
        Write-Error "An error occurred: $_"
        exit 1
    }
}