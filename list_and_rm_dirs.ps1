# Script 2: List Top 40 Folders by Size in a Given Path

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

