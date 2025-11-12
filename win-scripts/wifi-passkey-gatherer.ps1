#!/usr/bin/env pwsh
<#PSScriptInfo
.VERSION 1.2.0
.GUID 7b9f9b2e-1a1c-445c-9f2b-0d1f8b5a9e2e
.AUTHOR You
.COPYRIGHT (c) You. All rights reserved.
#>

<#
.SYNOPSIS
    Enumerate saved Wi-Fi (WLAN) profiles and recover settings/keys already stored on this machine.

.DESCRIPTION
    Uses `netsh wlan` to:
      • List all saved Wi-Fi profiles (SSIDs).
      • Show detailed settings for one or all profiles.
      • Reveal the cleartext key (password) when possible (elevated shell usually required for all-user profiles).
      • Export profiles as XML (optionally with key material).
      • Write a structured JSON snapshot for audit/backup.
      • Copy a single profile’s key to the clipboard.

    Key retrieval is attempted from `netsh wlan show profile ... key=clear` first.
    If not disclosed there, a fallback XML export is parsed for <keyMaterial>.

.PARAMETER Name
    A specific profile (SSID) to inspect. Use -All to inspect everything.

.PARAMETER All
    Inspect every saved WLAN profile.

.PARAMETER ShowKey
    Attempt to reveal cleartext key(s). If omitted, defaults to $true when elevated, else $false.

.PARAMETER JsonOut
    Path to a JSON file to write a structured dump of the selected profiles.

.PARAMETER ExportXml
    Directory to export `netsh wlan export profile` XML files. If -ShowKey is set, exported XML will include <keyMaterial>.

.PARAMETER Clipboard
    Copy the key of the selected -Name profile to the clipboard (requires -ShowKey and a recoverable key).

.PARAMETER Quiet
    Suppress table output (useful when only exporting JSON/XML).

.EXAMPLE
    # Quick inventory of all profiles (no keys unless elevated by default)
    .\wifi-passkey-gatherer.ps1 -All

.EXAMPLE
    # Show key for a specific SSID (run elevated), and copy to clipboard
    .\wifi-passkey-gatherer.ps1 -Name "WifiDD10" -ShowKey -Clipboard

.EXAMPLE
    # Full audit: all profiles to JSON + XML with keys (elevated)
    .\wifi-passkey-gatherer.ps1 -All -ShowKey `
        -JsonOut "$env:USERPROFILE\Desktop\wlan_profiles.json" `
        -ExportXml "$env:USERPROFILE\Desktop\wlan_xml"

.NOTES
    • WPA2/WPA3-Enterprise (802.1X) profiles have no PSK to reveal; Key will remain empty.
    • For maximum disclosure of keys, run PowerShell as Administrator.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ParameterSetName = 'One', Mandatory = $true)]
    [string]$Name,

    [Parameter(ParameterSetName = 'All', Mandatory = $true)]
    [switch]$All,

    [switch]$ShowKey,
    [string]$JsonOut,
    [string]$ExportXml,
    [switch]$Clipboard,
    [switch]$Quiet
)

#region Helpers

function Test-IsAdmin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = New-Object Security.Principal.WindowsPrincipal($id)
    return $pri.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-CurrentWlanInfo {
    $raw = netsh wlan show interfaces 2>$null
    if (-not $raw) { return $null }
    $h = [ordered]@{
        Interface      = $null
        State          = $null
        SSID           = $null
        BSSID          = $null
        RadioType      = $null
        Channel        = $null
        ReceiveRate    = $null
        TransmitRate   = $null
        SignalPct      = $null
        Authentication = $null
        Cipher         = $null
        Profile        = $null
    }
    foreach ($line in $raw) {
        if     ($line -match '^\s*Name\s*:\s*(.+)$')                 { $h.Interface    = $matches[1].Trim() }
        elseif ($line -match '^\s*State\s*:\s*(.+)$')                { $h.State        = $matches[1].Trim() }
        elseif ($line -match '^\s*SSID\s*:\s*(.+)$')                 { $h.SSID         = $matches[1].Trim() }
        elseif ($line -match '^\s*BSSID\s*:\s*(.+)$')                { $h.BSSID        = $matches[1].Trim() }
        elseif ($line -match '^\s*Radio type\s*:\s*(.+)$')           { $h.RadioType    = $matches[1].Trim() }
        elseif ($line -match '^\s*Channel\s*:\s*(.+)$')              { $h.Channel      = $matches[1].Trim() }
        elseif ($line -match '^\s*Receive rate.*:\s*(.+)$')          { $h.ReceiveRate  = $matches[1].Trim() }
        elseif ($line -match '^\s*Transmit rate.*:\s*(.+)$')         { $h.TransmitRate = $matches[1].Trim() }
        elseif ($line -match '^\s*Signal\s*:\s*(.+)$')               { $h.SignalPct    = $matches[1].Trim() }
        elseif ($line -match '^\s*Authentication\s*:\s*(.+)$')       { $h.Authentication = $matches[1].Trim() }
        elseif ($line -match '^\s*Cipher\s*:\s*(.+)$')               { $h.Cipher       = $matches[1].Trim() }
        elseif ($line -match '^\s*Profile\s*:\s*(.+)$')              { $h.Profile      = $matches[1].Trim() }
    }
    [pscustomobject]$h
}

