<#
.SYNOPSIS
    A helper script for winget that can search or install packages with features similar to Arch's AUR helper "yay".

.DESCRIPTION
    This script provides two main functionalities:

    1. Search mode (default): When not using -S, provide a search term as an argument. The script will:
       - Run 'winget search <term>'
       - Parse and display the results with an added numeric index column.
       - Prompt you to select packages by their number or range.
       - Install the selected packages (optionally without confirmation if -NoConfirm is used).
       - (Optional) Log the entire search results to a file in either CSV or TXT format.

    2. Install mode: When using -S, all subsequent arguments are considered package names to install directly via winget.
       - Automatically accept agreements if -NoConfirm is specified.
       - (Optional) Log is still possible if -LogOutput is used.

    Logging:
    - If -LogOutput is specified, a log file will be created named after the search term (in search mode) or "install_log"
      (in install mode if no search term is present) and appended with the chosen format (.txt or .csv).
    - If -LogPath is specified, logs are stored in that directory. Otherwise, they go to ~/winget-helper-logs by default.
    - The directory is created if it does not exist.
    - The CSV logs will be properly comma-separated so they can be opened in Excel, R, etc.

.PARAMETER S
    Switch. If used, the following arguments are considered package names for installation rather than a search term.

.PARAMETER NoConfirm
    Switch. If used, passes '--accept-package-agreements --accept-source-agreements' to winget install.

.PARAMETER LogOutput
    Switch. If set, enables logging the search results (and possibly the installation actions).

.PARAMETER Format
    Specifies the format of the log file. Acceptable values: 'csv', 'txt'
    Default: 'txt' if not specified.

.PARAMETER LogPath
    Specifies a custom directory to store the log files. If not provided, uses ~/winget-helper-logs.
    The directory will be created if it doesn't exist.

.PARAMETER Help
    Show this help message.

.EXAMPLE
    winget-helper vim
    Searches for 'vim', displays enumerated results, prompts user to select packages to install.

.EXAMPLE
    winget-helper -S vim vim.vim.nightly -NoConfirm
    Installs 'vim' and 'vim.vim.nightly' directly without searching, accepting all agreements automatically.

.EXAMPLE
    winget-helper vim -LogOutput csv
    Searches for 'vim', logs the results as CSV in ~/winget-helper-logs/vim.csv,
    prompts user to select packages, and installs them.

.EXAMPLE
    winget-helper vim -NoConfirm -LogOutput -Format csv -LogPath C:\mylogs
    Searches for 'vim', logs results as CSV to C:\mylogs\vim.csv, installs selected packages with no confirmation.

#>

[CmdletBinding()]
Param(
    [Switch]$S,
    [Switch]$NoConfirm,
    [Switch]$LogOutput,
    [ValidateSet("csv","txt")]
    [string]$Format = "txt",
    [string]$LogPath,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

# Show help if requested
if ($PSBoundParameters.ContainsKey('Help')) {
    Get-Help $MyInvocation.MyCommand.Path -Full
    return
}

# Ensure winget is available
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "winget not found. Please ensure winget is installed and on PATH."
    exit 1
}

# If in install mode (-S), the remaining arguments are packages to install
# If not in install mode, the last argument is considered the search term
if ($S) {
    $PackagesToInstall = $Args
    if (-not $PackagesToInstall) {
        Write-Error "No packages specified after -S."
        exit 1
    }
    $searchTerm = $PackagesToInstall -join '_'
} else {
    if (-not $Args) {
        Write-Error "No search term provided."
        exit 1
    }
    $searchTerm = $Args[-1] # last argument is search term
    $PackagesToInstall = @()
}

# Determine log directory
if (-not $LogPath) {
    $LogPath = (Join-Path $HOME "winget-helper-logs")
}
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

