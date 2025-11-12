#Invoke-Expression (& starship init powershell)
Invoke-Expression (& 'C:\Users\heini\.cargo\bin\starship.exe' init powershell --print-full-init | Out-String)
micromamba.exe shell hook -s powershell | Out-String | Invoke-Expression
# =====================================================================
# Ultra-fast profile: no installs or heavy imports at startup
# =====================================================================

# Fail fast for *your* code; imported modules can still handle their own errors
$ErrorActionPreference = 'Stop'

# Optional: disable PowerShell’s own update ping
$env:POWERSHELL_UPDATECHECK = 'Off'
$env:POWERSHELL_TELEMETRY_OPTOUT = 'true'

# --- Modules you commonly use (installed on demand; imported lazily) ---
$DevModules = @(
    # Light / UX
    'PSReadLine', 'posh-git', 'PSFzf', 'z', 'DockerCompletion',
    # Dev helpers
    'Pester', 'Plaster', 'PSDepend', 'PSFramework',
    # Sec / tooling
    'CredentialManager', 'PowerShellForGitHub', 'ThreadJob', 'PSScriptAnalyzer',
    # QoL
    'BurntToast', 'Evergreen', 'ClipboardText'
)
# NOTE: Exclude 'WindowsCompatibility' from auto-load; import it only when needed.

# ------------------------  On-demand bootstrap  ------------------------
function Bootstrap-DevShell {
<#
.SYNOPSIS
    One-time/bootstrap setup: package provider, gallery trust, and module installation.

.DESCRIPTION
    - Ensures NuGet provider and PowerShellGet are present.
    - Registers PSGallery as Trusted (no prompts).
    - Installs any modules from $DevModules that are missing (CurrentUser scope).

.NOTES
    Network-heavy. Run manually when provisioning a machine.
#>
    Write-Host "Bootstrapping dev shell..." -ForegroundColor Cyan

    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    }

    if (-not (Get-Module -ListAvailable -Name PowerShellGet)) {
        Install-Module -Name PowerShellGet -Scope CurrentUser -Force -SkipPublisherCheck
    }

    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $repo) {
        Register-PSRepository -Name PSGallery -SourceLocation "https://www.powershellgallery.com/api/v2" -InstallationPolicy Trusted
    } elseif ($repo.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    foreach ($m in $DevModules) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            try {
                Write-Host "Installing $m..." -ForegroundColor DarkCyan
                Install-Module -Name $m -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
            } catch {
                Write-Warning ("Failed to install {0}: {1}" -f $m, $_)
            }
        }
    }

    Write-Host "Bootstrap complete." -ForegroundColor Green
}

# ----------------------  Lazy / deferred imports  ----------------------
# Rely on PowerShell’s module autoloading. Do NOT import heavy modules here.
# If you want Terminal-Icons, defer it until the shell is idle so prompt appears first.

# Defer Terminal-Icons until the first idle tick (prompt shows instantly)
$script:tiSub = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
    try {
        if (Get-Module -ListAvailable -Name Terminal-Icons) {
            Import-Module Terminal-Icons -ErrorAction SilentlyContinue
        }
    } finally {
        # Unsubscribe only this handler
        if ($script:tiSub) { Unregister-Event -SubscriptionId $script:tiSub.Id -ErrorAction SilentlyContinue }
    }
}

# Optional: minimal, safe PSReadLine tweaks (PSReadLine is built-in on PS7)
if (Get-Module -ListAvailable -Name PSReadLine) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -HistoryNoDuplicates -HistorySearchCursorMovesToEnd
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}

# --------------------  Background weekly module update  ----------------
# Non-blocking: prompt shows immediately; update runs in background when due.
$UpdateStamp = Join-Path $env:USERPROFILE ".psprofile_update"
$DoUpdate   = -not (Test-Path $UpdateStamp) -or ((Get-Date) - (Get-Item $UpdateStamp).LastWriteTime).Days -ge 7
if ($DoUpdate) {
    Start-Job -Name 'WeeklyModuleUpdate' -ScriptBlock {
        try { Update-Module -ErrorAction SilentlyContinue } catch {}
        try { Set-Content -LiteralPath $using:UpdateStamp -Value (Get-Date) -Force } catch {}
    } | Out-Null
}

# ------------------------  Convenience functions  ---------------------
function Set-PathEntry {
<#
.SYNOPSIS
    Adds a directory to PATH (User or System), prepend or append.

.PARAMETER Path
    Directory to add.

.PARAMETER Scope
    User (default) or System.

.PARAMETER Prepend
    Put in front. Default behavior is append.
#>
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('User','System')][string]$Scope = 'User',
        [switch]$Prepend
    )
    $target = if ($Scope -eq 'System') { 'Machine' } else { 'User' }
    if ($Scope -eq 'System' -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning "Administrator privileges are required to modify the System PATH."
        return
    }
    $parts = [Environment]::GetEnvironmentVariable('PATH', $target) -split ';'
    if ($parts -contains $Path) { return }
    $new = if ($Prepend) { ,$Path + $parts } else { $parts + $Path }
    [Environment]::SetEnvironmentVariable('PATH', ($new -join ';').Trim(';'), $target)
}

