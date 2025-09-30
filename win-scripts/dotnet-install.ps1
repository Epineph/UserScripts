#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install one or more WinGet packages by ID, from memory, a text file, or a CSV.

.DESCRIPTION
    This script provides two exported functions:

    1) Install-WinGetPackages
       - Iterates over package IDs and installs them with WinGet.
       - Sources: in-memory array (-Ids), a text file (-IdFile), or a CSV (-CsvPath -IdColumn).
       - Idempotent-ish: can skip already-installed packages (best-effort check via 'winget list').
       - Supports -DryRun, logging, and quiet installation options.

    2) Save-WinGetSearch
       - Runs 'winget search' and parses the tabular output into objects and optionally a CSV.
       - NOTE: The parser is intentionally simple and may break if WinGet output formatting changes.

.PARAMETER Ids
    One or more WinGet package IDs (e.g., 'Git.Git', 'Microsoft.PowerShell').

.PARAMETER IdFile
    Path to a text file containing one package ID per line. Empty/comment lines are ignored.

.PARAMETER CsvPath
    Path to a CSV file from which to read package IDs.

.PARAMETER IdColumn
    The column name in the CSV that contains the WinGet package IDs (default: 'Id').

.PARAMETER DryRun
    If set, show what would be installed without invoking WinGet.

.PARAMETER SkipIfInstalled
    If set, run a quick check with 'winget list' to skip IDs that appear already installed.

.PARAMETER Silent
    If set, pass '--silent' to 'winget install' (where supported).

.PARAMETER LogPath
    If provided, append a line-delimited JSON log of installation results.

.PARAMETER Term
    (Save-WinGetSearch) One or more terms to pass to 'winget search'.

.PARAMETER OutputCsv
    (Save-WinGetSearch) Optional path to write parsed search results as CSV.

.EXAMPLE
    # 1) In-memory list
    $ids = @('Git.Git','Microsoft.PowerShell','Microsoft.VisualStudioCode')
    Install-WinGetPackages -Ids $ids -SkipIfInstalled -Silent

.EXAMPLE
    # 2) From a text file (one ID per line)
    Install-WinGetPackages -IdFile 'C:\temp\winget-ids.txt' -SkipIfInstalled

.EXAMPLE
    # 3) From a CSV with a custom column for IDs
    Install-WinGetPackages -CsvPath 'C:\temp\packages.csv' -IdColumn 'WingetId' -DryRun

.EXAMPLE
    # 4) Save rough search results for later curation
    Save-WinGetSearch -Term 'python','git' -OutputCsv 'C:\temp\winget-search.csv'

