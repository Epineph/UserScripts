<#
.SYNOPSIS
    Adds a comment with the script's full path to the top of each .ps1 file in the specified directory.

.DESCRIPTION
    This script loops through all .ps1 files in the specified directory and adds a comment line
    with the script's full path at the top of each file. This is useful for tracking the location 
    of scripts, especially in environments with many scripts scattered across directories.

.PARAMETER directory
    The directory containing the .ps1 files to which the path comments will be added. 
    The default is "$HOME\powershell_scripts".

.EXAMPLE
    .\Add-PathComments.ps1 -directory "C:\Users\heini\powershell_scripts"

    This command adds the full path as a comment at the top of each .ps1 file in the 
    "C:\Users\heini\powershell_scripts" directory.
#>

param (
    [string]$directory = "$HOME\powershell_scripts"
)

Get-ChildItem -Path $directory -Filter *.ps1 | ForEach-Object {
    $fullPath = $_.FullName
    $pathComment = "# $fullPath"

    # Read the content of the script
    $content = Get-Content -Path $fullPath

    # Prepend the path comment to the script content
    $newContent = @($pathComment) + $content

    # Write the new content back to the script
    Set-Content -Path $fullPath -Value $newContent
    Write-Output "Added path comment to $fullPath"
}