function Use-WinCompat {
<#
.SYNOPSIS
    Import WindowsCompatibility only when explicitly needed (it is expensive).
#>
    if (-not (Get-Module -Name WindowsCompatibility -ListAvailable)) {
        Write-Host "WindowsCompatibility module not installed. Run: Install-Module WindowsCompatibility -Scope CurrentUser" -ForegroundColor Yellow
        return
    }
    if (-not (Get-Module -Name WindowsCompatibility)) {
        Import-Module WindowsCompatibility
    }
}

# ------------------------  Optional: timing switch  --------------------
# Set $env:PS_PROFILE_TIMING=1 before launching to see where time goes.
if ($env:PS_PROFILE_TIMING) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $script:timingSub = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
        try {
            $elapsed = $sw.Elapsed
            Write-Host ("[profile] ready in {0} ms" -f [math]::Round($elapsed.TotalMilliseconds)) -ForegroundColor DarkGray
        } finally {
            if ($script:timingSub) { Unregister-Event -SubscriptionId $script:timingSub.Id -ErrorAction SilentlyContinue }
        }
    }
}

# =====================================================================
# XDG Base Directory setup (for Windows)
# Makes Windows behave more like Linux in terms of config locations.
# =====================================================================
# =====================================================================
# XDG Base Directory setup (Windows session scope)
# =====================================================================

$XDGRoot = Join-Path $env:USERPROFILE ".xdg"

# Desired XDG locations
$xdgDirs = [ordered]@{
    XDG_CONFIG_HOME = Join-Path $XDGRoot "config"
    XDG_DATA_HOME   = Join-Path $XDGRoot "data"
    XDG_CACHE_HOME  = Join-Path $XDGRoot "cache"
}

# Ensure directories and export to current session (no parser errors)
foreach ($entry in $xdgDirs.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value)) {
        New-Item -ItemType Directory -Force -Path $entry.Value | Out-Null
    }
    Set-Item -Path ("Env:{0}" -f $entry.Key) -Value $entry.Value
}

<#  OPTIONAL: persist for the current user (uncomment to make global across apps)
foreach ($entry in $xdgDirs.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "User")
}
#>


# Optional: persist them for the user (uncomment if you want permanent)

# =====================================================================
# XDG-aware config helpers for Starship & Alacritty (Windows friendly)
# Paste below your XDG section and above the final starship init line.
# =====================================================================

# ---------- Internal utilities (lightweight, no imports) --------------
function Test-Cmd {
    param([Parameter(Mandatory)][string]$Name)
    try { $null -ne (Get-Command -Name $Name -ErrorAction Stop) } catch { $false }
}

function Get-BatExe {
    if (Test-Cmd bat)    { return 'bat' }
    if (Test-Cmd batcat) { return 'batcat' } # Linux/WSL compatibility
    return $null
}

function Get-Editor {
<#
.SYNOPSIS
    Return a usable editor command.
.PARAMETER Editor
    Optional explicit editor command name.
.NOTES
    Prefers: provided -> $env:EDITOR -> code -> subl -> notepad++ -> notepad
#>
    param([string]$Editor)
    $candidates = @()
    if ($Editor)         { $candidates += $Editor }
    if ($env:EDITOR)     { $candidates += $env:EDITOR }
    $candidates += 'code','codium','subl','notepad++','nvim','vim','notepad'
    foreach ($c in $candidates) {
        if (Test-Cmd $c) { return $c }
    }
    return 'notepad'
}

function Show-FilePretty {
<#
.SYNOPSIS
    Pretty-print a file with bat presets or fallback to cat.
.PARAMETER Path
    File to display.
.PARAMETER LineNumbers
    Adds 'numbers' to bat --style.
#>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$LineNumbers
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }
    $bat = Get-BatExe
    if ($bat) {
        $style = 'snip,header,grid'
        if ($LineNumbers) { $style += ',numbers' }
        $args = @(
            "--style=$style",
            '--paging=never',
            '--italic-text=always',
            '--force-colorization',
            '--squeeze-blank',
            '--squeeze-limit=2',
            '--terminal-width=-1',
            '--theme=gruvbox-dark',
            '--wrap=auto',
            $Path
        )
        & $bat @args
    } elseif (Test-Cmd cat) {
        # In PowerShell 'cat' is an alias for Get-Content. Use it to honor your request.
        cat -LiteralPath $Path
    } else {
        # Practically unreachable in PowerShell, but kept for completeness
        Get-Content -LiteralPath $Path
    }
}

