#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Clones and/or updates a set of Git repositories in parallel with a configurable thread limit.

.DESCRIPTION
    - Supports three operations: CloneOnly, UpdateOnly, CloneAndUpdate.
    - Uses background jobs for parallelism; each job is self-contained and receives function definitions.
    - Detects local changes via `git status --porcelain` and stashes before pull; pops afterward.
    - Uses upstream tracking if available; otherwise skips pull with a warning.
    - Updates submodules after clone and (optionally) after update when .gitmodules exists.
    - Provides progress reporting and success/summary statistics.

.EXAMPLE
    .\RepoManager.ps1 -Operation CloneAndUpdate
    Clones missing repositories and updates existing ones.

.EXAMPLE
    .\RepoManager.ps1 -Operation UpdateOnly -MaxThreads 8 -Verbose
    Updates existing repositories using 8 parallel jobs with verbose logs.

.PARAMETER Operation
    CloneOnly        : Only clone repos that do not exist locally.
    UpdateOnly       : Only update repos that already exist locally.
    CloneAndUpdate   : Clone missing and update existing.

.PARAMETER MaxThreads
    Maximum number of simultaneous jobs (default: 4).

.PARAMETER RepoRoot
    Root directory under which repositories are (or will be) located.

.PARAMETER GitCmdPath
    Optional explicit path to the Git executable (e.g., C:\Program Files\Git\cmd\git.exe).
    If not provided, the job will attempt to use PATH. On Windows, it also tries common locations.

.NOTES
    Author  : Heini W. Johnsen (revised)
    Version : 2.2.0
    Requires: Git
#>

[CmdletBinding()]
param (
    [ValidateSet('CloneOnly','UpdateOnly','CloneAndUpdate')]
    [string]$Operation = 'CloneAndUpdate',

    [int]$MaxThreads = 4,

    [string]$RepoRoot = "C:\Users\heini\repos",

    [string]$GitCmdPath
)

