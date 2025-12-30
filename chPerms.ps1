#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Take ownership and/or grant full permissions on a path (optionally recursive),
  and/or display current ownership + ACL.

.DESCRIPTION
  Uses built-in Windows tools:
    - takeown.exe  (ownership)
    - icacls.exe   (permissions + owner setting)

  Intended for administrative recovery/repair tasks (e.g., fixing access denied).

PARAMETER Path
  One or more file or directory paths.

PARAMETER TakeOwnership
  Take ownership (sets owner to BUILTIN\Administrators by default).

PARAMETER FullPermissions
  Grants Full Control (F) to:
    - Current user
    - BUILTIN\Administrators
    - NT AUTHORITY\SYSTEM

PARAMETER R
  Recurse into subdirectories and files (directories only).

PARAMETER NoConfirm
  If set, do not prompt before a recursive operation.

PARAMETER GetAcl
  If set, prints current Owner + Access rules (works without elevation).

.EXAMPLE
  .\Set-PathAcl.ps1 -Path 'C:\ProgramData\ssh' -GetAcl

.EXAMPLE
  .\Set-PathAcl.ps1 -Path 'C:\ProgramData\ssh' -TakeOwnership -FullPermissions -R -NoConfirm
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
  [string[]]$Path,

  [switch]$TakeOwnership,
  [switch]$FullPermissions,
  [switch]$R,
  [switch]$NoConfirm,
  [switch]$GetAcl
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-IsAdministrator {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = [Security.Principal.WindowsPrincipal]::new($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Info {
  param([string]$Message)
  Write-Host $Message
}

function Fail {
  param([string]$Message)
  throw $Message
}

function Confirm-Recursive {
  param([string]$Target)
  if ($NoConfirm) { return }
  $reply = Read-Host "Recursive change requested for '$Target'. Type YES to proceed"
  if ($reply -ne 'YES') {
    Fail "Aborted by user (did not type YES)."
  }
}

function Show-Acl {
  param([string]$Target)

  $acl = Get-Acl -LiteralPath $Target -ErrorAction Stop

  [pscustomobject]@{
    Path  = $Target
    Owner = $acl.Owner
    Access = $acl.Access | ForEach-Object {
      [pscustomobject]@{
        IdentityReference = $_.IdentityReference.ToString()
        AccessControlType = $_.AccessControlType.ToString()
        FileSystemRights  = $_.FileSystemRights.ToString()
        InheritanceFlags  = $_.InheritanceFlags.ToString()
        PropagationFlags  = $_.PropagationFlags.ToString()
        IsInherited       = $_.IsInherited
      }
    }
  }
}

function Invoke-TakeOwn {
  param(
    [string]$Target,
    [bool]$IsDirectory
  )

  $args = @('/F', $Target, '/A')
  if ($R -and $IsDirectory) {
    $args += '/R'
    $args += '/D'
    $args += 'Y'
  }

  Write-Info "takeown.exe $($args -join ' ')"
  $p = Start-Process -FilePath 'takeown.exe' -ArgumentList $args -NoNewWindow -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    Fail "takeown.exe failed with exit code $($p.ExitCode) for '$Target'."
  }
}

function Invoke-IcAclsSetOwnerAdministrators {
  param(
    [string]$Target,
    [bool]$IsDirectory
  )

  $args = @($Target, '/setowner', 'BUILTIN\Administrators', '/C')
  if ($R -and $IsDirectory) { $args += '/T' }

  Write-Info "icacls.exe $($args -join ' ')"
  $p = Start-Process -FilePath 'icacls.exe' -ArgumentList $args -NoNewWindow -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    Fail "icacls.exe /setowner failed with exit code $($p.ExitCode) for '$Target'."
  }
}

function Invoke-IcAclsGrantFullControl {
  param(
    [string]$Target,
    [bool]$IsDirectory
  )

  $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

  $grants = @(
    "$currentUser:(OI)(CI)F"
    'BUILTIN\Administrators:(OI)(CI)F'
    'NT AUTHORITY\SYSTEM:(OI)(CI)F'
  )

  $args = @($Target, '/C')
  foreach ($g in $grants) {
    $args += '/grant'
    $args += $g
  }
  if ($R -and $IsDirectory) { $args += '/T' }

  Write-Info "icacls.exe $($args -join ' ')"
  $p = Start-Process -FilePath 'icacls.exe' -ArgumentList $args -NoNewWindow -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    Fail "icacls.exe /grant failed with exit code $($p.ExitCode) for '$Target'."
  }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$needsElevation = $TakeOwnership -or $FullPermissions
if ($needsElevation -and -not (Test-IsAdministrator)) {
  Fail "This operation requires an elevated PowerShell session (Run as Administrator)."
}

foreach ($p in $Path) {
  $resolved = $null
  try {
    $resolved = (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path
  } catch {
    Fail "Path not found: '$p'"
  }

  $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
  $isDir = $item.PSIsContainer

  if ($GetAcl) {
    Show-Acl -Target $resolved
  }

  if (-not $needsElevation) {
    continue
  }

  if ($R -and -not $isDir) {
    Write-Info "Note: -R ignored for file '$resolved' (recursion applies to directories)."
  }

  if ($R -and $isDir) {
    Confirm-Recursive -Target $resolved
  }

  if ($PSCmdlet.ShouldProcess($resolved, "Modify ownership/permissions")) {

    if ($TakeOwnership) {
      Invoke-TakeOwn -Target $resolved -IsDirectory:$isDir
      Invoke-IcAclsSetOwnerAdministrators -Target $resolved -IsDirectory:$isDir
    }

    if ($FullPermissions) {
      Invoke-IcAclsGrantFullControl -Target $resolved -IsDirectory:$isDir
    }
  }
}
