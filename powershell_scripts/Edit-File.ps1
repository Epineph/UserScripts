<#
.SYNOPSIS
    Backs up a specified script file with versioning and optionally resets it (empties its contents) and opens it in an editor.

.DESCRIPTION
    This script copies a specified script file to a backup directory with versioning (enumerating backups if necessary).
    It can also reset the file (empties its contents) and open it in a specified editor after the operation.

.PARAMETER ScriptPath
    The full path of the script file to be backed up and reset.

.PARAMETER BackupDir
    The directory where the backup of the script will be saved. Defaults to "$HOME\backup_scripts".

.PARAMETER NoReset
    If specified, the script file will be backed up without resetting its contents.

.PARAMETER Editor
    The editor to use for opening the script file after the operation. Defaults to "notepad++".

.EXAMPLE
    .\reset_file.ps1 -ScriptPath "C:\path\to\script.ps1" -Editor "nvim"

    Backs up the script "script.ps1", resets it, and opens it in Neovim.

.EXAMPLE
    .\reset_file.ps1 -ScriptPath "C:\path\to\script.ps1" --backup-dir "C:\Users\heini\Desktop" --no-reset -Editor "code"

    Backs up the script "script.ps1" to "C:\Users\heini\Desktop" without resetting it and opens it in Visual Studio Code.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$ScriptPath,

    [string]$BackupDir = "$HOME\backup_scripts",

    [switch]$NoReset,

    [string]$Editor = "notepad++"
)

function Backup-File {
    param (
        [string]$FilePath,
        [string]$DestinationDir
    )

    # Ensure the backup directory exists
    if (-not (Test-Path $DestinationDir)) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }

    # Get the current date to create a folder
    $currentDate = Get-Date -Format "yyyy-MM-dd"
    $dateDir = Join-Path -Path $DestinationDir -ChildPath $currentDate

    # Ensure the date directory exists
    if (-not (Test-Path $dateDir)) {
        New-Item -ItemType Directory -Path $dateDir -Force | Out-Null
    }

    # Get the script file name
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $fileExtension = [System.IO.Path]::GetExtension($FilePath)

    # Enumerate existing backups and determine the new backup name
    $existingBackups = Get-ChildItem -Path $dateDir -Filter "$fileName*"
    $backupIndex = $existingBackups.Count + 1
    $backupFileName = "$fileName`_$backupIndex$fileExtension"
    $backupPath = Join-Path -Path $dateDir -ChildPath $backupFileName

    # Copy the file to the backup directory
    Copy-Item -Path $FilePath -Destination $backupPath -Force

    Write-Host "File '$FilePath' has been backed up to '$backupPath'."

    return $backupPath
}

function Reset-File {
    param (
        [string]$FilePath
    )

    # Reset (empty) the file
    Set-Content -Path $FilePath -Value $null

    Write-Host "File '$FilePath' has been reset (emptied)."
}

function Edit-File {
    param (
        [string]$FilePath,
        [string]$Editor
    )

    # Determine the editor executable
    switch ($Editor.ToLower()) {
        "notepad++" { 
            Start-Process -FilePath "notepad++" -ArgumentList $FilePath 
        }
        "code" { 
            Start-Process -FilePath "code" -ArgumentList $FilePath 
        }
        "nvim" { 
            Invoke-Expression "nvim $FilePath" 
        }
        "vim" { 
            Invoke-Expression "vim $FilePath" 
        }
        "notepad" { 
            Start-Process -FilePath "notepad" -ArgumentList $FilePath 
        }
        default {
            Write-Host "Unknown editor '$Editor'. Defaulting to notepad++."
            Start-Process -FilePath "notepad++" -ArgumentList $FilePath
        }
    }

    Write-Host "File '$FilePath' has been opened with '$Editor'."
}

# Backup the file
$backupPath = Backup-File -FilePath $ScriptPath -DestinationDir $BackupDir

# Optionally reset the file
if (-not $NoReset) {
    Reset-File -FilePath $ScriptPath
}

# Optionally open the file for editing
if ($Editor) {
    Edit-File -FilePath $ScriptPath -Editor $Editor
}