begin {
    # --- Configuration: repositories to manage ---
    $repos = @(
    @{ Name = "Arch-Hyprland"; URL = "https://github.com/JaKooLit/Arch-Hyprland" }
    @{ Name = "asm-lsp"; URL = "https://github.com/bergercookie/asm-lsp.git" }
    @{ Name = "autotools-language-server"; URL = "https://github.com/Freed-Wu/autotools-language-server.git" }
    @{ Name = "awk-language-server"; URL = "https://github.com/Beaglefoot/awk-language-server.git" }
    @{ Name = "backup_scripts"; URL = "https://github.com/Epineph/backup_scripts.git" }
    @{ Name = "bacon"; URL = "https://github.com/Canop/bacon.git" }
    @{ Name = "bacon-ls"; URL = "https://github.com/crisidev/bacon-ls.git" }
    @{ Name = "bash-language-server"; URL = "https://github.com/bash-lsp/bash-language-server.git" }
    @{ Name = "bat"; URL = "https://github.com/sharkdp/bat.git" }
    @{ Name = "chainer-chemistry"; URL = "https://github.com/chainer/chainer-chemistry.git" }
    @{ Name = "CMake"; URL = "https://github.com/Kitware/CMake.git" }
    @{ Name = "crowbook"; URL = "https://github.com/lise-henry/crowbook.git" }
    @{ Name = "delta"; URL = "https://github.com/dandavison/delta.git" }
    @{ Name = "direnv"; URL = "https://github.com/direnv/direnv.git" }
    @{ Name = "dotbot"; URL = "https://github.com/anishathalye/dotbot.git" }
    @{ Name = "doxide"; URL = "https://github.com/lawmurray/doxide.git" }
    @{ Name = "doxygen"; URL = "https://github.com/doxygen/doxygen" }
    @{ Name = "dracula.nvim"; URL = "https://github.com/Mofiqul/dracula.nvim.git" }
    @{ Name = "fd"; URL = "https://github.com/sharkdp/fd.git" }
    @{ Name = "fidget.nvim"; URL = "https://github.com/j-hui/fidget.nvim.git" }
    @{ Name = "fzf"; URL = "https://github.com/junegunn/fzf.git" }
    @{ Name = "generate_install_command"; URL = "https://github.com/Epineph/generate_install_command" }
    @{ Name = "htmx-lsp"; URL = "https://github.com/ThePrimeagen/htmx-lsp.git" }
    @{ Name = "hydra-lsp"; URL = "https://github.com/Retsediv/hydra-lsp.git" }
    @{ Name = "ipykernel"; URL = "https://github.com/ipython/ipykernel" }
    @{ Name = "ipython"; URL = "https://github.com/ipython/ipython" }
    @{ Name = "jsoncpp"; URL = "https://github.com/open-source-parsers/jsoncpp.git" }
    @{ Name = "jupyter"; URL = "https://github.com/jupyter/jupyter" }
    @{ Name = "jupyter_client"; URL = "https://github.com/jupyter/jupyter_client" }
    @{ Name = "jupyter_core"; URL = "https://github.com/jupyter/jupyter_core" }
    @{ Name = "jupyterlab"; URL = "https://github.com/jupyterlab/jupyterlab" }
    @{ Name = "langserver"; URL = "https://github.com/nim-lang/langserver.git" }
    @{ Name = "lazygit"; URL = "https://github.com/jesseduffield/lazygit.git" }
    @{ Name = "libressl-3.9.2"; URL = "https://github.com/libressl-portable/portable.git" }
    @{ Name = "llvmlite"; URL = "https://github.com/numba/llvmlite.git" }
    @{ Name = "LSP"; URL = "https://github.com/sublimelsp/LSP.git" }
    @{ Name = "luau-lsp"; URL = "https://github.com/JohnnyMorganz/luau-lsp.git" }
    @{ Name = "manage_lvm_space"; URL = "https://github.com/Epineph/manage_lvm_space.git" }
    @{ Name = "markdown-oxide"; URL = "https://github.com/Feel-ix-343/markdown-oxide.git" }
    @{ Name = "mason.nvim"; URL = "https://github.com/mason-org/mason.nvim.git" }
    @{ Name = "mason-registry"; URL = "https://github.com/mason-org/mason-registry.git" }
    @{ Name = "MathJax"; URL = "https://github.com/mathjax/MathJax.git" }
    @{ Name = "MathJax-demos-node"; URL = "https://github.com/mathjax/MathJax-demos-node.git" }
    @{ Name = "MathJax-docs"; URL = "https://github.com/mathjax/MathJax-docs.git" }
    @{ Name = "mdBook"; URL = "https://github.com/rust-lang/mdBook.git" }
    @{ Name = "meson-python"; URL = "https://github.com/mesonbuild/meson-python.git" }
    @{ Name = "micromamba-releases"; URL = "https://github.com/mamba-org/micromamba-releases.git" }
    @{ Name = "move"; URL = "https://github.com/move-language/move.git" }
    @{ Name = "mutt-language-server"; URL = "https://github.com/neomutt/mutt-language-server.git" }
    @{ Name = "my_R_config"; URL = "https://github.com/Epineph/my_R_config.git" }
    @{ Name = "my_zshrc"; URL = "https://github.com/Epineph/my_zshrc" }
    @{ Name = "nelua-lsp"; URL = "https://github.com/codehz/nelua-lsp.git" }
    @{ Name = "nelua.vim"; URL = "https://github.com/stefanos82/nelua.vim.git" }
    @{ Name = "networkx"; URL = "https://github.com/networkx/networkx.git" }
    @{ Name = "next-ls"; URL = "https://github.com/elixir-tools/next-ls.git" }
    @{ Name = "nickel"; URL = "https://github.com/tweag/nickel.git" }
    @{ Name = "nil"; URL = "https://github.com/oxalica/nil.git" }
    @{ Name = "nimlsp"; URL = "https://github.com/PMunch/nimlsp.git" }
    @{ Name = "ninja"; URL = "https://github.com/ninja-build/ninja.git" }
    @{ Name = "nomad-lsp"; URL = "https://github.com/juliosueiras/nomad-lsp.git" }
    @{ Name = "numba"; URL = "https://github.com/numba/numba" }
    @{ Name = "nushell"; URL = "https://github.com/nushell/nushell.git" }
    @{ Name = "nvim_conf"; URL = "https://github.com/Epineph/nvim_conf.git" }
    @{ Name = "nvim-dap"; URL = "https://github.com/mfussenegger/nvim-dap.git" }
    @{ Name = "nvim-idris2"; URL = "https://github.com/ShinKage/nvim-idris2.git" }
    @{ Name = "nvim-jdtls"; URL = "https://github.com/mfussenegger/nvim-jdtls.git" }
    @{ Name = "ocaml"; URL = "https://github.com/ocaml/ocaml" }
    @{ Name = "onedrive"; URL = "https://github.com/abraunegg/onedrive.git" }
    @{ Name = "oniguruma"; URL = "https://github.com/defuz/oniguruma.git" }
    @{ Name = "openbabel"; URL = "https://github.com/openbabel/openbabel.git" }
    @{ Name = "openscad-language-server"; URL = "https://github.com/dzhu/openscad-language-server.git" }
    @{ Name = "openscad-LSP"; URL = "https://github.com/Leathong/openscad-LSP.git" }
    @{ Name = "oxc"; URL = "https://github.com/oxc-project/oxc.git" }
    @{ Name = "package_control"; URL = "https://github.com/wbond/package_control.git" }
    @{ Name = "Packages"; URL = "https://github.com/sublimehq/Packages.git" }
    @{ Name = "pandoc"; URL = "https://github.com/jgm/pandoc.git" }
    @{ Name = "papaja"; URL = "https://github.com/crsh/papaja.git" }
    @{ Name = "paru"; URL = "https://aur.archlinux.org/paru.git" }
    @{ Name = "pascal-language-server"; URL = "https://github.com/genericptr/pascal-language-server.git" }
    @{ Name = "PerlNavigator"; URL = "https://github.com/bscan/PerlNavigator.git" }
    @{ Name = "pest-ide-tools"; URL = "https://github.com/pest-parser/pest-ide-tools.git" }
    @{ Name = "phan"; URL = "https://github.com/phan/phan.git" }
    @{ Name = "phpactor"; URL = "https://github.com/phpactor/phpactor.git" }
    @{ Name = "please"; URL = "https://github.com/thought-machine/please.git" }
    @{ Name = "processing-sublime"; URL = "https://github.com/b-g/processing-sublime.git" }
    @{ Name = "qtconsole"; URL = "https://github.com/jupyter/qtconsole" }
    @{ Name = "rdkit"; URL = "https://github.com/rdkit/rdkit.git" }
    @{ Name = "re2c"; URL = "https://github.com/skvadrik/re2c.git" }
    @{ Name = "rhash"; URL = "https://github.com/rhash/RHash.git" }
    @{ Name = "ripgrep"; URL = "https://github.com/BurntSushi/ripgrep.git" }
    @{ Name = "rmarkdown"; URL = "https://github.com/rstudio/rmarkdown.git" }
    @{ Name = "rocks.nvim"; URL = "https://github.com/nvim-neorocks/rocks.nvim.git" }
    @{ Name = "rstudio-desktop-bin"; URL = "https://aur.archlinux.org/rstudio-desktop-bin.git" }
    @{ Name = "ryacas"; URL = "https://github.com/r-cas/ryacas.git" }
    @{ Name = "ScaffoldGraph"; URL = "https://github.com/UCLCheminformatics/ScaffoldGraph.git" }
    @{ Name = "semver"; URL = "https://github.com/semver/semver.git" }
    @{ Name = "shiny-examples"; URL = "https://github.com/rstudio/shiny-examples.git" }
    @{ Name = "slather"; URL = "https://github.com/SlatherOrg/slather.git" }
    @{ Name = "sublime"; URL = "https://github.com/JaredCubilla/sublime.git" }
    @{ Name = "SublimeAllAutocomplete"; URL = "https://github.com/alienhard/SublimeAllAutocomplete.git" }
    @{ Name = "swig"; URL = "https://github.com/swig/swig.git" }
    @{ Name = "syntect"; URL = "https://github.com/trishume/syntect.git" }
    @{ Name = "terminado"; URL = "https://github.com/jupyter/terminado" }
    @{ Name = "thorium-browser-bin"; URL = "https://aur.archlinux.org/thorium-browser-bin.git" }
    @{ Name = "tinytex"; URL = "https://github.com/yihui/tinytex.git" }
    @{ Name = "tree-sitter-phpdoc"; URL = "https://github.com/claytonrcarter/tree-sitter-phpdoc.git" }
    @{ Name = "UserScripts"; URL = "https://github.com/Epineph/UserScripts" }
    @{ Name = "vcpkg"; URL = "https://github.com/microsoft/vcpkg.git" }
    @{ Name = "vim-lsp"; URL = "https://github.com/prabirshrestha/vim-lsp.git" }
    @{ Name = "visual-studio-code-bin"; URL = "https://aur.archlinux.org/visual-studio-code-bin.git" }
    @{ Name = "WoeUSB-ng"; URL = "https://github.com/WoeUSB/WoeUSB-ng.git" }
    @{ Name = "xcbuild"; URL = "https://github.com/facebook/xcbuild.git" }
    @{ Name = "yay"; URL = "https://aur.archlinux.org/yay.git" }
    @{ Name = "zfsArch"; URL = "https://github.com/Epineph/zfsArch.git" }
    )
    # --- Pre-flight checks ---
    $gitCmd = if ($GitCmdPath) { $GitCmdPath } else { 'git' }

    if (-not (Get-Command $gitCmd -ErrorAction SilentlyContinue)) {
        Write-Error "Git was not found on PATH and no -GitCmdPath was provided. Please install Git or specify -GitCmdPath."
        break
    }

    # Ensure repo root exists
    $null = New-Item -Path $RepoRoot -ItemType Directory -Force -ErrorAction SilentlyContinue

    # --- Metrics / tracking ---
    $total       = $repos.Count
    $startTime   = Get-Date
    $completed   = 0
    $successes   = 0

    # --- Helper: serialize functions for jobs ---
    function New-FunctionBundle {
@'
function Write-RepoInfo {
    param([string]$Name, [string]$Message)
    Write-Host "[$Name] $Message"
}

function Get-GitExe {
    param([string]$GitCmdPath)
    if ($GitCmdPath -and (Test-Path -LiteralPath $GitCmdPath)) { return $GitCmdPath }
    if (Get-Command git -ErrorAction SilentlyContinue) { return 'git' }
    $candidates = @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "$env:ProgramFiles\Git\bin\git.exe",
        "$env:ProgramFiles(x86)\Git\cmd\git.exe"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    throw "Git executable not found in job environment. Provide -GitCmdPath."
}

function Test-HasLocalChanges {
    param([string]$Git, [string]$Path)
    Push-Location -LiteralPath $Path
    try {
        $lines = & $Git status --porcelain
        return ($lines.Count -gt 0)
    } finally { Pop-Location }
}

function Update-Repository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Git
    )
    Push-Location -LiteralPath $Path
    try {
        Write-Verbose "Updating '$Name' at '$Path'"

        $hasChanges = ( & $Git status --porcelain ).Count -gt 0
        if ($hasChanges) {
            Write-Verbose "Local changes detected in '$Name'; stashing."
            & $Git stash | Out-Null
        }

        & $Git fetch --all --prune | Out-Null

        $upstream = (& $Git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
        if (-not $upstream) {
            Write-Warning "No upstream set for '$Name'; skipping pull."
        } else {
            $pullOut = & $Git pull --ff-only 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Pull failed for '$Name': $pullOut"
                if ($hasChanges) { & $Git stash pop | Out-Null }
                return $false
            }
        }

        if (Test-Path -LiteralPath (Join-Path -Path $Path -ChildPath '.gitmodules')) {
            Write-Verbose "Updating submodules for '$Name'"
            & $Git submodule update --init --recursive | Out-Null
        }

        if ($hasChanges) {
            Write-Verbose "Restoring stashed changes in '$Name'"
            & $Git stash pop | Out-Null
        }
        return $true
    } catch {
        Write-Warning "Error updating '$Name': $($_)"
        return $false
    } finally {
        Pop-Location
    }
}