# Determine log file name
$logFileExtension = $Format
if (-not $S) {
    # Search mode: name the log after the search term
    $logFileName = "$searchTerm.$logFileExtension"
} else {
    # Install mode: if user provided no search term (since it's direct install), name it something generic
    if ([string]::IsNullOrWhiteSpace($searchTerm)) {
        $logFileName = "install_log.$logFileExtension"
    } else {
        # If $searchTerm came from joining packages, just use it
        $logFileName = "$searchTerm.$logFileExtension"
    }
}
$logFilePath = Join-Path $LogPath $logFileName

# Function to install packages
function Install-Packages {
    param(
        [string[]]$Pkgs,
        [switch]$NoConfirm
    )
    foreach ($p in $Pkgs) {
        $installCmd = "winget install `"$p`""
        if ($NoConfirm) {
            $installCmd += " --accept-package-agreements --accept-source-agreements"
        }
        Write-Host "Installing package: $p"
        Write-Host "Running: $installCmd"
        & powershell -Command $installCmd
    }
}

if ($S) {
    # Direct install mode (no search)
    Install-Packages -Pkgs $PackagesToInstall -NoConfirm:$NoConfirm
    if ($LogOutput) {
        # Just log the installed packages - no search results here
        # In CSV mode, produce a simple CSV with one column "InstalledPackages"
        if ($Format -eq 'csv') {
            "InstalledPackages" | Out-File $logFilePath -Encoding UTF8
            foreach ($p in $PackagesToInstall) {
                $p | Out-File $logFilePath -Append -Encoding UTF8
            }
        } else {
            # txt mode
            "Installed packages:" | Out-File $logFilePath -Encoding UTF8
            $PackagesToInstall | Out-File $logFilePath -Append -Encoding UTF8
        }
        Write-Host "Log saved to $logFilePath"
    }
    exit 0
} else {
    # Search mode
    Write-Host "Searching for '$searchTerm'..."
    $searchOutput = winget search $searchTerm 2>$null
    if (-not $searchOutput -or $searchOutput.Count -le 2) {
        Write-Host "No results found for '$searchTerm'."
        exit 0
    }

    # The output format typically looks like this:
    # Name              Id              Version   Match           Source
    # -----             --              -------   -----           ------
    # Vim Cheat Sheet   9WZDNCRDMCWR    Unknown   (maybe tags)    msstore
    # Vim               vim.vim         9.1.0821                winget
    #
    # We'll parse this into a structured array.
    # First, find the header line and the line of dashes below it:
    $headerLine = $searchOutput[0].TrimEnd()
    $dividerLine = $searchOutput[1]

    # Identify column indexes by reading header
    # Split by spaces is tricky because names may have spaces.
    # Instead, we will rely on fixed column positions by analyzing the divider line.
    # We know columns: Name, Id, Version, Match, Source
    # Let's find the column positions by matching header words.
    # We'll assume these columns always appear in the same order.

    $headerParts = $headerLine -split '\s{2,}' # split on two or more spaces
    # headerParts should contain ["Name", "Id", "Version", "Match", "Source"]

    # To find exact column positions, we can find the index of each header word in the header line.
    # But this may fail if name has spaces. However, the header line is well-aligned with multiple spaces.
    # We'll do this:
    # Use regex to match columns. The header is typically aligned:
    # Name<spaces>Id<spaces>Version<spaces>Match<spaces>Source
    #
    # We know there are 5 columns. We can also attempt a column-based extraction by using the divider line.
    # Each column alignment can be derived from the divider line positions.

    # Let's find column start indexes by scanning dividerLine for sequences of '-'
    # Actually, it's easier just to rely on -split with multiple spaces and trust stable column alignment.
    # We'll first parse using a heuristic: columns are separated by at least two spaces.
    # This will work if winget output is stable, which it generally is.

    # Data lines start from index 2 onwards.
    $dataLines = $searchOutput[2..($searchOutput.Count-1)]

    # Parse each data line similarly by splitting on two or more spaces
    $parsedResults = foreach ($line in $dataLines) {
        $cols = $line -split '\s{2,}'
        if ($cols.Count -eq 5) {
            [PSCustomObject]@{
                Name    = $cols[0].Trim()
                Id      = $cols[1].Trim()
                Version = $cols[2].Trim()
                Match   = $cols[3].Trim()
                Source  = $cols[4].Trim()
            }
        } elseif ($cols.Count -eq 4) {
            # Sometimes Match column might be empty
            # Let's assume that if Match is empty, we have Name, Id, Version, Source only
            # In that case, insert an empty Match
            [PSCustomObject]@{
                Name    = $cols[0].Trim()
                Id      = $cols[1].Trim()
                Version = $cols[2].Trim()
                Match   = ""
                Source  = $cols[3].Trim()
            }
        }
        else {
            # If parsing fails, skip this line
            $null
        }
    }

    # Filter out null results
    $parsedResults = $parsedResults | Where-Object { $_ -ne $null }

    # Add a pkg_number (index) column
    $i = 1
    $parsedResults = $parsedResults | ForEach-Object {
        $_ | Add-Member -NotePropertyName pkg_number -NotePropertyValue $i
        $i++
        $_
    }

    # Display results to user
    $table = $parsedResults | Select-Object pkg_number,Name,Id,Version,Match,Source
    $table | Format-Table | Out-Host

    # Logging the search results if requested
    if ($LogOutput) {
        if ($Format -eq 'csv') {
            $table | Export-Csv -Path $logFilePath -NoTypeInformation -Encoding UTF8
        } else {
            # txt format: just output the table as is
            $tableStr = ($table | Format-Table | Out-String)
            $tableStr | Out-File $logFilePath -Encoding UTF8
        }
        Write-Host "Search results logged to $logFilePath"
    }

    # Prompt user to select packages
    Write-Host "Enter numbers or ranges (e.g. '1 3 5-7') of packages to install. Press Enter to skip:"
    $selection = Read-Host "Selection"
    if ([string]::IsNullOrWhiteSpace($selection)) {
        Write-Host "No packages selected. Exiting."
        exit 0
    }

    # Parse the selection input
    # Split by space, and for each token either parse as a number or a range x-y
    $installNumbers = New-Object System.Collections.Generic.List[int]
    foreach ($token in $selection -split '\s+') {
        if ($token -match '^\d+$') {
            # single number
            $installNumbers.Add([int]$token)
        } elseif ($token -match '^(\d+)-(\d+)$') {
            # range
            $start = [int]$Matches[1]
            $end = [int]$Matches[2]
            if ($end -ge $start) {
                for ($n=$start; $n -le $end; $n++) {
                    $installNumbers.Add($n)
                }
            }
        }
    }

    $installNumbers = $installNumbers | Sort-Object -Unique
    if ($installNumbers.Count -eq 0) {
        Write-Host "No valid selections made. Exiting."
        exit 0
    }

    # Get the corresponding packages (Id is likely the best to install with)
    $selectedPackages = $parsedResults | Where-Object { $installNumbers -contains $_.pkg_number } | Select-Object -ExpandProperty Id

    if (-not $selectedPackages) {
        Write-Host "No packages found for the selected indices."
        exit 0
    }

    # Install selected packages
    Install-Packages -Pkgs $selectedPackages -NoConfirm:$NoConfirm

    # Optionally, we could also log the installed packages to the same file or a separate file.
    # Let's append installed packages info at the end of the log file if LogOutput is enabled.
    if ($LogOutput) {
        if ($Format -eq 'csv') {
            # Append installed packages as another section at the end
            # We'll just print them as lines. CSV doesn't support easy "append" of different schema easily
            Add-Content -Path $logFilePath "`n# Installed Packages"
            foreach ($p in $selectedPackages) {
                Add-Content -Path $logFilePath "$p"
            }
        } else {
            Add-Content -Path $logFilePath "`nInstalled Packages:"
            $selectedPackages | Out-File -FilePath $logFilePath -Append -Encoding UTF8
        }
    }
}
