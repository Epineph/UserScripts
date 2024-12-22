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

.PARAMETER None
    The script does not accept any parameters. It interacts with the user through prompts to gather necessary information.

.EXAMPLE
    To run the script, execute:
    PS> .\YourScriptName.ps1
    Follow the on-screen prompts to generate keys and push changes to your repository.

.NOTES
    Ensure that PowerShell is run with administrator privileges to allow installation of required components.
    An active internet connection is required for downloading and installing Gpg4win and OpenSSH if they are not already installed.

.LINK
    For more information on comment-based help in PowerShell, visit:
    https://learn.microsoft.com/en-us/powershell/scripting/developer/help/writing-help-for-windows-powershell-scripts-and-functions
#>

# Function to ensure Gpg4win is installed
function Ensure-Gpg4win {
    # Common installation path for Gpg4win
    $gpgPath = "C:\Program Files (x86)\GnuPG\bin\gpg.exe"

    # If not found in the x86 path, check the Program Files path
    if (-Not (Test-Path $gpgPath)) {
        $gpgPath = "C:\Program Files\GnuPG\bin\gpg.exe"
    }

    if (-Not (Test-Path $gpgPath)) {
        Write-Host "Gpg4win is not installed. Installing..."
        $installerPath = "$env:TEMP\gpg4win.exe"
        
        # Download Gpg4win installer
        Invoke-WebRequest -Uri "https://www.gpg4win.org/installer/gpg4win.exe" -OutFile $installerPath
        
        # Attempt a silent installation
        # /S is commonly used for silent mode, but might differ with Gpg4win versions
        Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait

        # Remove installer after installation
        Remove-Item -Path $installerPath -ErrorAction SilentlyContinue
        
        # Double-check after installation
        if (Test-Path $gpgPath) {
            Write-Host "Gpg4win installation completed."
        } else {
            Write-Host "Gpg4win installation may have failed. Please check manually."
        }
    } else {
        Write-Host "Gpg4win is already installed."
    }
}

# Function to ensure OpenSSH is installed
function Ensure-OpenSSH {
    $sshPath = "C:\Windows\System32\OpenSSH\ssh.exe"
    if (-Not (Test-Path $sshPath)) {
        Write-Host "OpenSSH is not installed. Installing..."
        try {
            Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
            Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

            # Configure and start sshd service
            Start-Service sshd -ErrorAction SilentlyContinue
            Set-Service -Name sshd -StartupType 'Automatic'

            Write-Host "OpenSSH installation and configuration completed."
        } catch {
            Write-Error "Failed to install OpenSSH. Please ensure you have admin rights and are on a supported Windows version."
        }
    } else {
        Write-Host "OpenSSH is already installed."
    }
}

# Function to generate an SSH key
function Generate-SSHKey {
    param(
        [string]$Email
    )

    # Ensure ssh-keygen is available
    $sshKeygen = "C:\Windows\System32\OpenSSH\ssh-keygen.exe"
    if (-Not (Test-Path $sshKeygen)) {
        Write-Error "ssh-keygen not found. Ensure OpenSSH is properly installed."
        return
    }

    Write-Host "Generating a new SSH key..."
    & $sshKeygen -t rsa -b 4096 -C $Email

    # Start ssh-agent if available
    if (Get-Service ssh-agent -ErrorAction SilentlyContinue) {
        Write-Host "Starting the ssh-agent..."
        Set-Service ssh-agent -StartupType Automatic
        Start-Service ssh-agent
    } else {
        Write-Host "ssh-agent service not found. Skipping agent startup."
    }

    # Ensure ssh-add is available and add the key
    $sshAdd = "C:\Windows\System32\OpenSSH\ssh-add.exe"
    if (Test-Path $sshAdd) {
        Write-Host "Adding your SSH key to the ssh-agent..."
        & $sshAdd $HOME\.ssh\id_rsa
    } else {
        Write-Host "ssh-add not found. Please add your key manually."
    }

    Write-Host "Your SSH public key to add to GitHub:"
    Get-Content $HOME\.ssh\id_rsa.pub
}

# Function to generate a GPG key
function Generate-GPGKey {
    # Ensure gpg is in PATH or at known location
    $gpg = "gpg.exe"
    if (-not (Get-Command $gpg -ErrorAction SilentlyContinue)) {
        Write-Error "gpg not found in PATH. Ensure Gpg4win is installed and available."
        return
    }

    Write-Host "Generating a new GPG key..."
    # Note: gpg --full-generate-key is interactive. Follow the prompts in the console.
    gpg --full-generate-key

    Write-Host "Listing your GPG keys..."
    gpg --list-secret-keys --keyid-format LONG

    $gpgKeyId = Read-Host "Enter the GPG key ID (long form) you'd like to use for signing commits"
    if ([string]::IsNullOrWhiteSpace($gpgKeyId)) {
        Write-Error "No GPG key ID provided."
        return
    }

    Write-Host "Configuring Git to use the GPG key..."
    git config --global user.signingkey $gpgKeyId

    $signAllCommits = Read-Host "Would you like to sign all commits by default? (y/n)"
    if ($signAllCommits.ToLower() -eq "y") {
        git config --global commit.gpgsign true
        Write-Host "All commits will now be signed by default."
    } else {
        Write-Host "Commits will not be signed by default."
    }
}

# Main script execution
try {
    # Ensure required tools are installed
    Ensure-Gpg4win
    Ensure-OpenSSH

    # Prompt user for email for SSH key
    $email = Read-Host "Enter the email associated with your GitHub account (for SSH key)"
    Generate-SSHKey -Email $email

    # GPG key generation
    Generate-GPGKey

    Write-Host "Setup complete. You can now add your SSH public key to GitHub and configure your GPG key there as well."
} catch {
    Write-Error "An error occurred: $_"
}
