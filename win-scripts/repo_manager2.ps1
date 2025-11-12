<#
.SYNOPSIS
    Clones and updates repositories in parallel with configurable settings.
.DESCRIPTION
    This script performs parallel cloning of repositories and can update existing ones.
    Uses PowerShell jobs for parallel operations with configurable thread count.
.EXAMPLE
    .\RepoManager.ps1 -Operation CloneAndUpdate
    Clones missing repos and updates existing ones.
.EXAMPLE
    .\RepoManager.ps1 -Operation UpdateOnly -MaxThreads 8
    Only updates existing repos using 8 parallel threads.
.NOTES
    Author: Heini W. Johnsen
    Version: 2.1.0
    Requires: Git for Windows
#>

[CmdletBinding()]
param (
    [ValidateSet("CloneOnly", "UpdateOnly", "CloneAndUpdate")]
    [string]$Operation = "CloneAndUpdate",
    
    [int]$MaxThreads = 4,
    
    [string]$RepoRoot = "C:\Users\heini\repos"
)

# Define helper functions outside the begin/process blocks to make them available globally
function Update-Repository {
    param (
        [string]$Path,
        [string]$Name
    )

    try {
        Push-Location -Path $Path
        Write-Verbose "Updating $Name at $Path"
        
        # Stash local changes if any
        $hasChanges = (git status --porcelain) -ne $null
        if ($hasChanges) {
            git stash | Out-Null
        }

        # Fetch updates
        git fetch --all --prune | Out-Null

        # Get current branch
        $branch = git rev-parse --abbrev-ref HEAD

        # Pull changes
        $output = git pull origin $branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to update $Name`: $output"
            return $false
        }

        # Update submodules
        if (Test-Path -Path ".gitmodules") {
            git submodule update --init --recursive | Out-Null
        }

        # Restore stashed changes if any
        if ($hasChanges) {
            git stash pop | Out-Null
        }

        return $true
    }
    catch {
        Write-Warning "Error updating $Name`: $_"
        return $false
    }
    finally {
        Pop-Location
    }
}

function Invoke-RepositoryOperation {
    param (
        [hashtable]$Repo,
        [string]$OperationType,
        [string]$RepoRoot
    )

    $repoPath = Join-Path -Path $RepoRoot -ChildPath $Repo.Name

    switch ($OperationType) {
        "Clone" {
            if (-not (Test-Path -Path $repoPath)) {
                Write-Host "Cloning $($Repo.Name)..." -ForegroundColor Blue
                git clone --recurse-submodules $Repo.Url $repoPath 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Cloned $($Repo.Name) successfully" -ForegroundColor Green
                    return $true
                }
                return $false
            }
            return $true
        }
        
        "Update" {
            if (Test-Path -Path (Join-Path -Path $repoPath -ChildPath ".git")) {
                if (Update-Repository -Path $repoPath -Name $Repo.Name) {
                    Write-Host "Updated $($Repo.Name) successfully" -ForegroundColor Green
                    return $true
                }
                return $false
            }
            return $true
        }
    }
}

begin {
    # Configure repositories
    $repos = @(
        @{Name="alacritty"; Url="https://github.com/alacritty/alacritty.git"},
        @{Name="bat"; Url="https://github.com/sharkdp/bat.git"},
        @{Name="fd"; Url="https://github.com/sharkdp/fd.git"},
        @{Name="fzf"; Url="https://github.com/junegunn/fzf.git"},
        @{Name="ripgrep"; Url="https://github.com/BurntSushi/ripgrep.git"},
        @{Name="starship"; Url="https://github.com/starship/starship.git"},
        @{Name="vcpkg"; Url="https://github.com/microsoft/vcpkg.git"}
    )

    # Validate git installation
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "Git could not be found. Please install Git for Windows."
        exit 1
    }

    # Create repo directory if needed
    $null = New-Item -Path $RepoRoot -ItemType Directory -Force -ErrorAction SilentlyContinue

    # Initialize progress tracking
    $completed = 0
    $total = $repos.Count
    $startTime = Get-Date
}

