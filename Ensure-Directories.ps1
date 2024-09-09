<#
.SYNOPSIS
    Ensures that the specified directories exist, creating them if necessary.

.DESCRIPTION
    This script loops through a list of directories provided as input and checks if each
    directory exists. If a directory does not exist, it creates the directory. This is useful 
    for setting up environments where specific directories are required.

.PARAMETER directories
    An array of directories to check and create if they do not exist.
    The default is an array with "$HOME\Documents", "$HOME\Downloads", and "$HOME\Scripts".

.EXAMPLE
    .\Ensure-Directories.ps1 -directories @("C:\Projects", "C:\Temp")

    This command checks if the "C:\Projects" and "C:\Temp" directories exist and creates them if they do not.
#>

param (
    [string[]]$directories = @("$HOME\Documents", "$HOME\Downloads", "$HOME\Scripts")
)

foreach ($dir in $directories) {
    if (-not (Test-Path -Path $dir)) {
        New-Item -Path $dir -ItemType Directory | Out-Null
        Write-Output "Created directory: $dir"
    } else {
        Write-Output "Directory already exists: $dir"
    }
}

