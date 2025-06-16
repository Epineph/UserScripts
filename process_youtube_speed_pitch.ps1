<#
.SYNOPSIS
    Ensures required tools are installed, then downloads a video, applies pitch shift
    and optional speed change, re-encodes for quality, and remuxes into an MP4.

.DESCRIPTION
    This script will:
      1. Check for Chocolatey and Scoop; install Chocolatey if neither exists.
      2. Install missing dependencies (yt-dlp, ffmpeg, librubberband) via Chocolatey or Scoop.
      3. Reload the environment if any tools were installed.
      4. Download the specified video via yt-dlp.
      5. Detect the actual downloaded file (regardless of extension).
      6. Apply pitch shift and time-stretch in a single ffmpeg pass using rubberband and setpts.
      7. Re-encode video (x264) and audio (AAC) with high-quality settings.
      8. Output a synchronized MP4 with embedded audio title metadata.

    If no pitch shift is desired, simply omit -Semitones or set it to 0.

.PARAMETER Url
    Video URL to download (e.g., YouTube link).

.PARAMETER Output
    Base name (with or without extension) for yt-dlp output.

.PARAMETER PitchShift
    'Up' or 'Down' semitones. Ignored if Semitones = 0. Default = 'Up'.

.PARAMETER Semitones
    Number of semitones to shift. Default = 0 (no pitch shift).

.PARAMETER SpeedFactor
    Time-stretch factor (<1 slows, >1 speeds). Default = 1.0.

.PARAMETER Title
    Audio title metadata for the final MP4.

.PARAMETER VideoName
    Base name for the final output file (without extension).

.PARAMETER VideoCRF
    CRF for x264 encoding (0–51). Default = 18.

.PARAMETER VideoPreset
    x264 preset. Default = 'slow'.

.PARAMETER AudioBitrate
    AAC bitrate (e.g., '320k'). Default = '320k'.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Output,
    [ValidateSet('Up','Down')][string]$PitchShift = 'Up',
    [int]$Semitones = 0,
    [ValidateRange(0.01,10.0)][double]$SpeedFactor = 1.0,
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$VideoName,
    [ValidateRange(0,51)][int]$VideoCRF = 18,
    [ValidateSet('ultrafast','superfast','veryfast','faster','fast','medium','slow','slower','veryslow')][string]$VideoPreset = 'slow
',
    [ValidatePattern('^\d+k$')][string]$AudioBitrate = '320k'
)

# Track whether we installed any dependencies
$depsInstalled = $false

function Install-Choco {
    Write-Host 'Installing Chocolatey...' -ForegroundColor Cyan
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $global:depsInstalled = $true
}

function Ensure-Packager {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue) -and -not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Install-Choco
    }
}

function Install-Tool {
    param(
        [string]$Command,
        [string]$ChocoName,
        [string]$ScoopName
    )
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "Installing $Command via Chocolatey..." -ForegroundColor Cyan
            choco install $ChocoName -y --no-progress
            $global:depsInstalled = $true
        } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
            Write-Host "Installing $Command via Scoop..." -ForegroundColor Cyan
            scoop install $ScoopName
            $global:depsInstalled = $true
        } else {
            Write-Error "No package manager found to install $Command."
            exit 1
        }
    }
}

# Ensure package manager exists and install dependencies
Ensure-Packager
Install-Tool -Command yt-dlp     -ChocoName yt-dlp     -ScoopName yt-dlp
Install-Tool -Command ffmpeg     -ChocoName ffmpeg     -ScoopName ffmpeg
Install-Tool -Command rubberband -ChocoName librubberband -ScoopName rubberband

# Reload environment if needed
if ($depsInstalled) {
    Write-Host 'Reloading environment variables...' -ForegroundColor Cyan
    RefreshEnv
}

# 1. Download via yt-dlp
Write-Host "Downloading '$Url' to '$Output'..." -ForegroundColor Cyan
yt-dlp -f 'bv*[height<=1080]+ba/best' -o "$Output" "$Url"

# 2. Locate downloaded file
$base = [IO.Path]::GetFileNameWithoutExtension($Output)
$file = Get-ChildItem -Filter "$base.*" -File |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $file) { Write-Error "Cannot find '$base.*'"; exit 1 }
Write-Host "Using file: $($file.Name)" -ForegroundColor Green

# 3. Compute filter parameters
$semi = if ($Semitones -eq 0) { 0 } elseif ($PitchShift -eq 'Down') { -$Semitones } else { $Semitones }
$pitchRatio = [math]::Pow(2, $semi/12)
$vFactor = 1.0/$SpeedFactor
$speedLabel = ($SpeedFactor.ToString([Globalization.CultureInfo]::InvariantCulture)).Replace('.', 'p') + 'x'

if ($Semitones -eq 0) {
    $namePart = "speed-$speedLabel"
} else {
    $namePart = "shifted-$($PitchShift.ToLower())-${Semitones}st-$speedLabel"
}
$outFile = "${VideoName}-${namePart}.mp4"

# Build filter_complex
$vf = "setpts=PTS*${vFactor}"
$af = "rubberband=tempo=${SpeedFactor}:pitch=${pitchRatio}"
$filter = "[0:v]$vf[v];[0:a]$af[a]"

Write-Host "Processing and encoding to '$outFile'..." -ForegroundColor Cyan

# 4. Single-pass filter+encode
ffmpeg -y -i $file.FullName `
    -filter_complex $filter `
    -map '[v]' -map '[a]' `
    -c:v libx264 -preset $VideoPreset -crf $VideoCRF `
    -c:a aac -b:a $AudioBitrate `
    -metadata:s:a:0 title="$Title" `
    $outFile

