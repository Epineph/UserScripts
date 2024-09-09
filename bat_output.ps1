<#
.SYNOPSIS
    Handles file or directory input, offering options for previewing, editing, or viewing files using 'bat' and 'lsd'.

.DESCRIPTION
    This script takes a file or directory path as input and allows you to preview, edit, or view the files 
    using the 'bat' and 'lsd' commands. It supports recursive directory searches with depth control, 
    filtering by file type, and options to bypass interactive file selection or paging.

.PARAMETER path
    The file or directory path to process. If a directory is provided, the script can list files recursively.

.PARAMETER recursive
    Enables recursive listing of files in the specified directory.

.PARAMETER depth
    Specifies the depth of recursion when listing files in a directory. The default is 1.

.PARAMETER scriptType
    Filters files by the specified script type or extension (e.g., ".ps1", ".py", ".sh"). The default is "*.ps1".

.PARAMETER preview
    Enables preview mode in 'bat', allowing you to see a preview of the file content.

.PARAMETER editor
    Opens selected files in the specified editor (e.g., "nvim", "code", "notepad++", "notepad").

.PARAMETER noPaging
    Disables paging in 'bat', outputting the file content directly to the terminal.

.PARAMETER noFzf
    Disables the use of 'fzf' for file selection, directly outputting all matching files.

.EXAMPLE
    .\bat_output.ps1 -path "C:\Users\heini\powershell_scripts" -recursive -depth 2 -scriptType "*.ps1"

    This command lists all .ps1 files in "C:\Users\heini\powershell_scripts" and its subdirectories up to a depth of 2, 
    then allows you to select and view them using 'bat'.

.EXAMPLE
    .\bat_output.ps1 -path "C:\Users\heini\scripts" -scriptType "*.py" -noFzf

    This command lists all .py files in "C:\Users\heini\scripts" without using 'fzf' for selection, directly displaying them.

.EXAMPLE
    .\bat_output.ps1 -path "C:\Users\heini\projects" -preview -noPaging

    This command previews the content of selected files in "C:\Users\heini\projects" without using paging.
#>

param (
    [string]$path,
    [switch]$recursive,
    [int]$depth = 1,
    [string]$scriptType = "*.ps1",  # Default to PowerShell scripts, e.g., ".ps1", ".py", ".sh"
    [switch]$preview,
    [switch]$editor,
    [switch]$noPaging,
    [switch]$noFzf
)

# Define bat and lsd commands with default options
$batCmd = "bat --style=grid --theme=TwoDark --paging=never --color=always"
$lsdCmd = "lsd -a -A -l -h"

# Adjust lsd command if recursive is enabled
if ($recursive) {
    $lsdCmd += " -R"
    if ($depth -gt 0) {
        $lsdCmd += " --depth $depth"
    }
}

# Function to list and filter files
function Get-FilteredFiles {
    param (
        [string]$directory,
        [string]$filter = "*.*",
        [switch]$recursive,
        [int]$depth = 1
    )

    if ($recursive) {
        Get-ChildItem -Path $directory -Filter $filter -Recurse -Depth $depth
    } else {
        Get-ChildItem -Path $directory -Filter $filter
    }
}

if (Test-Path -Path $path) {
    if (Test-Path -Path $path -PathType Container) {
        # If path is a directory, list and filter files using Get-FilteredFiles function
        $files = Get-FilteredFiles -directory $path -filter $scriptType -recursive:$recursive -depth $depth
        
        if ($noFzf) {
            # Output directly if noFzf is enabled
            foreach ($file in $files) {
                if ($preview) {
                    Invoke-Expression "$batCmd $file.FullName --preview"
                } else {
                    Invoke-Expression "$batCmd $file.FullName"
                }
            }
        } else {
            # Use lsd command with fzf for selection
            $lsdOutput = Invoke-Expression "$lsdCmd $path"
            $selectedFiles = $lsdOutput | fzf --multi
            
            foreach ($file in $selectedFiles) {
                if ($preview) {
                    Invoke-Expression "$batCmd $file --preview"
                } else {
                    Invoke-Expression "$batCmd $file"
                }
            }
        }
    } elseif (Test-Path -Path $path -PathType Leaf) {
        # If path is a file, directly use bat to display it
        if ($preview) {
            Invoke-Expression "$batCmd $path --preview"
        } else {
            Invoke-Expression "$batCmd $path"
        }
    }
}

# If --editor is specified, open the selected files with the chosen editor
if ($editor -and $selectedFiles) {
    foreach ($file in $selectedFiles) {
        switch ($editor) {
            "nvim" { Invoke-Expression "nvim $file" }
            "code" { Invoke-Expression "code $file" }
            "notepad++" { Invoke-Expression "notepad++ $file" }
            "notepad" { Invoke-Expression "notepad $file" }
            default { Write-Warning "Editor not supported: $editor" }
        }
    }
}