function Clone-Repository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Repo,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Git
    )
    $repoPath = Join-Path -Path $RepoRoot -ChildPath $Repo.Name
    if (-not (Test-Path -LiteralPath $repoPath)) {
        Write-Host "Cloning $($Repo.Name) ..." -ForegroundColor Blue
        $out = & $Git clone --recurse-submodules $Repo.Url $repoPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Clone failed for '$($Repo.Name)': $out"
            return $false
        }
        Write-Host "Cloned $($Repo.Name) successfully" -ForegroundColor Green
        return $true
    }
    return $true
}

function Invoke-RepositoryOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Repo,
        [Parameter(Mandatory)][string]$OperationType,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Git
    )
    $repoPath = Join-Path -Path $RepoRoot -ChildPath $Repo.Name

    switch ($OperationType) {
        'CloneOnly'    { return (Clone-Repository  -Repo $Repo -RepoRoot $RepoRoot -Git $Git) }
        'UpdateOnly'   {
            if (Test-Path -LiteralPath (Join-Path -Path $repoPath -ChildPath '.git')) {
                return (Update-Repository -Path $repoPath -Name $Repo.Name -Git $Git)
            } else {
                Write-Verbose "Skipping update for '$($Repo.Name)' (not cloned)."
                return $true
            }
        }
        'CloneAndUpdate' {
            $ok = Clone-Repository -Repo $Repo -RepoRoot $RepoRoot -Git $Git
            if (-not $ok) { return $false }
            if (Test-Path -LiteralPath (Join-Path -Path $repoPath -ChildPath '.git')) {
                return (Update-Repository -Path $repoPath -Name $Repo.Name -Git $Git)
            }
            return $true
        }
        default {
            Write-Warning "Unknown operation '$OperationType' for '$($Repo.Name)'."
            return $false
        }
    }
}
'@
}

    # Prepare serialized functions for the job
    $FunctionBundle = New-FunctionBundle

    # Queue and job storage
    $repoQueue = [System.Collections.Queue]::new()
    $repos | ForEach-Object { [void]$repoQueue.Enqueue($_) }

    $jobs = [System.Collections.ArrayList]::new()
}

