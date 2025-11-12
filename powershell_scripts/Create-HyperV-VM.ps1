<#
.SYNOPSIS
Creates and configures a Hyper-V virtual machine with customizable options.

.DESCRIPTION
This script creates a Hyper-V virtual machine, attaches one or more disks, sets up an ISO for installation, configures RAM, CPU weight, and other VM settings.

.PARAMETER VMName
The name of the virtual machine to create or configure.

.PARAMETER ISOPath
The file path to the ISO file to attach to the VM.

.PARAMETER DiskPaths
A list of paths to existing virtual hard disks to attach to the VM. Can be omitted if creating new disks.

.PARAMETER NewDisk
Create a new virtual hard disk if no DiskPaths are specified. Requires specifying NewDiskSize and NewDiskDynamic.

.PARAMETER NewDiskSize
The size (in GB) of the new virtual hard disk.

.PARAMETER NewDiskDynamic
Boolean flag to specify if the new virtual hard disk should expand dynamically.

.PARAMETER Memory
The amount of memory (in MB) to allocate to the VM.

.PARAMETER DynamicMemory
Boolean flag to enable or disable dynamic memory allocation.

.PARAMETER CPUWeight
The processor weight for the VM. Higher values give the VM higher priority.

.EXAMPLE
.\CreateHyperVVM.ps1 -VMName "TestVM" -ISOPath "C:\ISOs\Windows.iso" -NewDisk -NewDiskSize 50 -NewDiskDynamic $true -Memory 4096 -DynamicMemory $true -CPUWeight 80

Creates a VM named "TestVM" with a 50GB dynamically expanding disk, 4GB RAM with dynamic adjustment, and CPU weight set to 80.

.EXAMPLE
.\CreateHyperVVM.ps1 -VMName "LinuxVM" -ISOPath "C:\ISOs\Linux.iso" -DiskPaths "C:\Hyper-V\Disks\Disk1.vhdx","C:\Hyper-V\Disks\Disk2.vhdx" -Memory 2048 -DynamicMemory $false -CPUWeight 50

Creates a VM named "LinuxVM", attaches two existing disks, assigns 2GB fixed RAM, and sets the CPU weight to 50.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$ISOPath,

    [Parameter(Mandatory = $false)]
    [string[]]$DiskPaths,

    [Parameter(Mandatory = $false)]
    [switch]$NewDisk,

    [Parameter(Mandatory = $false)]
    [int]$NewDiskSize,

    [Parameter(Mandatory = $false)]
    [bool]$NewDiskDynamic = $true,

    [Parameter(Mandatory = $false)]
    [int]$Memory = 2048,

    [Parameter(Mandatory = $false)]
    [bool]$DynamicMemory = $true,

    [Parameter(Mandatory = $false)]
    [int]$CPUWeight = 50
)

# Validate parameters
if ($NewDisk -and $null -eq $NewDiskSize) {
    Write-Error "NewDiskSize must be specified when creating a new disk."
    return
}

if (-not (Test-Path $ISOPath)) {
    Write-Error "The specified ISOPath does not exist: $ISOPath"
    return
}

# Create the VM
Write-Host "Creating VM: $VMName"
New-VM -Name $VMName -MemoryStartupBytes ${Memory}MB -Generation 2

# Configure Dynamic Memory
if ($DynamicMemory) {
    Set-VM -Name $VMName -DynamicMemoryEnabled $true -MemoryMinimumBytes 512MB -MemoryMaximumBytes (${Memory}MB * 2)
} else {
    Set-VM -Name $VMName -DynamicMemoryEnabled $false
}

# Attach Disks
if ($DiskPaths) {
    foreach ($diskPath in $DiskPaths) {
        if (-not (Test-Path $diskPath)) {
            Write-Error "Disk path does not exist: $diskPath"
            return
        }
        Add-VMHardDiskDrive -VMName $VMName -Path $diskPath
    }
} elseif ($NewDisk) {
    $diskPath = "C:\Hyper-V\$VMName.vhdx"
    Write-Host "Creating new disk: $diskPath ($NewDiskSize GB, Dynamic: $NewDiskDynamic)"
    New-VHD -Path $diskPath -SizeBytes ${NewDiskSize}GB -Dynamic:$NewDiskDynamic
    Add-VMHardDiskDrive -VMName $VMName -Path $diskPath
}

# Attach ISO
Write-Host "Attaching ISO: $ISOPath"
Add-VMDvdDrive -VMName $VMName -Path $ISOPath

# Configure CPU Weight
Write-Host "Setting CPU weight: $CPUWeight"
Set-VMProcessor -VMName $VMName -ResourceControlWeight $CPUWeight

# Start the VM
Write-Host "Starting VM: $VMName"
Start-VM -Name $VMName

Write-Host "VM $VMName has been successfully created and configured."
