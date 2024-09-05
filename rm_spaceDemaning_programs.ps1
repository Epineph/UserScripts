# Script 1: List Top 40 Programs by Size

# Get the list of installed programs with their sizes
$programs = Get-WmiObject -Class Win32_Product | Select-Object Name, @{Name="SizeGB";Expression={[math]::Round($_.InstallSize / 1GB, 2)}} | Sort-Object -Property SizeGB -Descending

# Display the top 40 programs
$topPrograms = $programs | Select-Object -First 40
$topPrograms | ForEach-Object { $i = [array]::indexof($topPrograms, $_) + 1; Write-Output "$i. $($_.Name) - $($_.SizeGB) GB" }

# Ask the user to input the program numbers to remove
$removeList = Read-Host "Enter the program numbers to remove (e.g., 1,3,5-9)"

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
$programsToRemove = @()
foreach ($index in $indices) {
    $program = $topPrograms[$index - 1]
    $totalSize += $program.SizeGB
    $programsToRemove += $program.Name
}

# Prompt the user for confirmation
Write-Host "You are about to remove the following programs:"
$programsToRemove | ForEach-Object { Write-Host "- $_" }
Write-Host "Total space to be freed: $totalSize GB"

$confirmation = Read-Host "Are you sure you want to proceed? (yes/no)"
if ($confirmation -eq "yes") {
    foreach ($program in $programsToRemove) {
        $product = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -eq $program }
        $product.Uninstall()
    }
    Write-Host "Selected programs have been removed."
} else {
    Write-Host "Operation cancelled."
}

