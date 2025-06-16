<#
.SYNOPSIS
    Automates Git configuration with GPG commit signing and SSH key setup for GitHub.

.DESCRIPTION
    This script performs the following steps:
      1. Prompts for Git username and email, configures global Git settings.
      2. Generates or selects a GPG key for commit signing, configures Git to use it.
      3. Backs up existing SSH keys (if present), generates a new SSH key, and configures the SSH agent.
      4. Outputs the new GPG public key (ASCII-armored) for GitHub and the SSH public key with instructions.

.PARAMETER GitUsername
    The Git user.name to configure (global scope).

.PARAMETER GitEmail
    The Git user.email to configure (global scope) and for key generation.

.PARAMETER BackupDirectory
    Optional path where existing SSH keys are backed up. Defaults to "$HOME\.ssh_backup_<timestamp>".

.EXAMPLE
    # Run interactively, with default backup folder
    .\Configure-GitSecurity.ps1

.EXAMPLE
    # Specify a custom backup directory
    .\Configure-GitSecurity.ps1 -BackupDirectory "D:\KeyBackups"

.NOTES
    - Requires Git, GPG (GnuPG), and OpenSSH client installed and available in PATH.
    - Must be run in an elevated PowerShell session if modifying system-wide SSH agent.
    - On Windows, ensure the 'ssh-agent' service is enabled (Start-Service ssh-agent).
#>

[CmdletBinding()] 
param(
    [Parameter(Mandatory=$false)]
    [string]$BackupDirectory
)

function Show-Help {
    Get-Help -Detailed $MyInvocation.MyCommand.Path
    exit
}

function Configure-GitUser {
    Write-Host "\n==> Configuring Git global user identity..." -ForegroundColor Cyan
    $username = Read-Host -Prompt 'Enter your Git username'
    if (-not $username) {
        Write-Error 'Git username is required.'
        Show-Help
    }
    git config --global user.name "$username"

    $email = Read-Host -Prompt 'Enter your Git email address'
    if (-not $email) {
        Write-Error 'Git email address is required.'
        Show-Help
    }
    git config --global user.email "$email"
}

function Generate-GpgKey {
    Write-Host "\n==> Generating GPG key for commit signing..." -ForegroundColor Cyan
    Write-Host "A GPG key requires a name, email, and optional passphrase.\n"
    gpg --full-generate-key

    Write-Host "\nAvailable secret keys (long IDs):" -ForegroundColor Yellow
    gpg --list-secret-keys --keyid-format long

    $keyId = Read-Host -Prompt 'Enter the GPG key ID (long form) to use'
    if (-not $keyId) {
        Write-Error 'GPG key ID is required.'
        exit 1
    }

    git config --global user.signingkey $keyId
    $signAll = Read-Host -Prompt 'Sign all commits by default? (y/n)'
    if ($signAll -match '^[Yy]') {
        git config --global commit.gpgsign true
    }

    Write-Host "\nYour GPG public key (ASCII-armored), copy and add to GitHub:" -ForegroundColor Green
    gpg --armor --export $keyId
}

function Generate-SshKey {
    Write-Host "\n==> Setting up SSH key for GitHub..." -ForegroundColor Cyan
    $sshDir = Join-Path $HOME ".ssh"
    $defaultKey = Join-Path $sshDir 'id_rsa'

    if (Test-Path $defaultKey) {
        $backup = Read-Host -Prompt 'Existing SSH key found. Backup and generate a new one? (y/n)'
        if ($backup -match '^[Yy]') {
            if (-not $BackupDirectory) {
                $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                $BackupDirectory = Join-Path $HOME ".ssh_backup_$timestamp"
            }
            Write-Host "Backing up existing keys to $BackupDirectory" -ForegroundColor Yellow
            New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
            Copy-Item -Path "$sshDir\*" -Destination $BackupDirectory -Recurse
            Remove-Item -Path $defaultKey* -Force
        }
        else {
            Write-Host 'Skipping SSH key generation.' -ForegroundColor Yellow
            return
        }
    }

    $sshEmail = Read-Host -Prompt 'Enter your email address for SSH key comment'
    if (-not $sshEmail) {
        Write-Error 'Email address is required for SSH key generation.'
        exit 1
    }

    Write-Host "Generating SSH key (RSA 4096)..." -ForegroundColor Cyan
    ssh-keygen -t rsa -b 4096 -C $sshEmail -f $defaultKey -N ''

    Write-Host "\nStarting ssh-agent service..." -ForegroundColor Cyan
    if (Get-Service ssh-agent -ErrorAction SilentlyContinue) {
        Start-Service ssh-agent
    }
    else {
        Write-Warning 'ssh-agent service not found. Ensure OpenSSH client is installed.'
    }

    Write-Host "Adding SSH key to agent..." -ForegroundColor Cyan
    ssh-add $defaultKey

    Write-Host "\nYour SSH public key, copy and add to GitHub:" -ForegroundColor Green
    Get-Content "$defaultKey.pub"

    Write-Host "`nTo add to GitHub:"
    Write-Host " 1. Copy the above key."
    Write-Host " 2. In GitHub, go to Settings > SSH and GPG keys > New SSH key."
}

function Main {
    if ($args -contains '-h' -or $args -contains '--help') {
        Show-Help
    }

    Configure-GitUser
    Generate-GpgKey
    Generate-SshKey
}

# Execution starts here
Main @PSBoundParameters