Write-Host "Done: $outFile" -ForegroundColor Green
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
~  bat --theme="Dracula" --style="header,snip,grid" --color="always" --tabs="2" --paging="never" .\yl-dlp.ps1
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
File: .\yl-dlp.ps1
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
<#
.SYNOPSIS
    Ensures required tools are installed, then downloads a video, applies pitch shift
    and optional speed change, re-encodes for quality, and remuxes into an MP4.

.DESCRIPTION
    This script will:
      1. Check for Chocolatey and Scoop; install Chocolatey if neither exists.
      2. Install missing dependencies (yt-dlp, ffmpeg, librubberband) via Chocolatey or Scoop.
      3. Reload the environment if any tools were installed.
      4. Download the specified video via yt-dlp.
      5. Detect the actual downloaded file (regardless of extension).
      6. Apply pitch shift and time-stretch in a single ffmpeg pass using rubberband and setpts.
      7. Re-encode video (x264) and audio (AAC) with high-quality settings.
      8. Output a synchronized MP4 with embedded audio title metadata.

    If no pitch shift is desired, simply omit -Semitones or set it to 0.

.PARAMETER Url
    Video URL to download (e.g., YouTube link).

.PARAMETER Output
    Base name (with or without extension) for yt-dlp output.

.PARAMETER PitchShift
    'Up' or 'Down' semitones. Ignored if Semitones = 0. Default = 'Up'.

.PARAMETER Semitones
    Number of semitones to shift. Default = 0 (no pitch shift).

.PARAMETER SpeedFactor
    Time-stretch factor (<1 slows, >1 speeds). Default = 1.0.

.PARAMETER Title
    Audio title metadata for the final MP4.

.PARAMETER VideoName
    Base name for the final output file (without extension).

.PARAMETER VideoCRF
    CRF for x264 encoding (0–51). Default = 18.

.PARAMETER VideoPreset
    x264 preset. Default = 'slow'.

.PARAMETER AudioBitrate
    AAC bitrate (e.g., '320k'). Default = '320k'.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Output,
    [ValidateSet('Up','Down')][string]$PitchShift = 'Up',
    [int]$Semitones = 0,
    [ValidateRange(0.01,10.0)][double]$SpeedFactor = 1.0,
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$VideoName,
    [ValidateRange(0,51)][int]$VideoCRF = 18,
    [ValidateSet('ultrafast','superfast','veryfast','faster','fast','medium','slow','slower','veryslow')][string]$VideoPreset = 'slow
',
    [ValidatePattern('^\d+k$')][string]$AudioBitrate = '320k'
)

# Track whether we installed any dependencies
$depsInstalled = $false

function Install-Choco {
    Write-Host 'Installing Chocolatey...' -ForegroundColor Cyan
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $global:depsInstalled = $true
}

function Ensure-Packager {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue) -and -not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Install-Choco
    }
}

function Install-Tool {
    param(
        [string]$Command,
        [string]$ChocoName,
        [string]$ScoopName
    )
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "Installing $Command via Chocolatey..." -ForegroundColor Cyan
            choco install $ChocoName -y --no-progress
            $global:depsInstalled = $true
        } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
            Write-Host "Installing $Command via Scoop..." -ForegroundColor Cyan
            scoop install $ScoopName
            $global:depsInstalled = $true
        } else {
            Write-Error "No package manager found to install $Command."
            exit 1
        }
    }
}

# Ensure package manager exists and install dependencies
Ensure-Packager
Install-Tool -Command yt-dlp     -ChocoName yt-dlp     -ScoopName yt-dlp
Install-Tool -Command ffmpeg     -ChocoName ffmpeg     -ScoopName ffmpeg
Install-Tool -Command rubberband -ChocoName librubberband -ScoopName rubberband

# Reload environment if needed
if ($depsInstalled) {
    Write-Host 'Reloading environment variables...' -ForegroundColor Cyan
    RefreshEnv
}

# 1. Download via yt-dlp
Write-Host "Downloading '$Url' to '$Output'..." -ForegroundColor Cyan
yt-dlp -f 'bv*[height<=1080]+ba/best' -o "$Output" "$Url"

# 2. Locate downloaded file
$base = [IO.Path]::GetFileNameWithoutExtension($Output)
$file = Get-ChildItem -Filter "$base.*" -File |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $file) { Write-Error "Cannot find '$base.*'"; exit 1 }
Write-Host "Using file: $($file.Name)" -ForegroundColor Green

# 3. Compute filter parameters
$semi = if ($Semitones -eq 0) { 0 } elseif ($PitchShift -eq 'Down') { -$Semitones } else { $Semitones }
$pitchRatio = [math]::Pow(2, $semi/12)
$vFactor = 1.0/$SpeedFactor
$speedLabel = ($SpeedFactor.ToString([Globalization.CultureInfo]::InvariantCulture)).Replace('.', 'p') + 'x'

if ($Semitones -eq 0) {
    $namePart = "speed-$speedLabel"
} else {
    $namePart = "shifted-$($PitchShift.ToLower())-${Semitones}st-$speedLabel"
}
$outFile = "${VideoName}-${namePart}.mp4"

# Build filter_complex
$vf = "setpts=PTS*${vFactor}"
$af = "rubberband=tempo=${SpeedFactor}:pitch=${pitchRatio}"
$filter = "[0:v]$vf[v];[0:a]$af[a]"

Write-Host "Processing and encoding to '$outFile'..." -ForegroundColor Cyan

# 4. Single-pass filter+encode
ffmpeg -y -i $file.FullName `
    -filter_complex $filter `
    -map '[v]' -map '[a]' `
    -c:v libx264 -preset $VideoPreset -crf $VideoCRF `
    -c:a aac -b:a $AudioBitrate `
    -metadata:s:a:0 title="$Title" `
    $outFile

Write-Host "Done: $outFile" -ForegroundColor Green