.NOTES
    - WinGet can also import/export a JSON manifest of installed apps:
        winget export -o C:\temp\apps.json
        winget import -i C:\temp\apps.json --accept-package-agreements --accept-source-agreements
    - The 'already installed' check is conservative and based on 'winget list'.
      It is designed to be fast and avoid false positives, but remains best-effort.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Install-WinGetPackages {
    [CmdletBinding(DefaultParameterSetName='FromMemory', PositionalBinding=$false)]
    param(
        [Parameter(Mandatory=$true, ParameterSetName='FromMemory')]
        [string[]]$Ids,

        [Parameter(Mandatory=$true, ParameterSetName='FromFile')]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$IdFile,

        [Parameter(Mandatory=$true, ParameterSetName='FromCsv')]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$CsvPath,

        [Parameter(ParameterSetName='FromCsv')]
        [ValidateNotNullOrEmpty()]
        [string]$IdColumn = 'Id',

        [switch]$DryRun,
        [switch]$SkipIfInstalled,
        [switch]$Silent,

        [string]$LogPath
    )

    # --- local helper: read IDs from the chosen source and normalize ---
    function Resolve-Ids {
        param(
            [Parameter(Mandatory=$true)] [string]$ParameterSetName,
            [string[]]$Ids,
            [string]$IdFile,
            [string]$CsvPath,
            [string]$IdColumn
        )

        switch ($ParameterSetName) {
            'FromMemory' {
                $Ids
            }
            'FromFile' {
                Get-Content -LiteralPath $IdFile |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -and -not $_.StartsWith('#') } |
                    Sort-Object -Unique
            }
            'FromCsv' {
                $rows = Import-Csv -LiteralPath $CsvPath
                if (-not $rows) { return @() }
                if (-not ($rows | Get-Member -Name $IdColumn -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                    throw "CSV does not contain a column named '$IdColumn'."
                }
                $rows |
                    ForEach-Object { ($_.$IdColumn).ToString().Trim() } |
                    Where-Object { $_ } |
                    Sort-Object -Unique
            }
            default { @() }
        }
    }

    # --- local helper: conservative "is installed" check using winget list ---
    function Test-WinGetInstalled {
        param([Parameter(Mandatory=$true)][string]$Id)
        # Use '--exact' to reduce ambiguity; suppress progress bars; capture text
        $out = winget list --id $Id --exact 2>$null
        # Heuristic: if there is a data row under the header, the ID is present
        # Ignore decorative lines; look for the ID token itself.
        if ($out -match [regex]::Escape($Id)) { return $true }
        return $false
    }

    # --- local helper: install one package and return a result object ---
    function Invoke-WinGetInstall {
        param(
            [Parameter(Mandatory=$true)][string]$Id,
            [switch]$Silent
        )
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $args = @('install','--id', $Id, '--exact',
                  '--accept-package-agreements','--accept-source-agreements')
        if ($Silent) { $args += '--silent' }

        $stdout = ''
        $stderr = ''
        try {
            # Use & to invoke and capture streams
            $stdout = & winget @args 2>&1
            $exit   = $LASTEXITCODE
        }
        catch {
            $stderr = $_.Exception.Message
            $exit   = 1
        }
        finally { $sw.Stop() }

        [pscustomobject]@{
            Id        = $Id
            ExitCode  = $exit
            DurationS = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            Output    = $stdout
            Error     = $stderr
            Status    = if ($exit -eq 0) { 'Success' } else { 'Failed' }
        }
    }

    # --- assemble the worklist ---
    $workIds = Resolve-Ids -ParameterSetName $PSCmdlet.ParameterSetName `
                           -Ids $Ids -IdFile $IdFile -CsvPath $CsvPath -IdColumn $IdColumn

    if (-not $workIds -or $workIds.Count -eq 0) {
        Write-Host "No package IDs to process." -ForegroundColor Yellow
        return
    }

    Write-Host ("Packages to process: {0}" -f ($workIds -join ', ')) -ForegroundColor Cyan

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($id in $workIds) {
        if ($SkipIfInstalled) {
            if (Test-WinGetInstalled -Id $id) {
                $results.Add([pscustomobject]@{
                    Id        = $id
                    ExitCode  = 0
                    DurationS = 0
                    Output    = "Skipped (already installed)"
                    Error     = ''
                    Status    = 'Skipped'
                })
                continue
            }
        }

        if ($DryRun) {
            $results.Add([pscustomobject]@{
                Id        = $id
                ExitCode  = 0
                DurationS = 0
                Output    = "DryRun: winget install --id $id --exact --accept-* " + ($(if($Silent){"--silent"}else{""}))
                Error     = ''
                Status    = 'DryRun'
            })
            continue
        }

        $result = Invoke-WinGetInstall -Id $id -Silent:$Silent
        $results.Add($result)
    }

    # Optional: append JSONL log for machine-readable audit
    if ($LogPath) {
        foreach ($r in $results) {
            $json = $r | ConvertTo-Json -Depth 4 -Compress
            Add-Content -LiteralPath $LogPath -Value $json
        }
        Write-Host "Wrote log entries to $LogPath" -ForegroundColor DarkGray
    }

    # Emit results to pipeline for further processing (Format-Table, Export-Csv, etc.)
    $results
}

function Save-WinGetSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$Term,
        [string]$OutputCsv
    )
    # NOTE: This parser assumes the typical tabular layout:
    # Name  <spaces>  Id  <spaces>  Version  <spaces>  Source
    # It is a convenience tool, not a guaranteed stable API.
    $all = foreach ($t in $Term) {
        $raw = winget search $t 2>$null
        if (-not $raw) { continue }
        # Drop the first two header lines (title + separator)
        $lines = $raw | Select-Object -Skip 2
        foreach ($line in $lines) {
            if (-not $line -or $line.Trim() -eq '') { continue }
            # Split on 2+ spaces
            $parts = [regex]::Split($line, '\s{2,}') | Where-Object { $_ -ne '' }
            if ($parts.Count -ge 4) {
                [pscustomobject]@{
                    Name    = $parts[0]
                    Id      = $parts[1]
                    Version = $parts[2]
                    Source  = $parts[3]
                    Query   = $t
                }
            }
        }
    }

    if ($OutputCsv) {
        $all | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Saved $($all.Count) rows to $OutputCsv" -ForegroundColor Green
    }

    $all
}

Export-ModuleMember -Function Install-WinGetPackages, Save-WinGetSearch

