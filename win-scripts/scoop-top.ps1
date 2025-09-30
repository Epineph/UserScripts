#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Rank Scoop packages by "popularity" (GitHub stars).

.DESCRIPTION
  Scans installed Scoop buckets for manifests (*.json), extracts the upstream
  GitHub repository from 'homepage', 'autoupdate.github', or download 'url'
  fields, queries the GitHub REST API for stargazer counts, and reports the
  top-N packages (default N=50).

  Notes:
    - Scoop does not expose install/download counts. We use GitHub stars as a
      pragmatic proxy, similar to community listings.
    - Non-GitHub packages are skipped (no reliable public metric).
    - Results are cached per repo to reduce API calls.

.PARAMETER Limit
  Number of top entries to show. Default: 50.

.PARAMETER SaveCsv
  Optional path to write the ranked list as CSV.

.PARAMETER GitHubToken
  Optional GitHub token to raise rate limits. A fine-grained PAT with "public_repo"
  (read) is sufficient for public metadata.

.PARAMETER RebuildCache
  Ignore existing cache and refetch all repo stats.

.EXAMPLE
  .\scoop-top.ps1
  # Show top 50 packages (default) across installed buckets.

.EXAMPLE
  .\scoop-top.ps1 -Limit 100 -SaveCsv "$HOME\Desktop\scoop-top.csv"

.EXAMPLE
  $env:GITHUB_TOKEN="ghp_XXXXXXXX..." ; .\scoop-top.ps1 -GitHubToken $env:GITHUB_TOKEN

.LIMITATIONS
  Popularity ≠ quality. Stars can be biased by age/visibility. Use as triage,
  not gospel.

#>

param(
  [int]$Limit = 50,
  [string]$SaveCsv,
  [string]$GitHubToken,
  [switch]$RebuildCache
)

# ----------------------------- Configuration ---------------------------------
$ErrorActionPreference = 'Stop'

# Cache file for repo → stars mapping
$CacheDir  = Join-Path $HOME ".cache"
$CacheFile = Join-Path $CacheDir "scoop-top-stars-cache.json"

# Respect a typical Scoop root if environment var is missing
$ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $HOME "scoop" }
$BucketsRoot = Join-Path $ScoopRoot "buckets"

# GitHub REST headers
$GitHubHeaders = @{
  'User-Agent' = 'scoop-top-stars'
  'Accept'     = 'application/vnd.github+json'
}
if ($GitHubToken) {
  $GitHubHeaders['Authorization'] = "token $GitHubToken"
}

# ------------------------------- Utilities -----------------------------------
function Show-HelpText {
  $help = @"
Scoop Top (by GitHub Stars)
---------------------------
Usage:
  pwsh .\scoop-top.ps1 [-Limit 50] [-SaveCsv <path>] [-GitHubToken <token>] [-RebuildCache]

Examples:
  .\scoop-top.ps1
  .\scoop-top.ps1 -Limit 100 -SaveCsv "$HOME\Desktop\scoop-top.csv"
  $env:GITHUB_TOKEN="ghp_xxx"; .\scoop-top.ps1 -GitHubToken $env:GITHUB_TOKEN

Interpretation:
  - Stars are used as a proxy for popularity (Scoop does not publish installs).
  - Only manifests whose repo can be resolved to GitHub are included.
"@
  # Prefer user's bat style; fall back gracefully
  $bat = (Get-Command bat -ErrorAction SilentlyContinue)
  if ($bat) {
    $help | & $bat --set-terminal-title --style="grid,header,snip" --squeeze-blank --theme="Dracula" --pager="Never" --decorations="always" --italic-text="always" --color="always"
  } else {
    $help | Write-Output
  }
}

function Assert-Prereqs {
  if (-not (Test-Path $BucketsRoot)) {
    throw "Buckets directory not found at '$BucketsRoot'. Is Scoop installed and buckets added?"
  }
  if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }
}

# Extract "owner/repo" from a URL if it looks like GitHub
function Try-ParseGitHubRepo([string]$uri) {
  if ([string]::IsNullOrWhiteSpace($uri)) { return $null }
  # Match: https://github.com/owner/repo (possibly with extra segments)
  $m = [regex]::Match($uri, 'https?://github\.com/([^/\s]+)/([^/\s#]+)')
  if ($m.Success) { return "{0}/{1}" -f $m.Groups[1].Value, $m.Groups[2].Value }
  return $null
}