function Ensure-ParentDir {
    param([Parameter(Mandatory)][string]$FilePath)
    $dir = Split-Path -LiteralPath $FilePath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}


function Git-PullAll {
<#
.SYNOPSIS
    Update all git repositories in the current working directory.

.DESCRIPTION
    Iterates through each subdirectory of the current location.
    If the subdirectory contains a `.git` folder, it:
      - Stashes changes
      - Pulls latest changes
      - Marks the directory as safe in global git config
    Returns to the original working directory after each update.

.EXAMPLE
    Git-PullAll
#>
    $currentDir = Get-Location

    Get-ChildItem -Directory | ForEach-Object {
        $repoDir = $_.FullName
        $gitPath = Join-Path $repoDir ".git"

        if (Test-Path $gitPath) {
            Write-Host "Updating $repoDir..." -ForegroundColor Cyan
            Set-Location $repoDir

            try {
                git stash push -u
                git pull
                git config --global --add safe.directory $repoDir
            }
            catch {
                Write-Warning ("Failed updating {0}: {1}" -f $repoDir, $_.Exception.Message)
            }

            Set-Location $currentDir
        }
        else {
            Write-Host "$repoDir is not a git repository." -ForegroundColor DarkGray
        }
    }
}
Set-Alias -Name gpa -Value Git-PullAll


