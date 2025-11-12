<#
.SYNOPSIS
  Ensure this script runs elevated; if not, relaunch it with UAC consent.

.DESCRIPTION
  Detects current process token. If not Administrator, re-executes the same script
  via Start-Process -Verb RunAs, forwarding all bound parameters and $args.
  Waits for completion and returns the elevated script’s exit code.

.NOTES
  Works in Windows PowerShell and PowerShell 7+. Safe to include in any script.
#>

# --- helper: are we admin? ---
function Test-IsAdmin {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wp = [Security.Principal.WindowsPrincipal]$wi
    return $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    # Path to *this* PowerShell executable (pwsh.exe or powershell.exe)
    $exe = (Get-Process -Id $PID).Path

    # Rebuild argument list: -File <this.ps1> [bound params] [positional args]
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath)

    # Forward named parameters that were actually bound
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        $argList += @("-$($kv.Key)")
        # PowerShell will quote values as needed when each token is its own element
        $argList += @("$($kv.Value)")
    }

    # Forward remaining positional args
    if ($args.Count) { $argList += $args }

    # Start elevated, wait, propagate exit code
    $p = Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList -PassThru
    $p.WaitForExit()
    exit $p.ExitCode
}