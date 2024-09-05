function batCat {
    <#
    .SYNOPSIS
    A PowerShell wrapper for the bat command-line tool.

    .DESCRIPTION
    The batCat function is a wrapper around the bat command, providing options to display files with syntax highlighting,
    line numbers, paging, and themes. It allows for customizable viewing of files.

    .PARAMETER DirPath
    The path to the file you want to view. If not provided, the user will be prompted to enter it manually.

    .PARAMETER ShowLineNumbers
    If set to $true, bat will display line numbers with a grid style. Defaults to $false.

    .PARAMETER NoPaging
    If set to $true, bat will disable paging (`--paging=never`). Defaults to $true.

    .PARAMETER ShowColors
    If set to $true, colors are shown (`--color=always`). Defaults to $true.

    .PARAMETER Theme
    Specifies the color theme for bat. Defaults to "TwoDark". If the theme isn't available, bat will fall back to the default theme.

    .EXAMPLE
    batCat -DirPath "/some/dir/test.sh" -ShowLineNumbers $true -NoPaging $false -Theme "GitHub"

    This example outputs the file /some/dir/test.sh with line numbers, using the GitHub theme, and paging enabled.

    .NOTES
    Author: Your Name
    Dependencies: bat command-line tool
    #>

    param (
        [string]$DirPath,
        [switch]$ShowLineNumbers = $false,
        [switch]$NoPaging = $true,
        [switch]$ShowColors = $true,
        [string]$Theme = "TwoDark"
    )

    # Check if DirPath is provided, if not prompt the user
    if (-not $DirPath) {
        $DirPath = Read-Host "Enter the file path"
    }

    # Initialize arguments for bat command
    $args = @()

    if ($ShowLineNumbers) {
        $args += "--style=grid"
    } else {
        $args += "--style=plain"
    }

    if ($NoPaging) {
        $args += "--paging=never"
    } else {
        $args += "--paging=always"
    }

    if ($ShowColors) {
        $args += "--color=always"
    } else {
        $args += "--color=never"
    }

    # Add theme if specified
    if ($Theme) {
        $args += "--theme=$Theme"
    }

    # Add the file path as the last argument
    $args += $DirPath

    # Execute the bat command with the arguments
    bat @args
}

# Append to Profile Script
$profilePath = $PROFILE.CurrentUserAllHosts

if (-not (Test-Path -Path $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force
}

# Add the batCat function to the profile script
$batCatFunction = @"
function batCat {
    <#
    .SYNOPSIS
    A PowerShell wrapper for the bat command-line tool.

    .DESCRIPTION
    The batCat function is a wrapper around the bat command, providing options to display files with syntax highlighting,
    line numbers, paging, and themes. It allows for customizable viewing of files.

    .PARAMETER DirPath
    The path to the file you want to view. If not provided, the user will be prompted to enter it manually.

    .PARAMETER ShowLineNumbers
    If set to `$true, bat will display line numbers with a grid style. Defaults to `$false.

    .PARAMETER NoPaging
    If set to `$true, bat will disable paging (--paging=never). Defaults to `$true.

    .PARAMETER ShowColors
    If set to `$true, colors are shown (--color=always). Defaults to `$true.

    .PARAMETER Theme
    Specifies the color theme for bat. Defaults to 'TwoDark'. If the theme isn't available, bat will fall back to the default theme.

    .EXAMPLE
    batCat -DirPath '/some/dir/test.sh' -ShowLineNumbers `$true -NoPaging `$false -Theme 'GitHub'

    This example outputs the file /some/dir/test.sh with line numbers, using the GitHub theme, and paging enabled.

    .NOTES
    Author: Your Name
    Dependencies: bat command-line tool
    #>

    param (
        [string]`$DirPath,
        [switch]`$ShowLineNumbers = `$false,
        [switch]`$NoPaging = `$true,
        [switch]`$ShowColors = `$true,
        [string]`$Theme = 'TwoDark'
    )

    if (-not `$DirPath) {
        `$DirPath = Read-Host 'Enter the file path'
    }

    `$args = @()
    if (`$ShowLineNumbers) {
        `$args += '--style=grid'
    } else {
        `$args += '--style=plain'
    }

    if (`$NoPaging) {
        `$args += '--paging=never'
    } else {
        `$args += '--paging=always'
    }

    if (`$ShowColors) {
        `$args += '--color=always'
    } else {
        `$args += '--color=never'
    }

    if (`$Theme) {
        `$args += '--theme=' + `$Theme
    }

    `$args += `$DirPath
    bat `@args
}
"@

Add-Content -Path $profilePath -Value "`n$batCatFunction`n"

# Reload the profile
. $profilePath