function Invoke-PackageManagers {
<#
.SYNOPSIS
  List and/or upgrade packages installed via winget, Chocolatey, and Scoop.

.DESCRIPTION
  -List    : Prints three tables (one per manager) sorted by size (largest first).
  -Upgrade : Upgrades all packages using each manager's native command.
  -Manager : Optional filter ('winget','chocolatey','scoop','all'; default 'all').
  -DeepScan: For winget entries lacking EstimatedSize, attempt folder size on InstallLocation.
  -WhatIf  : Simulate the -Upgrade actions.

  Size methodology:
    * Scoop       -> size of $env:SCOOP\apps\<app>\current plus $env:SCOOP\persist\<app> (if present).
    * Chocolatey  -> size of $env:ChocolateyInstall\lib\<pkg>*.
    * winget      -> winget JSON list joined to registry Uninstall entries; uses EstimatedSize (KB) when present.
                     If -DeepScan and InstallLocation exists, compute directory size as a fallback.

.PARAMETER List
  Emit size-sorted tables for each detected package manager.

.PARAMETER Upgrade
  Upgrade packages for each detected manager. Respects -WhatIf.

.PARAMETER Manager
  Restrict to one manager: 'winget','chocolatey','scoop','all'. Default 'all'.

.PARAMETER DeepScan
  For winget items without EstimatedSize, compute size of InstallLocation (slower).

.PARAMETER Help
  Print a concise CLI-style help block with examples.

.EXAMPLE
  Invoke-PackageManagers -List

.EXAMPLE
  Invoke-PackageManagers -Upgrade -WhatIf

.EXAMPLE
  Invoke-PackageManagers -Manager scoop -List

.EXAMPLE
  Invoke-PackageManagers -List -DeepScan

.NOTES
  Requires: PowerShell 5+ on Windows; tools are optional and auto-detected.
  Running -Upgrade may require an elevated prompt for some packages.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [switch]$List,
        [switch]$Upgrade,
        [ValidateSet('winget','chocolatey','scoop','all')]
        [string]$Manager = 'all',
        [switch]$DeepScan,
        [Alias('h','help')][switch]$Help
    )

    # ---------- inline CLI help (heredoc) ----------
    if ($Help) {
@"
Usage:
  Invoke-PackageManagers [-List] [-Upgrade] [-Manager <winget|chocolatey|scoop|all>] [-DeepScan] [-WhatIf]

Actions:
  -List          Show installed packages grouped by manager, sorted by size (desc).
  -Upgrade       Update all packages (per available managers). Use -WhatIf to simulate.
  -Manager       Limit to a single manager (default: all).
  -DeepScan      For winget entries without EstimatedSize, compute folder size of InstallLocation (slower).

Examples:
  Invoke-PackageManagers -List
  Invoke-PackageManagers -Upgrade -WhatIf
  Invoke-PackageManagers -Manager scoop -List
  Invoke-PackageManagers -List -DeepScan

Notes:
  * Scoop size = apps\<name>\current + persist\<name> (if present).
  * Chocolatey size = ChocolateyInstall\lib\<pkg>* directories.
  * winget size = Registry EstimatedSize (KB) when present; -DeepScan may compute InstallLocation.
"@ | Write-Host
        return
    }

    # ---------- prerequisites / detection ----------
    $haveWinget     = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    $haveChoco      = [bool](Get-Command choco  -ErrorAction SilentlyContinue)
    $haveScoop      = [bool](Get-Command scoop  -ErrorAction SilentlyContinue)

    $targets = @()
    if ($Manager -in @('winget','all') -and $haveWinget)     { $targets += 'winget' }
    if ($Manager -in @('chocolatey','all') -and $haveChoco)  { $targets += 'chocolatey' }
    if ($Manager -in @('scoop','all') -and $haveScoop)       { $targets += 'scoop' }

    if (-not $targets) {
        Write-Warning "No supported package managers detected for -Manager '$Manager'."
        return
    }

    # ---------- helpers ----------
    function Get-DirSizeBytes {
        param([Parameter(Mandatory)][string]$Path)
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            $sum = 0L
            # Fast file-only summation, avoids directory objects
            Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $sum += $_.Length }
            return $sum
        } catch {
            return $null
        }
    }

    function Format-Size {
        param([long]$Bytes)
        if (-not $Bytes -or $Bytes -lt 0) { return "" }
        if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
        if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
        if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
        if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
        return ('{0} B' -f $Bytes)
    }

    function Get-UninstallRegistryRows {
        # Aggregate HKLM/HKCU (native and WOW6432) uninstall entries
        $roots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        )
        $rows = foreach ($root in $roots) {
            if (-not (Test-Path $root)) { continue }
            Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $p = Get-ItemProperty $_.PsPath -ErrorAction Stop
                    [pscustomobject]@{
                        DisplayName     = $p.DisplayName
                        DisplayVersion  = $p.DisplayVersion
                        Publisher       = $p.Publisher
                        InstallLocation = $p.InstallLocation
                        EstimatedSizeKB = $p.EstimatedSize
                        UninstallString = $p.UninstallString
                        PsPath          = $_.PsPath
                    }
                } catch { }
            }
        }
        $rows | Where-Object { $_.DisplayName }  # filter empties
    }

    # ---------- collectors per manager ----------
    $registry = $null
    $results  = @()

    if ('winget' -in $targets) {
        # Get winget installed (source winget only) as JSON
        $wingetJson = try {
            & winget list --source winget --include-unknown --accept-source-agreements --output json 2>$null
        } catch { $null }

        if ($wingetJson) {
            try { $wingetData = $wingetJson | ConvertFrom-Json } catch { $wingetData = $null }
        }

        if (-not $registry) { $registry = Get-UninstallRegistryRows }

        $wingetRows = @()
        if ($wingetData -and $wingetData.Sources) {
            # Newer winget JSON has .Sources[].Packages[]. Map both possible shapes.
            $apps = @()
            foreach ($src in $wingetData.Sources) {
                if ($src.Packages) { $apps += $src.Packages }
            }
            if (-not $apps -and $wingetData.Apps) { $apps = $wingetData.Apps }

            foreach ($a in $apps) {
                $name    = $a.Name      ?? $a.PackageName
                $id      = $a.Id        ?? $a.PackageIdentifier
                $version = $a.Version   ?? $a.InstalledVersion

                # Best-effort join to registry by DisplayName; fallback to contains/starts-with heuristics
                $regHit = $registry | Where-Object { $_.DisplayName -eq $name } |
                          Select-Object -First 1
                if (-not $regHit) {
                    $candidates = $registry | Where-Object {
                        $_.DisplayName -and (
                            $_.DisplayName -like "$name" -or
                            $_.DisplayName -like "$name *" -or
                            $_.DisplayName -like "* $name" -or
                            $_.DisplayName -like "*$name*"
                        )
                    }
                    # Heuristic: pick the candidate with the largest EstimatedSizeKB (if any)
                    if ($candidates) {
                        $regHit = $candidates | Sort-Object { $_.EstimatedSizeKB } -Descending | Select-Object -First 1
                    }
                }

                $sizeBytes = $null
                $path      = $null

                if ($regHit) {
                    $path = if ($regHit.InstallLocation -and (Test-Path $regHit.InstallLocation)) { $regHit.InstallLocation } else { $null }
                    if ($regHit.EstimatedSizeKB) {
                        $sizeBytes = [int64]$regHit.EstimatedSizeKB * 1024
                    } elseif ($DeepScan -and $path) {
                        $sizeBytes = Get-DirSizeBytes -Path $path
                    }
                }

                $wingetRows += [pscustomobject]@{
                    Manager   = 'winget'
                    Name      = $name
                    Id        = $id
                    Version   = $version
                    Path      = $path
                    SizeBytes = $sizeBytes
                    Size      = if ($sizeBytes) { Format-Size $sizeBytes } else { '' }
                }
            }
        }

        if ($wingetRows) { $results += $wingetRows }
    }

    if ('chocolatey' -in $targets) {
        $chocoRows = @()

        # Query Chocolatey list (local only, raw pipe-friendly)
        $chocoList = try { & choco list -lo -r 2>$null } catch { $null }
        # Each line typically: name|version
        $libRoot = $env:ChocolateyInstall
        if (-not $libRoot -or -not (Test-Path $libRoot)) { $libRoot = 'C:\ProgramData\chocolatey' }
        $libDir = Join-Path $libRoot 'lib'

        foreach ($line in ($chocoList -split "`r?`n")) {
            if (-not $line) { continue }
            $parts = $line -split '\|', 2
            $name = $parts[0].Trim()
            $ver  = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }

            # Package folder may be name or name.version; aggregate both
            $pkgDirs = Get-ChildItem -LiteralPath $libDir -Directory -Filter "$name*" -ErrorAction SilentlyContinue
            $sizeBytes = 0
            $pathShown = $null
            foreach ($d in $pkgDirs) {
                $pathShown = $d.FullName
                $bytes = Get-DirSizeBytes -Path $d.FullName
                if ($bytes) { $sizeBytes += $bytes }
            }

            $chocoRows += [pscustomobject]@{
                Manager   = 'chocolatey'
                Name      = $name
                Id        = $name
                Version   = $ver
                Path      = $pathShown
                SizeBytes = if ($sizeBytes -gt 0) { $sizeBytes } else { $null }
                Size      = if ($sizeBytes -gt 0) { Format-Size $sizeBytes } else { '' }
            }
        }

        if ($chocoRows) { $results += $chocoRows }
    }

    if ('scoop' -in $targets) {
        $scoopRows = @()
        $scoopRoot = $env:SCOOP
        if (-not $scoopRoot) { $scoopRoot = Join-Path $env:USERPROFILE 'scoop' }
        $appsRoot   = Join-Path $scoopRoot 'apps'
        $persistRoot= Join-Path $scoopRoot 'persist'

        # Prefer JSON for reliable parsing
        $scoopJson = try { & scoop list --json 2>$null } catch { $null }
        $apps = @()
        if ($scoopJson) {
            try { $apps = $scoopJson | ConvertFrom-Json } catch { $apps = @() }
        }
        if (-not $apps -or $apps.Count -eq 0) {
            # Fallback: list directories under apps
            $apps = (Get-ChildItem -LiteralPath $appsRoot -Directory -ErrorAction SilentlyContinue).Name |
                    ForEach-Object { [pscustomobject]@{ name=$_; version='(current)'} }
        }

        foreach ($a in $apps) {
            $name = $a.name
            $ver  = $a.version
            $curr = Join-Path (Join-Path $appsRoot $name) 'current'
            $persist = Join-Path $persistRoot $name

            $sizeBytes = 0
            $pathShown = $null
            if (Test-Path $curr)   { $sizeBytes += (Get-DirSizeBytes -Path $curr);   $pathShown = $curr }
            if (Test-Path $persist){ $sizeBytes += (Get-DirSizeBytes -Path $persist) }

            $scoopRows += [pscustomobject]@{
                Manager   = 'scoop'
                Name      = $name
                Id        = $name
                Version   = $ver
                Path      = if (Test-Path $curr) { $curr } elseif (Test-Path $persist) { $persist } else { $null }
                SizeBytes = if ($sizeBytes -gt 0) { $sizeBytes } else { $null }
                Size      = if ($sizeBytes -gt 0) { Format-Size $sizeBytes } else { '' }
            }
        }

        if ($scoopRows) { $results += $scoopRows }
    }

    # ---------- upgrade path ----------
    if ($Upgrade) {
        foreach ($t in $targets) {
            switch ($t) {
                'winget' {
                    $cmd = 'winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements'
                    if ($PSCmdlet.ShouldProcess('winget', "Upgrade all packages")) {
                        Write-Host "[winget] Upgrading..." -ForegroundColor Cyan
                        try { & winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements } catch {
                            Write-Warning "[winget] upgrade failed: $($_.Exception.Message)"
                        }
                    } else {
                        Write-Host "[winget] Would run: $cmd"
                    }
                }
                'chocolatey' {
                    $cmd = 'choco upgrade all -y'
                    if ($PSCmdlet.ShouldProcess('chocolatey', "Upgrade all packages")) {
                        Write-Host "[chocolatey] Upgrading..." -ForegroundColor Cyan
                        try { & choco upgrade all -y } catch {
                            Write-Warning "[chocolatey] upgrade failed: $($_.Exception.Message)"
                        }
                    } else {
                        Write-Host "[chocolatey] Would run: $cmd"
                    }
                }
                'scoop' {
                    # Update Scoop itself, then all apps
                    if ($PSCmdlet.ShouldProcess('scoop', "Update Scoop + all apps")) {
                        Write-Host "[scoop] Updating..." -ForegroundColor Cyan
                        try { & scoop update } catch { Write-Warning "[scoop] self-update failed: $($_.Exception.Message)" }
                        try { & scoop update * } catch { Write-Warning "[scoop] apps update failed: $($_.Exception.Message)" }
                    } else {
                        Write-Host "[scoop] Would run: scoop update; scoop update *"
                    }
                }
            }
        }
    }

    # ---------- listing / output ----------
    if ($List) {
        foreach ($t in $targets) {
            $block = $results | Where-Object { $_.Manager -eq $t } | Sort-Object SizeBytes -Descending
            $count = ($block | Measure-Object).Count
            Write-Host ""
            Write-Host "== $t (`$count=$count) ==" -ForegroundColor Green
            if ($count -eq 0) {
                Write-Host "(no entries found)" -ForegroundColor DarkYellow
                continue
            }
            $block | Select-Object Name, Version,
                                   @{n='Size';e={$_.Size}},
                                   @{n='Path';e={$_.Path}} |
                    Format-Table -AutoSize | Out-Host
        }
    }

    # Also return objects for further processing in pipelines, if desired
    return $results
}