process {
    while ($repoQueue.Count -gt 0 -or $jobs.Count -gt 0) {

        # Launch up to MaxThreads
        while ($jobs.Count -lt $MaxThreads -and $repoQueue.Count -gt 0) {
            $repo = $repoQueue.Dequeue()

            $job = Start-Job -Name $repo.Name -ScriptBlock {
                param(
                    [hashtable]$Repo,
                    [string]   $OperationType,
                    [string]   $RepoRoot,
                    [string]   $GitCmdPath,
                    [string]   $FunctionBundle,
                    [bool]     $VerboseOn
                )

                # Import functions
                Invoke-Expression $FunctionBundle

                # Respect -Verbose if requested
                if ($VerboseOn) { $script:VerbosePreference = 'Continue' }

                try {
                    $git = Get-GitExe -GitCmdPath $GitCmdPath
                    $ok  = Invoke-RepositoryOperation -Repo $Repo -OperationType $OperationType -RepoRoot $RepoRoot -Git $git
                    if ($ok) {
                        Write-Host "[$($Repo.Name)] OK" -ForegroundColor Green
                        return [pscustomobject]@{ Name = $Repo.Name; Success = $true }
                    } else {
                        Write-Host "[$($Repo.Name)] FAILED" -ForegroundColor Red
                        return [pscustomobject]@{ Name = $Repo.Name; Success = $false }
                    }
                } catch {
                    Write-Warning "[$($Repo.Name)] Exception: $($_)"
                    return [pscustomobject]@{ Name = $Repo.Name; Success = $false }
                }
            } -ArgumentList $repo, $Operation, $RepoRoot, $GitCmdPath, $FunctionBundle, ($PSBoundParameters.ContainsKey('Verbose'))

            [void]$jobs.Add($job)
        }

        # Collect completed jobs
        $finished = @()
        foreach ($j in $jobs) {
            if ($j.State -ne 'Running') { $finished += $j }
        }

        foreach ($fj in $finished) {
            $result = $null
            try {
                $result = Receive-Job -Job $fj -ErrorAction Stop
            } catch {
                # Ensure a result object even on Receive-Job error
                $result = [pscustomobject]@{ Name = $fj.Name; Success = $false }
            } finally {
                Remove-Job -Job $fj -Force -ErrorAction SilentlyContinue
                [void]$jobs.Remove($fj)
            }

            $completed++
            if ($result -and $result.Success) { $successes++ }

            # Progress estimation
            $elapsed   = (Get-Date) - $startTime
            $rate      = if ($completed -gt 0) { $elapsed.TotalSeconds / $completed } else { 0.0 }
            $remaining = [int][math]::Round(($total - $completed) * $rate, 0)

            $pct = if ($total -eq 0) { 100 } else { [int]([double]$completed / $total * 100) }

            Write-Progress -Activity "Processing repositories" `
                           -Status "$completed of $total completed" `
                           -PercentComplete $pct `
                           -SecondsRemaining $remaining
        }

        Start-Sleep -Milliseconds 150
    }
}

end {
    # Summary
    Write-Host "`nRepository operations completed:" -ForegroundColor Cyan
    Write-Host ("Total repositories:      {0}" -f $total)
    Write-Host ("Successful operations:    {0}" -f $successes) -ForegroundColor Green
    Write-Host ("Failed/Skipped (failure): {0}" -f ($total - $successes)) -ForegroundColor Yellow

    $elapsed = (Get-Date) - $startTime
    Write-Host ("Total time:               {0:hh\:mm\:ss}`n" -f $elapsed)

    # Directory snapshot (last write gives a quick sanity check)
    Get-ChildItem -Path $RepoRoot -Directory -ErrorAction SilentlyContinue |
        Select-Object Name, LastWriteTime |
        Sort-Object Name |
        Format-Table -AutoSize |
        Out-Host
}
