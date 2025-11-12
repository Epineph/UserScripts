# Define variables
$OpenSSLRepoUrl = "https://github.com/openssl/openssl.git"
$OpenSSLDir = "$env:USERPROFILE\openssl"
$BuildDir = "$OpenSSLDir\build"
$InstallDir = "$OpenSSLDir\install"

# Ensure the Visual Studio environment variables are set
& "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"

# Clone the OpenSSL repository
if (-Not (Test-Path $OpenSSLDir)) {
    git clone $OpenSSLRepoUrl $OpenSSLDir
} else {
    Write-Output "OpenSSL repository already exists at $OpenSSLDir. Skipping clone."
}

# Navigate to the OpenSSL directory
Set-Location $OpenSSLDir

# Update the repository to ensure it's on the latest version
git pull origin main

# Clean previous build artifacts
if (Test-Path $BuildDir) {
    Remove-Item -Recurse -Force $BuildDir
}
if (Test-Path $InstallDir) {
    Remove-Item -Recurse -Force $InstallDir
}

# Create build and install directories
New-Item -ItemType Directory -Force -Path $BuildDir, $InstallDir

# Configure the build
Write-Output "Configuring the OpenSSL build..."
perl Configure VC-WIN64A --prefix=$InstallDir

# Build OpenSSL
Write-Output "Building OpenSSL..."
nmake

# Install OpenSSL
Write-Output "Installing OpenSSL..."
nmake install

Write-Output "OpenSSL build and installation completed successfully."