# ---------- XDG helpers (use your existing $env:XDG_* if set) ----------
function Get-XDGDir {
<#
.SYNOPSIS
    Return the effective XDG directory (Config/Data/Cache) on Windows.
.PARAMETER Type
    Config | Data | Cache (default: Config)
#>
    param(
        [ValidateSet('Config','Data','Cache')]
        [string]$Type = 'Config'
    )
    switch ($Type) {
        'Config' { if ($env:XDG_CONFIG_HOME) { return $env:XDG_CONFIG_HOME }
                   if ($IsWindows) { return Join-Path $env:APPDATA '' } # %APPDATA%
                   return Join-Path $env:HOME '.config' }
        'Data'   { if ($env:XDG_DATA_HOME)   { return $env:XDG_DATA_HOME }
                   if ($IsWindows) { return Join-Path $env:LOCALAPPDATA '' }
                   return Join-Path $env:HOME '.local/share' }
        'Cache'  { if ($env:XDG_CACHE_HOME)  { return $env:XDG_CACHE_HOME }
                   if ($IsWindows) { return Join-Path $env:LOCALAPPDATA 'Cache' }
                   return Join-Path $env:HOME '.cache' }
    }
}

# ---------- Starship ---------------------------------------------------
function Resolve-StarshipConfigPath {
<#
.SYNOPSIS
    Compute the path Starship will use for its config on this host.
.DESCRIPTION
    Search precedence (first existing wins; otherwise first candidate to create):
      1) $XDG_CONFIG_HOME\starship.toml
      2) %APPDATA%\starship\config.toml
      3) $HOME\.config\starship.toml
