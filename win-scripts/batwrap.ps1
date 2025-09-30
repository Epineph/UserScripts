<#
.SYNOPSIS
    PowerShell wrapper for bat (cat clone with syntax highlighting) with custom defaults.

.DESCRIPTION
    Provides a bat wrapper with Heini's preferred defaults:
    --style="snip,header" --paging="never" --italic-text="always" 
    --force-colorization --squeeze-blank --squeeze-limit="2" 
    --terminal-width="-1" --theme="gruvbox-dark" --wrap="auto"

.PARAMETER Path
    File or directory path to display (supports multiple paths).

.PARAMETER Language
    Explicit language for syntax highlighting.

.PARAMETER Theme
    Override the default gruvbox-dark theme.

.PARAMETER Paging
    Override paging mode (never/auto/always).

.PARAMETER Plain
    Disable all styling and decorations (equivalent to --plain).

.PARAMETER ShowAll
    Show non-printable characters (like cat -A).

.EXAMPLE
    .\batwrap.ps1 .\script.ps1
    Display a file with default formatting.

.EXAMPLE
    .\batwrap.ps1 -Path *.md -Language markdown
    Display all markdown files with proper syntax highlighting.

.NOTES
    Requires bat to be installed: https://github.com/sharkdp/bat
    Version: 1.0.0
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
    [Alias("File", "Target")]
    [string[]]$Path,

    [Alias("L")]
    [string]$Language,

    [string]$Theme = "gruvbox-dark",

    [ValidateSet("never", "auto", "always")]
    [string]$Paging = "never",

    [switch]$Plain,

    [Alias("A")]
    [switch]$ShowAll
)

begin {
    # Verify bat is installed
    if (-not (Get-Command bat -ErrorAction SilentlyContinue)) {
        Write-Error "bat command not found. Please install from https://github.com/sharkdp/bat"
        exit 1
    }

    # Build base command arguments
    $batArgs = @(
        "--style=`"snip,header`"",
        "--paging=$Paging",
        "--italic-text=`"always`"",
        "--force-colorization",
        "--squeeze-blank",
        "--squeeze-limit=`"2`"",
        "--terminal-width=`"-1`"",
        "--theme=`"$Theme`"",
        "--wrap=`"auto`""
    )

    if ($Plain) {
        $batArgs += "--plain"
    }

    if ($ShowAll) {
        $batArgs += "--show-all"
    }

    if ($Language) {
        $batArgs += "--language=`"$Language`""
    }
}

process {
    foreach ($item in $Path) {
        try {
            $resolvedPath = Resolve-Path $item -ErrorAction Stop
            $fullArgs = $batArgs + "`"$resolvedPath`""
            
            Write-Verbose "Executing: bat $($fullArgs -join ' ')"
            Start-Process -FilePath "bat" -ArgumentList $fullArgs -NoNewWindow -Wait
        }
        catch {
            Write-Warning "Failed to process path '$item': $_"
        }
    }
}

end {
    Write-Verbose "bat wrapper execution completed"
}