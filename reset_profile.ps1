<#
.SYNOPSIS
Resets the PowerShell profile by either clearing it or preserving the current content, with the option to choose an editor.

.DESCRIPTION
This script allows you to reset your PowerShell profile by either clearing its contents or preserving the current profile.
If the profile exists, it will be backed up to a log file before any changes are made. The backup is stored in a directory
under Documents\powershell_profile_logs\date\ with a sequential log file name. You can choose the editor to open the profile with, defaulting to Notepad++.

.PARAMETER Editor
Specifies the editor to use for opening the profile. Options include 'notepad', 'notepad++', 'code', 'vim', and 'nvim'. The default is 'notepad++'.

.EXAMPLE
.\reset_profile.ps1 -Editor code

This example runs the script, backs up the existing profile, prompts the user to clear or preserve the profile, and then opens it in Visual Studio Code.

.NOTES
Author: Your Name
This script is useful for resetting your PowerShell profile while maintaining a history of changes. It creates a backup of
the profile's previous content before clearing it, allowing you to revert if needed.
#>

param (
    [Alias("E")]
    [ValidateSet("notepad", "notepad++", "code", "vim", "nvim")]
    [string]$Editor = "notepad++"
)

# Define paths to editors
$editorPaths = @{
    "notepad"  = "C:\Windows\System32\notepad.exe"
    "notepad++" = "C:\Program Files\Notepad++\notepad++.exe"
    "code"     = "C:\ProgramData\chocolatey\bin\code.exe"
    "vim"      = "C:\Program Files\Git\usr\bin\vim.exe"
    "nvim"     = "C:\tools\neovim\nvim-win64\bin\nvim.exe"
}

# Define paths
$profilePath = $PROFILE.CurrentUserAllHosts
$logDir = "$HOME\Documents\powershell_profile_logs"
$dateDir = Get-Date -Format "yyyy-MM-dd"
$logDateDir = Join-Path $logDir $dateDir

# Ensure log directory exists
if (-not (Test-Path -Path $logDateDir)) {
    New-Item -ItemType Directory -Path $logDateDir -Force
}

# Determine the next log file number
$logFiles = Get-ChildItem -Path $logDateDir -Filter "profile_log_*" | Sort-Object Name
$nextLogNumber = ($logFiles.Count + 1)
$logFilePath = Join-Path $logDateDir "profile_log_$nextLogNumber.txt"

# Backup the existing profile if it exists
if (Test-Path -Path $profilePath) {
    $backupContent = Get-Content -Path $profilePath -Raw
    Set-Content -Path $logFilePath -Value $backupContent
    Write-Output "Profile backup created at $logFilePath"
} else {
    Write-Output "No existing profile found. No backup created."
}

# Prompt to clear the profile or preserve it
$choice = Read-Host "Do you want to clear the profile? (Yes/No)"
if ($choice -eq "Yes") {
    # Clear the profile by writing an empty string to it
    Set-Content -Path $profilePath -Value ""
    Write-Output "Profile has been cleared. You can now paste new contents."
} else {
    Write-Output "Profile reset aborted. Existing profile has been preserved."
}

# Open the profile with the chosen editor
if ($editorPaths.ContainsKey($Editor)) {
    & $editorPaths[$Editor] $profilePath
} else {
    Write-Warning "The specified editor ($Editor) is not recognized. Opening with Notepad++ as default."
    & $editorPaths["notepad++"] $profilePath
}