.EXAMPLE
    Resolve-StarshipConfigPath
#>
    $candidates = @()
    # 1) XDG
    $xdg = Get-XDGDir -Type Config
    if ($xdg) { $candidates += (Join-Path $xdg 'starship.toml') }
    # 2) Windows APPDATA canonical location
    if ($IsWindows) { $candidates += (Join-Path $env:APPDATA 'starship\config.toml') }
    # 3) Fallback ~/.config
    $candidates += (Join-Path $env:HOME '.config\starship.toml')

    $existing = $candidates | Where-Object { Test-Path -LiteralPath $_ }
    if ($existing) { return ($existing | Select-Object -First 1) }
    # none exist: return first candidate as the place to create
    return ($candidates | Select-Object -First 1)
}

function Get-StarshipExe {
    $fromPath = (Get-Command starship -ErrorAction SilentlyContinue)?.Source
    if ($fromPath) { return $fromPath }
    $cargo = Join-Path $env:USERPROFILE '.cargo\bin\starship.exe'
    if (Test-Path $cargo) { return $cargo }
    return 'starship' # hope for PATH
}

function Starship-Config {
<#
.SYNOPSIS
    Show path, open, or print Starship config with smart fallbacks.
.PARAMETER Open
    Open the config in an editor (see -Editor).
.PARAMETER Editor
    Editor command (e.g., code, subl, notepad++, nvim). Defaults to $env:EDITOR or sensible fallback.
.PARAMETER PrintConfig
    Pretty-print the plain file with bat/cat; if neither usable, dumps merged config via 'starship print-config'.
.PARAMETER LineNumbers
    When printing with bat, append 'numbers' to --style.
.EXAMPLE
    Starship-Config            # prints the effective path
.EXAMPLE
    Starship-Config -Open -Editor code
.EXAMPLE
    Starship-Config -PrintConfig -LineNumbers
#>
    param(
        [switch]$Open,
        [string]$Editor,
        [switch]$PrintConfig,
        [switch]$LineNumbers
    )
    $path = Resolve-StarshipConfigPath

    if ($Open) {
        Ensure-ParentDir -FilePath $path
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType File -Path $path -Force | Out-Null }
        $ed = Get-Editor -Editor $Editor
        & $ed $path
        return
    }

    if ($PrintConfig) {
        # Prefer printing the file; if it doesn't exist or viewers fail, fallback to merged config
        if (Test-Path -LiteralPath $path) {
            try {
                Show-FilePretty -Path $path -LineNumbers:$LineNumbers
                return
            } catch { }  # swallow and fallback
        }
        $starship = Get-StarshipExe
        & $starship print-config
        return
    }

    # Default: just show the path
    Write-Output $path
}

