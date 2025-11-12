<#
.SYNOPSIS
    Creates a new script file in a predefined directory based on the script type and extension.

.DESCRIPTION
    This script allows you to create a new script file by specifying a name and type.
    It will automatically determine the correct location based on the file type and create the necessary directories if they do not exist.
    It will also insert a default header or shebang depending on the script type.

.PARAMETER Name
    The name of the script file to create.

.PARAMETER Type
    The type of the script (sh, ps1, py, r, rmd, md).

.PARAMETER Location
    The base location for scripts. If not provided, it defaults to the user's personal scripts directory.

.EXAMPLE
    .\new_script.ps1 -Name "install_grub" -Type "sh"

    Creates a shell script at "C:\Users\heini\scripts\shell_scripts\install_grub.sh" with a bash shebang line.

.EXAMPLE
    .\new_script.ps1 -Name "data_analysis" -Type "rmd"

    Creates an R Markdown script at "C:\Users\heini\scripts\Rmd\data_analysis.rmd" with a basic R Markdown header.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$Name,

    [Parameter(Mandatory=$true)]
    [ValidateSet("sh", "ps1", "py", "r", "rmd", "md")]
    [string]$Type,

    [string]$Location = "$env:PERSONAL_SCRIPTS"
)

function Get-DefaultDirectory {
    param (
        [string]$BaseLocation,
        [string]$Type
    )
    
    switch ($Type) {
        "sh" { return Join-Path -Path $BaseLocation -ChildPath "shell_scripts" }
        "ps1" { return Join-Path -Path $BaseLocation -ChildPath "pwsh_scripts" }
        "py" { return Join-Path -Path $BaseLocation -ChildPath "py_scripts" }
        "r" { return Join-Path -Path $BaseLocation -ChildPath "R_scripts" }
        "rmd" { return Join-Path -Path $BaseLocation -ChildPath "Rmd" }
        "md" { return Join-Path -Path $BaseLocation -ChildPath "md" }
        default { throw "Unsupported script type." }
    }
}

function Get-BoilerplateContent {
    param (
        [string]$Type,
        [string]$ScriptName
    )
    
    switch ($Type) {
        "sh" { return "#!/usr/bin/bash" }
        "ps1" { return "<#\n.SYNOPSIS\n    Brief description of the script.\n.DESCRIPTION\n    Detailed description of the script.\n.PARAMETER\n    List of parameters.\n.EXAMPLE\n    Example usage.\n#>" }
        "py" { return "#!/usr/bin/env python3" }
        "r" { return "# This is an R script." }
        "rmd" { return "---`n" + 'title: "' + $ScriptName + '"' + "`nauthor: 'me'`noutput: pdf_document`n---`n" }
        "md" { return "# $ScriptName`n" }
        default { throw "Unsupported script type." }
    }
}

# Determine the default directory based on the type
$defaultDirectory = Get-DefaultDirectory -BaseLocation $Location -Type $Type

# Ensure the directory exists
if (-not (Test-Path $defaultDirectory)) {
    New-Item -ItemType Directory -Path $defaultDirectory -Force | Out-Null
}

# Determine the full file path
$scriptFilePath = Join-Path -Path $defaultDirectory -ChildPath "$Name.$Type"

# Get the appropriate boilerplate content
$boilerplateContent = Get-BoilerplateContent -Type $Type -ScriptName $Name

# Create the script with the boilerplate content
Set-Content -Path $scriptFilePath -Value $boilerplateContent

Write-Host "Script '$Name.$Type' has been created at '$scriptFilePath'."
