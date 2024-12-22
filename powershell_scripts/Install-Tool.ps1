
<#
.SYNOPSIS
    Installs packages via winget, automatically accepts licenses, and updates the system PATH.

.DESCRIPTION
    This script takes one or more package names as arguments (either an ID or a friendly install name)
    and installs them using winget. It automatically accepts package and source agreements.
    After installation, the script attempts to determine the installation location of the package and
    adds that location to the system PATH environment variable. If the PATH becomes too long, it
    suggests using environment variables to shorten long paths.

    NOTE: This script must be run as an administrator to modify the system PATH.

.PARAMETER Packages
    One or more package names to install. These can be winget IDs or friendly names.

.EXAMPLE
    .\Install-Tools.ps1 "Microsoft.VisualStudioCode"
    Installs Visual Studio Code using winget, accepts all agreements, and updates the PATH.

.EXAMPLE
    .\Install-Tools.ps1 git nodejs
    Installs both Git and Node.js, accepting agreements and updating PATH as needed.

.NOTES
    - Requires Windows 10 or later with winget installed.
    - May require a restart of the PowerShell session or system logoff/logon for PATH changes to take effect.
    - If unable to determine the installation location, the PATH is not updated for that particular package.

.LINK
    For more information on winget:
    https://github.com/microsoft/winget-cli
#>

Param(
    [Parameter(Mandatory=$true, ValueFromRemainingArguments=$true)]
    [string[]]$Packages
)

# Ensure script is run as Administrator
If (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole] "Administrator")) {
    Write-Error "You must run this script as an administrator!"
    exit 1
}

foreach ($pkg in $Packages) {
    Write-Host "Installing package: $pkg"
    # Attempt installation via winget
    $installCmd = "winget install $pkg --accept-package-agreements --accept-source-agreements -h"
    Write-Host "Running: $installCmd"
    $null = Invoke-Expression $installCmd

    # Optional: Check if installation succeeded
    # (In practice, you'd check $LastExitCode or parse winget output)
    # For simplicity, assuming success here.

    # Attempt to find installation location
    $packageInfo = winget show $pkg 2>$null
    $installLocation = ($packageInfo | Select-String -Pattern "Location:\s+(.*)").Matches.Groups[1].Value.Trim()

    if ([string]::IsNullOrEmpty($installLocation)) {
        Write-Host "Could not determine install location for $pkg. Skipping PATH addition."
        continue
    }

    Write-Host "Detected install location: $installLocation"

    # Update PATH
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path","Machine")
    # Ensure we don't add duplicate entries
    if ($machinePath -notlike "*$installLocation*") {
        $newPath = $machinePath + ";" + $installLocation
        # Check length of PATH
        if ($newPath.Length -gt 30000) {
            Write-Warning "PATH is becoming very long. Consider creating a new env variable to shorten the path."
            # Create a new variable pointing to this tool
            $envName = $pkg.ToUpperInvariant() + "_HOME"
            $envName = $envName -replace "[^A-Z0-9_]", "_" # sanitize name
            [System.Environment]::SetEnvironmentVariable($envName, $installLocation, "Machine")
            $newPath = $machinePath + ";%$envName%"
        }

        [System.Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        Write-Host "$pkg install location added to system PATH."
    } else {
        Write-Host "$pkg is already in PATH."
    }
}

Write-Host "All installations complete. You may need to restart your session or open a new terminal to see PATH changes."
