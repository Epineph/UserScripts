<#
.SYNOPSIS
    Creates a new script file in the specified directory with the appropriate headers.

.DESCRIPTION
    This script creates a new script file based on the specified type (PowerShell, Bash, Python, RMarkdown, Markdown, etc.).
    It adds the appropriate shebang or header information based on the script type.

.PARAMETER Name
    The name of the script file. If no extension is provided, it will be added based on the selected type.

.PARAMETER Type
    The type of script to create (e.g., ps1, sh, py, rmd, md, txt). Determines the file extension and any headers.

.PARAMETER ScriptDir
    The directory where the script will be created. Defaults to "$HOME\powershell_scripts".

.PARAMETER OutputType
    For RMarkdown, specify the output type (html, docx, pdf, etc.).

.PARAMETER Toc
    For RMarkdown, specify whether to include a table of contents (true/false).

.PARAMETER Title
    The title of the document (for RMarkdown).

.PARAMETER Author
    The author of the document (for RMarkdown).

.EXAMPLE
    .\new_script.ps1 -Name "my_script" -Type "sh"

    Creates a new Bash script named "my_script.sh" with a shebang line.

.EXAMPLE
    .\new_script.ps1 -Name "analysis" -Type "rmd" -OutputType "pdf" -Title "My Analysis" -Author "John Doe" -Toc $true

    Creates a new RMarkdown document named "analysis.rmd" with the specified metadata.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$Name,                # -n | -N | --name

    [string]$Type = "ps1",        # -t | -T | --type

    [string]$ScriptDir = "$HOME\powershell_scripts", # Directory where the script will be created

    [string]$OutputType,          # For RMarkdown

    [switch]$Toc,                 # Include Table of Contents (for RMarkdown)

    [string]$Title = "Document Title",  # Title for RMarkdown

    [string]$Author = "Author Name"     # Author for RMarkdown
)

# Ensure script directory exists
if (-not (Test-Path -Path $ScriptDir -PathType Container)) {
    New-Item -Path $ScriptDir -ItemType Directory -Force | Out-Null
}

# Determine the file extension
switch ($Type.ToLower()) {
    "ps1" { $extension = ".ps1" }
    "sh" { $extension = ".sh" }
    "py" { $extension = ".py" }
    "rmd" { $extension = ".Rmd" }
    "md" { $extension = ".md" }
    "txt" { $extension = ".txt" }
    default { $extension = ".txt" }
}

# Full path to the new script
$scriptPath = Join-Path -Path $ScriptDir -ChildPath "$Name$extension"

# Content based on the type
$content = switch ($Type.ToLower()) {
    "ps1" { "# PowerShell script" }
    "sh" { "#!/bin/bash" }
    "py" { "#!/usr/bin/env python3" }
    "rmd" { 
        $output = if ($OutputType) { $OutputType } else { "html_document" }
        $tocValue = if ($Toc) { "TRUE" } else { "FALSE" }
        @"
---
title: "$Title"
author: "$Author"
output:
  $output:
    toc: $tocValue
---
"@
    }
    "md" { "# Markdown document" }
    "txt" { "# Text document" }
    default { "# New document" }
}

# Create the script file
Set-Content -Path $scriptPath -Value $content

Write-Host "Created script at '$scriptPath'."

