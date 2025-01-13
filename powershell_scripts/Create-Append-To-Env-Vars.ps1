<#
.SYNOPSIS
    Manage environment variables at either the user or system level.

.DESCRIPTION
    This script allows you to:
    1) Append or prepend the current directory (or a given path) 
       to an existing environment variable (e.g., PATH).
    2) Create a new environment variable with a specified value.

    You must specify either:
        -a / --append or -p / --prepend    for modifying existing variables, or
        -c / --create                     for creating a new variable.

    You must also specify either:
        -u / --user    to modify user-level environment variables, or
        -s / --system  to modify system-level environment variables.

    When appending or prepending (-a / --append or -p / --prepend):
        You must provide the name of the environment variable using -n / --name.
        The value appended or prepended defaults to the current directory 
        unless otherwise specified using -v / --value.

    When creating a new environment variable (-c / --create):
        You must provide -n / --name and -v / --value.

.PARAMETER -a --append
    Append the specified or current directory path to an existing environment variable.

.PARAMETER -p --prepend
    Prepend the specified or current directory path to an existing environment variable.

.PARAMETER -c --create
    Create a new environment variable.

.PARAMETER -u --user
    Specifies that the changes apply to the current user's environment variables.

.PARAMETER -s --system
    Specifies that the changes apply to the system-wide environment variables.

.PARAMETER -n --name
    The name of the environment variable to modify or create.

.PARAMETER -v --value
    The value to be appended, prepended, or set (used when creating a new variable).
    If -a or -p is used and -v is not specified, the script uses the current directory.
    If -c is used, -v is mandatory.

.EXAMPLE
    PS C:\> .\Manage-EnvVar.ps1 -a -n PATH -u
    Appends the current directory to the PATH environment variable at the User level.

.EXAMPLE
    PS C:\> .\Manage-EnvVar.ps1 -p -n PATH -s -v "C:\MyTools"
    Prepends "C:\MyTools" to the PATH environment variable at the System level.

.EXAMPLE
    PS C:\> .\Manage-EnvVar.ps1 -c -n MY_NEW_VAR -u -v "HelloWorld"
    Creates a new environment variable named "MY_NEW_VAR" with the value "HelloWorld" at the User level.

#>

[CmdletBinding()]
param(
    [switch]$append,       # -a | --append
    [switch]$prepend,      # -p | --prepend
    [switch]$create,       # -c | --create
    [switch]$user,         # -u | --user
    [switch]$system,       # -s | --system
    
    [string]$name,         # -n | --name <NAME>
    [string]$value         # -v | --value <VALUE>
)

#
# Validate and enforce correct usage
#
if ((-not $user) -and (-not $system)) {
    Write-Error "You must specify either -u / --user or -s / --system."
    return
}

if (($append -or $prepend) -and $create) {
    Write-Error "You cannot simultaneously create a variable (-c) and append/prepend (-a or -p)."
    return
}

if (($append -or $prepend) -and (-not $name)) {
    Write-Error "When using -a / --append or -p / --prepend, you must provide a variable name (-n / --name)."
    return
}

if ($create -and ((-not $name) -or (-not $value))) {
    Write-Error "When using -c / --create, both -n / --name and -v / --value are required."
    return
}

if ((-not $append) -and (-not $prepend) -and (-not $create)) {
    Write-Error "You must specify at least one operation: -a / --append, -p / --prepend, or -c / --create."
    return
}

#
# Determine scope to operate on. 
# "Machine" corresponds to system-wide variables. 
# "User" corresponds to user-level variables.
#
$scope = if ($system) { 'Machine' } else { 'User' }

#
# If user is appending or prepending, we get the old value, 
# modify it, and set the environment variable. 
#
if ($append -or $prepend) {

    # If no -v / --value is supplied, default to current directory.
    if (-not $value) {
        $value = (Get-Location).Path
    }

    $oldValue = [Environment]::GetEnvironmentVariable($name, $scope)

    if (-not $oldValue) {
        # If the environment variable does not exist, 
        # we can create it with the provided value (append or prepend effectively the same).
        Write-Host "Variable '$name' not found. Creating a new one with value '$value'."
        [Environment]::SetEnvironmentVariable($name, $value, $scope)
    }
    else {
        # Normalize trailing or leading semicolons
        $oldValue = $oldValue.Trim(';')
        $value    = $value.Trim(';')
        
        if ($append) {
            # Append
            $newValue = "$oldValue;$value"
            Write-Host "Appending '$value' to '$name'..."
        }
        elseif ($prepend) {
            # Prepend
            $newValue = "$value;$oldValue"
            Write-Host "Prepending '$value' to '$name'..."
        }
        
        [Environment]::SetEnvironmentVariable($name, $newValue, $scope)
        Write-Host "Operation complete. New value of '$name':"
        Write-Host [Environment]::GetEnvironmentVariable($name, $scope)
    }
}

#
# If user is creating a new environment variable:
#
if ($create) {
    Write-Host "Creating new environment variable '$name' with value '$value'..."
    [Environment]::SetEnvironmentVariable($name, $value, $scope)
    Write-Host "Operation complete. New variable '$name' has value:"
    Write-Host [Environment]::GetEnvironmentVariable($name, $scope)
}