Set-Alias -Name starconf -Value Starship-Config



# ---------- Alacritty --------------------------------------------------
function Resolve-AlacrittyConfigPath {
<#
.SYNOPSIS
    Compute the path Alacritty will use for its config on this host.
.DESCRIPTION
    Tries (in order), returning first that exists; else first TOML candidate to create:
      1) $XDG_CONFIG_HOME\alacritty\alacritty.toml
      2) %APPDATA%\alacritty\alacritty.toml
      3) $HOME\.config\alacritty\alacritty.toml
    If none exist, checks legacy YAML:
      4) same locations but alacritty.yml (legacy)
.EXAMPLE
    Resolve-AlacrittyConfigPath
#>
    $xdg = Get-XDGDir -Type Config
    $tomlCandidates = @()
    if ($xdg)          { $tomlCandidates += (Join-Path $xdg 'alacritty\alacritty.toml') }
    if ($IsWindows)    { $tomlCandidates += (Join-Path $env:APPDATA 'alacritty\alacritty.toml') }
    $tomlCandidates += (Join-Path $env:HOME '.config\alacritty\alacritty.toml')

    $yamlCandidates = $tomlCandidates.ForEach({ $_ -replace '\.toml$', '.yml' })

    $existing = @($tomlCandidates + $yamlCandidates) | Where-Object { Test-Path -LiteralPath $_ }
    if ($existing) { return ($existing | Select-Object -First 1) }
    return ($tomlCandidates | Select-Object -First 1) # prefer TOML going forward
}

function Alacritty-Config {
<#
.SYNOPSIS
    Show path, open, or print Alacritty config with bat/cat.
.PARAMETER Open
    Open the config in an editor (see -Editor).
.PARAMETER Editor
    Editor command (e.g., code, subl, notepad++, nvim).
.PARAMETER PrintConfig
    Pretty-print config with bat/cat (no merged view exists for Alacritty).
.PARAMETER LineNumbers
    When printing with bat, append 'numbers' to --style.
.EXAMPLE
    Alacritty-Config          # prints the effective path
.EXAMPLE
    Alacritty-Config -Open -Editor subl
.EXAMPLE
    Alacritty-Config -PrintConfig -LineNumbers
#>
    param(
        [switch]$Open,
        [string]$Editor,
        [switch]$PrintConfig,
        [switch]$LineNumbers
    )
    $path = Resolve-AlacrittyConfigPath

    if ($Open) {
        Ensure-ParentDir -FilePath $path
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType File -Path $path -Force | Out-Null }
        $ed = Get-Editor -Editor $Editor
        & $ed $path
        return
    }

    if ($PrintConfig) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Alacritty config not found. Expected: $path"
        }
        Show-FilePretty -Path $path -LineNumbers:$LineNumbers
        return
    }

    Write-Output $path
}

Set-Alias -Name alacconf -Value Alacritty-Config

# =====================================================================
#							Examples			                      #
# =====================================================================
## Show Paths commands:							   		      		  #
## 				Starship-Config                                       #
## 				Alacritty-Config                                      #
# =====================================================================
## Open in editor commands:				    					      #
## 				Starship-Config -Open -Editor code                    #
##				Alacritty-Config -Open -Editor subl                   #
# =====================================================================
## Print config commands (pretty):						     	      #
## 				Starship-Config -PrintConfig -LineNumbers             #
##				Alacritty-Config -PrintConfig -LineNumbers            #
# =====================================================================

Invoke-Expression (& 'C:\Users\heini\.cargo\bin\starship.exe' init powershell --print-full-init | Out-String)

#& 'C:\Users\heini\.cargo\bin\starship.exe'

function Show-ProfileSummary {
<#
.SYNOPSIS
    Displays profile_summary.md with bat if available, otherwise falls back to Get-Content.
#>
    $summaryPath = Join-Path $HOME "Documents\PowerShell\profile_summary.md"

    if (-not (Test-Path -LiteralPath $summaryPath)) {
        Write-Warning "Summary file not found at: $summaryPath"
        return
    }

    $bat = Get-Command bat -ErrorAction SilentlyContinue
    if ($bat) {
        & $bat --style="grid,header" --paging=never --italic-text=always `
               --force-colorization --squeeze-blank --squeeze-limit=2 `
               --terminal-width=-1 --theme=gruvbox-dark --wrap=auto $summaryPath
    } else {
        Get-Content -LiteralPath $summaryPath
    }
}
Set-Alias -Name profsum -Value Show-ProfileSummary

# =====================================================================
#				Overview of custom functions and aliases              #
# =====================================================================

