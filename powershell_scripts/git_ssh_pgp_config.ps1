<#
.SYNOPSIS
    Generates SSH and GPG keys, verifies the installation of Gpg4win and OpenSSH, and automates the process of committing and pushing changes to a Git repository.

.DESCRIPTION
    This script assists users in setting up secure communication and version control by:
    - Checking for the installation of Gpg4win and OpenSSH, installing them if necessary.
    - Generating SSH keys for secure connections.
    - Generating GPG keys for commit signing.
    - Configuring Git to use the generated keys.
    - Automating the process of adding, committing (with GPG signing), and pushing changes to a Git repository.

.PARAMETER Generate
    Specifies which keys to generate. Accepts 'ssh', 'gpg', or 'both'. Default is 'both'.

.PARAMETER FullName
    The user's full name to be associated with the GPG key.

.PARAMETER Email
    The user's email address to be associated with the SSH and GPG keys.

.EXAMPLE
    To generate both SSH and GPG keys with specified user details:
    PS> .\YourScriptName.ps1 -Generate both -FullName "John Doe" -Email "john.doe@example.com"

.NOTES
    Ensure that PowerShell is run with administrator privileges to allow installation of required components.
    An active internet connection is required for downloading and installing Gpg4win and OpenSSH if they are not already installed.

.LINK
    For more information on comment-based help in PowerShell, visit:
    https://learn.microsoft.com/en-us/powershell/scripting/developer/help/writing-help-for-windows-powershell-scripts-and-functions
#>

param (
    [ValidateSet('ssh', 'gpg', 'both')]
    [string]$Generate = 'both',
    [string]$FullName,
    [string]$Email
)

# Function to check and install Gpg4win
function Ensure-Gpg4win {
    $gpgPath = "C:\Program Files (x86)\GnuPG\bin\gpg.exe"
    if (-Not (Test-Path $gpgPath)) {
        Write-Host "Gpg4win is not installed. Installing..."
        $installerPath = "$env:TEMP\gpg4win.exe"
        Invoke-WebRequest -Uri "https://www.gpg4win.org/installer/gpg4win.exe" -OutFile $installerPath
        Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
        Remove-Item -Path $installerPath
        Write-Host "Gpg4win installation completed."
    } else {
        Write-Host "Gpg4win is already installed."
    }
}

# Function to check and install OpenSSH
function Ensure-OpenSSH {
    $sshPath = "C:\Windows\System32\OpenSSH\ssh.exe"
    if (-Not (Test-Path $sshPath)) {
        Write-Host "OpenSSH is not installed. Installing..."
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        Start-Service sshd
        Set-Service -Name sshd -StartupType 'Automatic'
        Write-Host "OpenSSH installation and configuration completed."
    } else {
        Write-Host "OpenSSH is already installed."
    }
}

# Function to generate an SSH key
function Generate-SSHKey {
    param (
        [string]$email
    )

    if (-Not $email) {
        $email = Read-Host "Enter your GitHub email"
    }

    Write-Host "Generating a new SSH key..."
    ssh-keygen -t rsa -b 4096 -C $email

    Write-Host "Starting the ssh-agent..."
    Start-Service ssh-agent

    Write-Host "Adding your SSH key to the ssh-agent..."
    ssh-add $HOME\.ssh\id_rsa

    Write-Host "Your SSH public key to add to GitHub:"
    Get-Content $HOME\.ssh\id_rsa.pub
}

# Function to generate a GPG key
function Generate-GPGKey {
    param (
        [string]$fullName,
        [string]$email
    )

    if (-Not $fullName) {
        $fullName = Read-Host "Enter your full name"
    }
    if (-Not $email) {
        $email = Read-Host "Enter your email"
    }

    Write-Host "Generating a new GPG key..."
    gpg --quick-gen-key "$fullName <$email>"

    Write-Host "Listing your GPG keys..."
    gpg --list-secret-keys --keyid-format LONG

    $gpgKeyId = Read-Host "Enter the GPG key ID (long form) you'd like to use for signing commits"

    Write-Host "Configuring Git to use the GPG key..."
    git config --global user.signingkey $gpgKeyId

    $signAllCommits = Read-Host "Would you like to sign all commits by default? (y/n)"
    if ($signAllCommits -eq "y") {
        git config --global commit.gpgsign true
    }

    Write-Host "Your GPG public key to add to GitHub:"
    gpg --armor --export $gpgKeyId
}

# Function to push changes to GitHub
function Git-Push {
    param (
        [string]$token,
        [string]$branch = "main"
    )

    $commitMessage = Read-Host "Enter the commit message"

    Write-Host "Adding all changes to the repository..."
    git add .

    Write-Host "Committing the changes..."
    git commit -S -m $commitMessage

    Write-Host "Pushing the changes..."
    $repoUrl = git config --get remote.origin.url
    $sanitizedUrl = $repoUrl -replace 'https://', "https://$token@"
    git push $sanitizedUrl $branch

    Write-Host "Changes committed and pushed successfully."
}

# Main script logic
Ensure-Gpg4win
Ensure-OpenSSH

switch ($Generate) {
    'ssh' {
        Generate-SSHKey -email $Email
    }
    'gpg' {
        Generate-GPGKey -fullName $FullName -email $Email
    }
    'both' {
        Generate-SSHKey -email $Email
        Generate-GPGKey -fullName $FullName -email $Email
    }
}

$token = Read-
::contentReference[oaicite:0]{index=0}
 