function Get-WlanProfiles {
    <#
      Robust profile name discovery:
        1) Try parsing `netsh wlan show profiles` with a tolerant regex (handles "Profile"/"Profil").
        2) If nothing is found (e.g., heavily localized output), export all profiles to a temp folder and
           read <WLANProfile><name> from each XML.
    #>
    $raw = netsh wlan show profiles 2>$null
    $names = @()

    if ($raw) {
        foreach ($line in $raw) {
            # Accept lines like:
            #   All User Profile     : SSID
            #   Current User Profile : SSID
            #   (and tolerate "Profil" without trailing 'e')
            if ($line -match '^\s*(?:All\s+User\s+Profil[e]?|Current\s+User\s+Profil[e]?)\s*:\s*(.+)$') {
                $n = $matches[1].Trim()
                if ($n) { $names += $n }
            }
            elseif ($line -match '^\s*.*Profil[e]?\s*:\s*(.+)$') {
                # Very tolerant catch-all if localized but still contains "Profil(e)"
                $n = $matches[1].Trim()
                if ($n) { $names += $n }
            }
        }
    }

    $names = $names | Sort-Object -Unique
    if ($names.Count -gt 0) { return $names }

    # Fallback: export and parse XMLs
    $tmp = $null
    try {
        $tmp = Join-Path $env:TEMP ("wlan_xml_" + [IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $null = netsh wlan export profile folder="$tmp" key=absent 2>$null
        $xmls = Get-ChildItem -Path $tmp -Filter '*.xml' -File -ErrorAction SilentlyContinue
        foreach ($f in $xmls) {
            try {
                [xml]$x = Get-Content -LiteralPath $f.FullName -Raw
                $n = $x.WLANProfile.name
                if ($n) { $names += $n.Trim() }
            } catch { }
        }
    } catch { }
    finally {
        if ($tmp -and (Test-Path $tmp)) {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }
    }

    $names | Sort-Object -Unique
}

function Get-WlanProfileDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [switch]$IncludeKey
    )

    # Query profile; ask for clear key only if requested
    $keyArg = if ($IncludeKey) { 'clear' } else { 'absent' }
    $raw = netsh wlan show profile name="$ProfileName" key=$keyArg 2>$null
    if (-not $raw) { return $null }

    # Parse the text output
    $h = [ordered]@{
        Name            = $ProfileName
        OwnerScope      = $null     # All-user / Current-user
        ConnectionMode  = $null
        Authentication  = $null
        Cipher          = $null
        SecurityKey     = $null     # "Present" / "Absent"
        Key             = $null     # cleartext if disclosed
        Cost            = $null
        AutoSwitch      = $null
        AutoConnect     = $null
    }

    foreach ($line in $raw) {
        if     ($line -match '^\s*Profile\s+information') { continue }
        elseif ($line -match '^\s*Profile\s*:\s*(.+)$')         { $h.Name           = $matches[1].Trim() }
        elseif ($line -match '^\s*Owner\s*:\s*(.+)$')           { $h.OwnerScope     = $matches[1].Trim() }
        elseif ($line -match '^\s*Connection mode\s*:\s*(.+)$') { $h.ConnectionMode = $matches[1].Trim() }
        elseif ($line -match '^\s*Authentication\s*:\s*(.+)$')  { $h.Authentication = $matches[1].Trim() }
        elseif ($line -match '^\s*Cipher\s*:\s*(.+)$')          { $h.Cipher         = $matches[1].Trim() }
        elseif ($line -match '^\s*Security key\s*:\s*(.+)$')    { $h.SecurityKey    = $matches[1].Trim() }
        elseif ($line -match '^\s*Key Content\s*:\s*(.+)$')     { $h.Key            = $matches[1].Trim() }
        elseif ($line -match '^\s*Cost\s*:\s*(.+)$')            { $h.Cost           = $matches[1].Trim() }
        elseif ($line -match '^\s*AutoSwitch\s*:\s*(.+)$')      { $h.AutoSwitch     = $matches[1].Trim() }
        elseif ($line -match '^\s*Connect\s*:\s*(.+)$')         { $h.AutoConnect    = $matches[1].Trim() }
    }

    # Fallback: if we asked for the key but the text output didn't disclose it, parse an XML export
    if ($IncludeKey -and -not $h.Key) {
        $tmp = $null
        try {
            $tmp = Join-Path $env:TEMP ("wlan_xml_" + [IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null

            $null = netsh wlan export profile name="$ProfileName" folder="$tmp" key=clear 2>$null
            $xmlFile = Get-ChildItem -Path $tmp -Filter '*.xml' -File -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTime -Descending |
                       Select-Object -First 1

            if ($xmlFile) {
                [xml]$x = Get-Content -LiteralPath $xmlFile.FullName -Raw
                $maybe = $x.WLANProfile.MSM.security.sharedKey.keyMaterial
                if ($maybe) { $h.Key = $maybe.Trim() }
            }
        } catch {
            # Leave Key empty if export/parsing fails
        } finally {
            if ($tmp -and (Test-Path $tmp)) {
                Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
            }
        }
    }

    [pscustomobject]$h
}

#endregion Helpers

# -------------------- Defaults and current state banner --------------------

if (-not $PSBoundParameters.ContainsKey('ShowKey')) {
    $ShowKey = Test-IsAdmin
}

$current = Get-CurrentWlanInfo
if ($current -and -not $Quiet) {
    Write-Host ("`nCurrent WLAN interface: {0} | State: {1} | SSID: {2} | Signal: {3}" -f `
        $current.Interface, $current.State, $current.SSID, $current.SignalPct)
}

# -------------------- Resolve target profiles --------------------

$targets = if ($PSCmdlet.ParameterSetName -eq 'All') { Get-WlanProfiles } else { @($Name) }
if (-not $targets -or $targets.Count -eq 0) {
    Write-Warning "No saved WLAN profiles found."
    exit 1
}

# -------------------- Collect and output --------------------

$results = @()
foreach ($p in $targets) {
    $detail = Get-WlanProfileDetail -ProfileName $p -IncludeKey:$ShowKey
    if ($null -ne $detail) {
        $results += $detail
    }
}

if (-not $Quiet) {
    $view = $results | Select-Object Name, Authentication, Cipher, ConnectionMode, SecurityKey,
        @{n='Key';e={ if ($_.Key) { $_.Key } else { '' } }}
    $view | Format-Table -AutoSize
}

# -------------------- Optional JSON dump --------------------

if ($JsonOut) {
    try {
        $dir = Split-Path -Parent $JsonOut
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $results | ConvertTo-Json -Depth 6 | Set-Content -Path $JsonOut -Encoding UTF8
        if (-not $Quiet) { Write-Host "`nJSON written to: $JsonOut" }
    } catch {
        Write-Error "Failed to write JSON to '$JsonOut': $_"
    }
}

# -------------------- Optional XML export of all profiles --------------------

if ($ExportXml) {
    try {
        if (-not (Test-Path $ExportXml)) { New-Item -ItemType Directory -Path $ExportXml -Force | Out-Null }
        $keyParam = if ($ShowKey) { 'clear' } else { 'absent' }
        $null = netsh wlan export profile folder="$ExportXml" key=$keyParam
        if (-not $Quiet) { Write-Host "XML exported to: $ExportXml (key=$keyParam)" }
    } catch {
        Write-Error "Failed to export XML to '$ExportXml': $_"
    }
}

# -------------------- Optional clipboard copy --------------------

if ($Clipboard) {
    if (-not $PSBoundParameters.ContainsKey('Name')) {
        Write-Warning "-Clipboard requires -Name <SSID>."
    } else {
        $k = ($results | Where-Object Name -eq $Name | Select-Object -First 1).Key
        if ($k) {
            try {
                Set-Clipboard -Value $k
                if (-not $Quiet) { Write-Host "Key for '$Name' copied to clipboard." }
            } catch {
                Write-Error "Failed to copy key to clipboard: $_"
            }
        } else {
            Write-Warning "No recoverable key for '$Name'. Try running as Administrator, and verify it is a PSK network."
        }
    }
}
