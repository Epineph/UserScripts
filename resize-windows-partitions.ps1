[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z]:?$')]
    [string] $Storage,

    [Parameter(Mandatory = $true)]
    [string] $Shrink,

    [switch] $NoConfirm,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$bytesPerKiB = [decimal] 1024
$bytesPerMiB = $bytesPerKiB * 1024
$bytesPerGiB = $bytesPerMiB * 1024
$bytesPerTiB = $bytesPerGiB * 1024

function Format-Size {
    param([decimal] $Bytes)

    $mb = $Bytes / $bytesPerMiB
    $result = '{0:N2} MB' -f $mb

    if ($Bytes -le $bytesPerGiB) {
        $remaining = [decimal] [math]::Floor($Bytes)
        $gib = [decimal] [math]::Floor($remaining / $bytesPerGiB)
        $remaining -= $gib * $bytesPerGiB
        $mib = [decimal] [math]::Floor($remaining / $bytesPerMiB)
        $remaining -= $mib * $bytesPerMiB
        $kib = [decimal] [math]::Floor($remaining / $bytesPerKiB)
        $remaining -= $kib * $bytesPerKiB
        $result += ' ({0} GiB + {1} MiB + {2} KiB + {3} bytes)' -f $gib, $mib, $kib, $remaining
    }

    return $result
}

try {
    if ($Shrink -notmatch '^\s*(\d+(?:\.\d+)?)\s*(MB|GB|TB)\s*$') {
        throw "Invalid -Shrink value '$Shrink'. Use a positive amount such as 350GB, 120000MB, or 0.5TB."
    }

    $amount = [decimal]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    if ($amount -le 0) {
        throw '-Shrink must be greater than zero.'
    }

    $multiplier = switch ($Matches[2].ToUpperInvariant()) {
        'MB' { $bytesPerMiB }
        'GB' { $bytesPerGiB }
        'TB' { $bytesPerTiB }
    }
    $shrinkBytes = [decimal]::ToInt64([decimal]::Ceiling($amount * $multiplier))

    $driveLetter = $Storage.TrimEnd(':').ToUpperInvariant()
    $partition = Get-Partition -DriveLetter $driveLetter
    $volume = Get-Volume -DriveLetter $driveLetter
    $disk = Get-Disk -Number $partition.DiskNumber
    $supportedSize = Get-PartitionSupportedSize -DriveLetter $driveLetter

    Write-Output "Disk $($disk.Number) partition style: $($disk.PartitionStyle)"
    Write-Output "Selected volume: $driveLetter`: ($($volume.FileSystemLabel))"
    Write-Output "Current partition capacity: $(Format-Size $partition.Size)"
    Write-Output "Current free space in volume: $(Format-Size $volume.SizeRemaining)"

    $maximumShrink = [decimal] $partition.Size - [decimal] $supportedSize.MinSize
    $requestedNewSize = [decimal] $partition.Size - $shrinkBytes
    $usedBytes = [decimal] $volume.Size - [decimal] $volume.SizeRemaining

    if ($shrinkBytes -gt $maximumShrink) {
        Write-Error "Cannot shrink by $(Format-Size $shrinkBytes): maximum supported shrink is $(Format-Size $maximumShrink). Windows reports a minimum partition size of $(Format-Size $supportedSize.MinSize)."
        exit 1
    }

    if ($requestedNewSize -lt $usedBytes) {
        Write-Error "Cannot shrink by $(Format-Size $shrinkBytes): the resulting partition would be smaller than the volume's currently used space ($(Format-Size $usedBytes))."
        exit 1
    }

    $remainingFreeBytes = [decimal] $volume.SizeRemaining - $shrinkBytes
    Write-Output "Amount to shrink: $(Format-Size $shrinkBytes)"
    Write-Output "Partition capacity after shrinking: $(Format-Size $requestedNewSize)"
    Write-Output "Unallocated space released: $(Format-Size $shrinkBytes)"
    Write-Output "Estimated free space left inside the Windows volume: $(Format-Size $remainingFreeBytes)"
    Write-Warning 'Shrinking normally preserves the data, but partition changes carry risk. Back up important files first; the freed space will be unallocated, not a new Linux partition.'

    $isAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdministrator) {
        throw 'Administrator privileges are required to resize a partition. Re-run PowerShell as Administrator.'
    }

    if (-not ($NoConfirm -or $Force)) {
        $answer = Read-Host "To proceed, type exactly 'yes'"
        if ($answer -cne 'yes') {
            Write-Output 'Cancelled; no partition changes were made.'
            exit 0
        }
    }
    else {
        Write-Output 'Confirmation prompt bypassed; Windows feasibility and size checks remain enabled.'
    }

    $currentPartition = Get-Partition -DriveLetter $driveLetter
    $currentSupportedSize = Get-PartitionSupportedSize -DriveLetter $driveLetter
    if ($currentPartition.Size -ne $partition.Size -or
        $shrinkBytes -gt ([decimal] $currentPartition.Size - [decimal] $currentSupportedSize.MinSize)) {
        throw 'The partition or its supported shrink limit changed after it was inspected. No changes were made; run the script again.'
    }

    $newSizeBytes = [long] $requestedNewSize
    Resize-Partition -DriveLetter $driveLetter -Size $newSizeBytes
    Write-Output 'Partition resize completed.'
}
catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit 1
}