function Show-CustomCommands {
<#
.SYNOPSIS
    Display user-defined functions and aliases.
#>
    Write-Host "`n=== Custom Functions ===" -ForegroundColor Cyan
    Get-Command -CommandType Function | Where-Object { $_.Source -eq '' } |
        Select-Object Name, Definition |
        Format-Table -AutoSize

    Write-Host "`n=== Custom Aliases ===" -ForegroundColor Cyan
    Get-Alias | Where-Object { $_.Options -notmatch 'ReadOnly|AllScope' } |
        Select-Object Name, Definition |
        Format-Table -AutoSize
}
Set-Alias -Name funcs -Value Show-CustomCommands


<#
===============================================================================
 PowerShell Profile – Summary (custom user profile)
===============================================================================
 Startup
   • Prompt: Starship initialized (keep ONE init line only).
   • Shell:  micromamba shell hook enabled for pwsh sessions.
   • Errors: $ErrorActionPreference = 'Stop' (fail fast).
   • Telemetry: POWERSHELL_UPDATECHECK=Off, POWERSHELL_TELEMETRY_OPTOUT=true.

 XDG (Windows)
   • Exports XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME to: $HOME\.xdg\...
   • Optional persistence to User env is present but commented out.

 Background maintenance
   • Weekly module update via Start-Job (non-blocking).
   • Stamp file: $HOME\.psprofile_update

 Lazy UX / Input
   • Terminal-Icons: Deferred import on first engine idle tick.
   • PSReadLine: History+plugin predictions, no duplicates; Tab => MenuComplete.

 One-time bootstrap (manual)
   Function: Bootstrap-DevShell
     - Ensures NuGet + PowerShellGet
     - PSGallery registered + trusted
     - Installs modules in $DevModules (CurrentUser)
   NOTE: Not auto-run; invoke manually when provisioning.

 PATH management
   Function: Set-PathEntry
     - Params:
         -Path       <string>  (required)
         -Scope      User|System (default: User; System requires admin)
         -Prepend    [switch]  (prepend vs append)
     - Behavior: Adds if missing; preserves ordering; trims delimiters.

 WindowsCompatibility (manual)
   Function: Use-WinCompat
     - Imports WindowsCompatibility only when requested.
     - Warns if module not installed.

 Config discovery & pretty printing utilities
   Helpers:
     Test-Cmd            -> true/false if command is available
     Get-BatExe          -> returns 'bat' or 'batcat' if available, else $null
     Get-Editor          -> resolves editor (arg > $env:EDITOR > code/subl/notepad++/nvim/vim/notepad)
     Show-FilePretty     -> pretty print with bat presets or fallback to cat/Get-Content
     Ensure-ParentDir    -> create parent directory for a file path if missing
     Get-XDGDir          -> resolves XDG Config/Data/Cache directory for this host

 Starship configuration
   Paths:
     Resolve-StarshipConfigPath -> first existing of:
       1) $XDG_CONFIG_HOME\starship.toml
       2) %APPDATA%\starship\config.toml
       3) $HOME\.config\starship.toml
     Get-StarshipExe            -> resolves starship path (PATH / Cargo default)
   Command: Starship-Config  (alias: starconf)
     -Open             [switch]  open config in editor
     -Editor <string>            editor command (code/subl/notepad++/nvim/...)
     -PrintConfig      [switch]  pretty-print file with bat/cat; if file missing,
                                 falls back to `starship print-config` (merged)
     -LineNumbers      [switch]  add 'numbers' to bat --style
   Examples:
     starconf
     starconf -Open -Editor code
     starconf -PrintConfig -LineNumbers

 Alacritty configuration
   Paths:
     Resolve-AlacrittyConfigPath -> prefers TOML:
       1) $XDG_CONFIG_HOME\alacritty\alacritty.toml
       2) %APPDATA%\alacritty\alacritty.toml
       3) $HOME\.config\alacritty\alacritty.toml
       (falls back to legacy *.yml if present)
   Command: Alacritty-Config  (alias: alacconf)
     -Open             [switch]  open config in editor
     -Editor <string>            editor command
     -PrintConfig      [switch]  pretty-print with bat/cat
     -LineNumbers      [switch]  add 'numbers' to bat --style
   Examples:
     alacconf
     alacconf -Open -Editor subl
     alacconf -PrintConfig -LineNumbers

 Aliases
   starconf  -> Starship-Config
   alacconf  -> Alacritty-Config

 Notes / Recommendations
   • Keep exactly one Starship init line (e.g., at end of file).
   • Bootstrap-DevShell is manual; run it once per machine as needed.
   • `bat` presets used when available:
       --style="snip,header,grid[,+numbers]" --paging=never --italic-text=always
       --force-colorization --squeeze-blank --squeeze-limit=2 --terminal-width=-1
       --theme=gruvbox-dark --wrap=auto
===============================================================================
#>
