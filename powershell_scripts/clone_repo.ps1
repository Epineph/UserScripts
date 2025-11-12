<#
.SYNOPSIS
    Clones one or more Git repositories, with optional recursive submodule cloning.

.DESCRIPTION
    This script clones Git repositories from a specified instance (default is GitHub).
    You can specify multiple repositories to clone, and use the `-Recurse` switch to clone submodules recursively.
    By default, the repositories are cloned into `C:\Users\heini\repos`, but you can override this with the `-CloneDir` parameter.

.PARAMETER repos
    The list of repositories to clone. Each repository should be specified in the format `user/repo_name`.

.PARAMETER instance
    The Git instance to clone from. Defaults to `github.com`. You can specify another instance if needed.

.PARAMETER recurse
    If specified, the script will clone submodules recursively for each repository.

.PARAMETER CloneDir
    Specifies the directory where the repositories should be cloned. Defaults to `C:\Users\heini\repos`.

.EXAMPLE
    .\clone.ps1 sharkdp/fd sharkdp/bat doxygen/doxygen

    Clones the `fd`, `bat`, and `doxygen` repositories from GitHub into the default directory.

.EXAMPLE
    .\clone.ps1 -CloneDir "D:\Projects" sharkdp/fd sharkdp/bat

    Clones the `fd` and `bat` repositories from GitHub into the `D:\Projects` directory.
#>

param (
    [string[]]$repos,
    [string]$instance = "github.com",
    [switch]$recurse,
    [string]$CloneDir = "C:\Users\heini\repos"
)

function Clone-Repo {
    param (
        [string[]]$repos,
        [string]$instance,
        [switch]$recurse,
        [string]$CloneDir
    )

    # Ensure the clone directory exists
    if (-not (Test-Path -Path $CloneDir)) {
        Write-Host "Directory $CloneDir does not exist. Creating it..."
        New-Item -ItemType Directory -Path $CloneDir -Force | Out-Null
    }

    # Change to the clone directory
    Set-Location -Path $CloneDir

    foreach ($repo in $repos) {
        # Construct the Git clone command
        $userRepo = $repo -split '/'
        if ($userRepo.Length -eq 2) {
            $url = "git@${instance}:${repo}.git"
        } else {
            $url = $repo
        }

        # Add recursive option if the switch is provided
        $cloneCommand = "git clone"
        if ($recurse.IsPresent) {
            $cloneCommand += " --recurse-submodules"
        }
        $cloneCommand += " $url"

        # Execute the Git clone command
        Write-Host "Cloning repository from $url into $CloneDir..."
        Invoke-Expression $cloneCommand
    }
}

# Run the clone function with the provided parameters
Clone-Repo -repos $repos -instance $instance -recurse:$recurse -CloneDir $CloneDir
