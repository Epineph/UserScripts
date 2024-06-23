# Function to generate an SSH key
function Generate-SSHKey {
    param(
        [string]$email
    )

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
    Write-Host "Generating a new GPG key..."
    gpg --full-generate-key

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
    param(
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
$needGPG = Read-Host "Do you need to generate a GPG key? (y/n)"
if ($needGPG -eq "y") {
    Generate-GPGKey
}

$needSSH = Read-Host "Do you need to generate an SSH key? (y/n)"
if ($needSSH -eq "y") {
    $email = Read-Host "Enter your GitHub email"
    Generate-SSHKey -email $email
}

$token = Read-Host "Enter your GitHub Personal Access Token"
Git-Push -token $token