# Extract GitHub repo from manifest object and URL fields
function Get-GitHubRepoFromManifest($manifest) {
  $candidates = @()

  if ($manifest.homepage) { $candidates += $manifest.homepage }
  if ($manifest.autoupdate -and $manifest.autoupdate.github) { $candidates += $manifest.autoupdate.github }

  # url may be a string or an array or a hashtable for arch
  if ($manifest.url) {
    switch ($manifest.url.GetType().Name) {
      'String' { $candidates += $manifest.url }
      'Object[]' { $candidates += $manifest.url }
      default {
        # Hashtable like: {64bit: "...", 32bit: "..."}
        try { $candidates += $manifest.url.PSObject.Properties.Value } catch {}
      }
    }
  }

  foreach ($u in ($candidates | Where-Object { $_ })) {
    $repo = Try-ParseGitHubRepo $u
    if ($repo) { return $repo }
  }
  return $null
}

# Load/save cache
function Load-RepoCache {
  if (-not (Test-Path $CacheFile)) { return @{} }
  try {
    $json = Get-Content -Raw -LiteralPath $CacheFile | ConvertFrom-Json
    return @{} + $json  # convert PSCustomObject → hashtable
  } catch { return @{} }
}
function Save-RepoCache([hashtable]$cache) {
  $cache.GetEnumerator() | Sort-Object Name | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $CacheFile -Encoding UTF8
}

# Query GitHub for stars; use cache when possible
function Get-RepoStars([string]$ownerRepo, [hashtable]$cache) {
  if (-not $ownerRepo) { return $null }
  if (-not $RebuildCache -and $cache.ContainsKey($ownerRepo)) { return [int]$cache[$ownerRepo] }

  $uri = "https://api.github.com/repos/$ownerRepo"
  try {
    $resp = Invoke-RestMethod -Uri $uri -Headers $GitHubHeaders -Method GET -TimeoutSec 20
    $stars = [int]$resp.stargazers_count
    $cache[$ownerRepo] = $stars
    return $stars
  } catch {
    # Rate-limit or 404: cache as 0 to avoid hammering; caller can RebuildCache later.
    $cache[$ownerRepo] = 0
    return 0
  }
}

# ------------------------------ Main routine ---------------------------------
try {
  Assert-Prereqs

  # Gather manifests from installed buckets
  $bucketDirs = Get-ChildItem -Path $BucketsRoot -Directory -ErrorAction SilentlyContinue
  if (-not $bucketDirs) { throw "No buckets found under '$BucketsRoot'." }

  $manifests = foreach ($bd in $bucketDirs) {
    $bucketName = $bd.Name
    $manifestDir = Join-Path $bd.FullName "bucket"
    if (-not (Test-Path $manifestDir)) { $manifestDir = $bd.FullName } # some buckets keep *.json at root
    Get-ChildItem -Path $manifestDir -Filter *.json -File -Recurse -ErrorAction SilentlyContinue |
      ForEach-Object {
        [PSCustomObject]@{
          Bucket       = $bucketName
          ManifestPath = $_.FullName
          AppName      = $_.BaseName
        }
      }
  }

  if (-not $manifests) { throw "No manifests discovered. Are your buckets empty?" }

  # Parse JSON & resolve GitHub repos
  $resolved = foreach ($m in $manifests) {
    try {
      $obj = Get-Content -LiteralPath $m.ManifestPath -Raw | ConvertFrom-Json
    } catch {
      continue
    }
    $repo = Get-GitHubRepoFromManifest $obj
    if ($repo) {
      [PSCustomObject]@{
        AppName  = $m.AppName
        Bucket   = $m.Bucket
        Repo     = $repo
        Homepage = $obj.homepage
        Desc     = $obj.description
      }
    }
  }

  # Deduplicate AppName+Bucket (keep first)
  $resolved = $resolved | Group-Object Bucket,AppName | ForEach-Object { $_.Group | Select-Object -First 1 }

  # Map repo → stars with caching
  $repoCache = if ($RebuildCache) { @{} } else { Load-RepoCache }
  $ranked = $resolved |
  ForEach-Object {
    $stars = Get-RepoStars -ownerRepo $_.Repo -cache $repoCache
    [PSCustomObject]@{
      Stars   = $stars
      App     = $_.AppName
      Bucket  = $_.Bucket
      Repo    = "https://github.com/$($_.Repo)"
      Home    = $_.Homepage
      Desc    = $_.Desc
    }
  } |
  Sort-Object -Property @{Expression='Stars';Descending=$true}, @{Expression='App';Descending=$false}



  Save-RepoCache $repoCache

  $top = $ranked | Select-Object -First $Limit

  # Output: pretty table
  $top | Format-Table -AutoSize Stars, App, Bucket, Repo

  if ($SaveCsv) {
    $top | Export-Csv -NoTypeInformation -Path $SaveCsv -Encoding UTF8
    Write-Host "`nCSV written to: $SaveCsv"
  }

} catch {
  Write-Error $_.Exception.Message
  Show-HelpText
  exit 1
}
