<#
.SYNOPSIS
    This script lists the top 40 folders by size within a specified directory and allows the user to remove selected folders.

.DESCRIPTION
    The script takes a directory path as input and calculates the size of each folder within that directory recursively.
    It then ranks the folders by size and displays the top 40. The user can input the numbers corresponding to the folders
    they want to remove. The script calculates the total space that will be freed and prompts the user for confirmation
    before proceeding with the deletion.

.PARAMETER Path
    The directory path to analyze. If not provided, the script will prompt the user to enter a path.

.EXAMPLE
    PS C:\> .\ListAndRemoveFolders.ps1 -Path "C:\Users\heini\Documents"
    1. ProjectA - 4.56 GB
    2. ProjectB - 3.23 GB
    3. Backup - 2.67 GB
    ...
    Enter the folder numbers to remove (e.g., 1,3,5-9): 2,3
    You are about to remove the following folders:
    - ProjectB
    - Backup
    Total space to be freed: 5.90 GB
    Are you sure you want to proceed? (yes/no): yes

.NOTES
    The script requires the user to have appropriate permissions to delete the folders. Use with caution as the operation
    is irreversible.

#>

param(
    [string]$path = $(Read-Host "Enter the directory path")
)

# Function to calculate folder size recursively
function Get-FolderSize {
    param ([string]$folderPath)

    $size = (Get-ChildItem -Path $folderPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    return [math]::Round($size / 1GB, 2)
}

# Get the list of folders and their sizes
$folders = Get-ChildItem -Path $path -Directory | ForEach-Object {
    $folderSize = Get-FolderSize $_.FullName
    [PSCustomObject]@{
        Name = $_.Name
        Path = $_.FullName
        SizeGB = $folderSize
    }
} | Sort-Object -Property SizeGB -Descending

# Display the top 40 folders
$topFolders = $folders | Select-Object -First 40
$topFolders | ForEach-Object { $i = [array]::indexof($topFolders, $_) + 1; Write-Output "$i. $($_.Name) - $($_.SizeGB) GB" }

# Ask the user to input the folder numbers to remove
$removeList = Read-Host "Enter the folder numbers to remove (e.g., 1,3,5-9)"

# Parse the input into an array of numbers
$indices = @()
$removeList -split ',' | ForEach-Object {
    if ($_ -match "-") {
        $range = $_ -split "-"
        $indices += $range[0]..$range[1]
    } else {
        $indices += $_
    }
}

# Calculate the total size to be removed
$totalSize = 0
$foldersToRemove = @()
foreach ($index in $indices) {
    $folder = $topFolders[$index - 1]
    $totalSize += $folder.SizeGB
    $foldersToRemove += $folder.Path
}

# Prompt the user for confirmation
Write-Host "You are about to remove the following folders:"
$foldersToRemove | ForEach-Object { Write-Host "- $_" }
Write-Host "Total space to be freed: $totalSize GB"

$confirmation = Read-Host "Are you sure you want to proceed? (yes/no)"
if ($confirmation -eq "yes") {
    foreach ($folder in $foldersToRemove) {
        Remove-Item -Path $folder -Recurse -Force
    }
    Write-Host "Selected folders have been removed."
} else {
    Write-Host "Operation cancelled."
}