process {
    # Process repositories in parallel batches
    $jobs = [System.Collections.Generic.List[object]]::new()
    $repoQueue = [System.Collections.Queue]::new($repos)

    while ($repoQueue.Count -gt 0 -or $jobs.Count -gt 0) {
        # Start new jobs if we have capacity
        while ($jobs.Count -lt $MaxThreads -and $repoQueue.Count -gt 0) {
            $repo = $repoQueue.Dequeue()
            
            $jobScript = {
                param($repo, $Operation, $RepoRoot)
                
                function Update-Repository {
                    param (
                        [string]$Path,
                        [string]$Name
                    )

                    try {
                        Push-Location -Path $Path
                        Write-Verbose "Updating $Name at $Path"

                        #Stash local changes if any

                        $hasChanges = (git status --porcelain) -ne $null
                        if ($hasChanges) {
                            git stash | Out-Null
                        }

                        # Get updates

                        git fetch --all --prune | Out-Null

                        # Get current branch

                        $branch = git rev-parse --abbrev-ref HEAD

                        # Pull changes

                        $output = git pull origin $branch 2>&1

                        if ($LASTEXITCODE -ne 0) {
                            Write-Warning "Failed to update $Name`: $output"
                            return $false

                        }

                        if ($hasChanges) {
                            git stash pop | Out-Null
                        }
                        return $true


                    }
                    catch {
                        Write-Warning "Error updating $Name`: $_"
                        return $false
                    }

                    finally {
                        Pop-Location
                    }
                }

                function Invoke-RepositoryOperation {
                    param (
                        [hashtable]$Repo,
                        [string]$OperationType
                    )

                    $repoPath = Join-Path -Path $RepoRoot -ChildPath $Repo.Name

                    switch ($OperationType) {
                        "Clone" {
                            if (-not (Test-Path -Path $repoPath)) {
                                Write-Host "Cloning $($Repo.Name)..." -ForegroundColor Blue

                                git clone --recurse-submodules $Repo.Url $repoPath 2>&1 | Out-Null

                                if ($LASTEXITCODE -eq 0) {
                                    Write-Host "Cloned $($Repo.Name) successfully" -ForegroundColor Green

                                    return $true
                                }
                                return $false
                            }
                            return $true
                        }
                        "Update" {
                            if (Test-Path -Path (Join-Path -Path $repoPath -ChildPath ".git")) {
                                if (Update-Repository -Path $repoPath -Name $Repo.Name) {
                                    Write-Host "Updated $($Repo.Name) successfully" -ForegroundColor Green

                                    return $true
                                }
                                return $false
                            }
                            return $true
                        }
                    }

                    $jobs = [System.Collections.Generic.List[object]]::new()
                    $repoQueue = [System.Collections.Queue]::new($repos)

                    while ($repoQueue.Count -gt 0 -or $jobs.Count -gt 0) {
                        while ($jobs.Count -lt $MaxThreads -and $repoQueue.Count -gt 0) {
                            $repo = $repoQueue.Dequeue()

                            $jobScript = {
                                param($repo, $Operation, $RepoRoot)
                                Invoke-RepositoryOperation -Repo $repo -OperationType $Operation
                            }

                            $job = Start-Job -ScriptBlock $jobScript -ArgumentList $repo, $Operation, $RepoRoot
                            $jobs.Add(@{
                                Job = $job
                                Name = $repo.Name
                                })
                        }

                        $completedJobs = $jobs | Where-Object { $_.Job.State -ne "Running" }
                        foreach ($completedJob in $completedJobs) {
                            $result = Receive-Job -Job $completedJob.Job
                            $jobs.Remove($completedJob)
                            $completed++

                            $elapsed = (Get-Date) - $startTime
                            $remaining = ($total - $completed) * ($elapsed.TotalSeconds / [Math]::Max(1, $completed))
                            Write-Progress -Activity "Processing repositories" -Status "$completed of $total completed" `
                                -PercentComplete ($completed / $total * 100) `
                                -SecondsRemaining $remaining
                            }

                            Start-Sleep -Milliseconds 200
                        }
                        $jobs | ForEach-Object { Remove-Job -Job $_.Job -Force }
                    }
                    end {
    Write-Host "`nRepository operations completed:`n" -ForegroundColor Cyan
    Write-Host "Total repositories processed: $total" -ForegroundColor White
    Write-Host "Successful operations: $completed" -ForegroundColor Green

    $elapsed = (Get-Date) - $startTime
    Write-Host "Total time: $($elapsed.ToString('hh\:mm\:ss'))`n" -ForegroundColor White

    Get-ChildItem -Path $RepoRoot | 
        Select-Object Name, LastWriteTime | 
        Format-Table -AutoSize |
        Out-Host
    }
}