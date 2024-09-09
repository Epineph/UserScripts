<#
.SYNOPSIS
    Adds a directory to the system or user PATH environment variable, or creates a new environment variable with a specified name.

.DESCRIPTION
    This script adds a directory to either the system or user PATH environment variable.
    It can also create a new environment variable with a specified name and set it to the provided directory path.
    Additionally, it allows for prepending text or inserting it at a specific position in the PATH.

.PARAMETER DirectoryPath
    The full path of the directory to add to the PATH or set as a new environment variable.

.PARAMETER SystemPath
    Indicates that the directory should be added to the system PATH (Machine-level).

.PARAMETER UserPath
    Indicates that the directory should be added to the user PATH (User-level).

.PARAMETER Name
    The name of the environment variable to create or modify. If not specified, the directory is added to the PATH.

.PARAMETER Prepend
    Indicates that the directory or environment variable should be prepended to the PATH.

.PARAMETER PrependText
    Text to prepend to the PATH variable.

.PARAMETER InsertPosition
    Specifies the position at which the directory or variable should be inserted in the PATH.

.EXAMPLE
    .\add_to_path.ps1 -DirectoryPath "C:\path\to\directory" -SystemPath

    Adds "C:\path\to\directory" to the system PATH.

.EXAMPLE
    .\add_to_path.ps1 -DirectoryPath "C:\path\to\directory" -UserPath -Name MY_ENV_VAR

    Creates or modifies the user-level environment variable "MY_ENV_VAR" and sets it to "C:\path\to\directory".

.EXAMPLE
    .\add_to_path.ps1 -DirectoryPath "C:\path\to\directory" -UserPath -Prepend

    Prepends "C:\path\to\directory" to the user PATH.

.EXAMPLE
    .\add_to_path.ps1 -DirectoryPath "C:\path\to\directory" -UserPath -InsertPosition 2

    Inserts "C:\path\to\directory" at position 2 in the user PATH.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$DirectoryPath,

    [switch]$SystemPath,

    [switch]$UserPath,

    [string]$Name,

    [switch]$Prepend,

    [string]$PrependText,

    [int]$InsertPosition
)

function Add-ToEnvVariable {
    param (
        [string]$PathToAdd,
        [string]$VariableName,
        [System.EnvironmentVariableTarget]$Target,
        [switch]$Prepend,
        [string]$PrependText,
        [int]$InsertPosition
    )

    # Get the current value of the environment variable
    $currentValue = [System.Environment]::GetEnvironmentVariable($VariableName, $Target)

    if ($currentValue) {
        # Split the current PATH into an array
        $pathArray = $currentValue -split ";"

        # Check if the path is already included
        if ($pathArray -contains $PathToAdd) {
            Write-Host "The directory '$PathToAdd' is already in the $VariableName."
            return
        }

        # Handle prepending or inserting the new path
        if ($Prepend) {
            $newValue = "$PathToAdd;$currentValue"
        } elseif ($PrependText) {
            $newValue = "$PrependText;$currentValue"
        } elseif ($InsertPosition) {
            $pathArray.Insert($InsertPosition - 1, $PathToAdd)
            $newValue = $pathArray -join ";"
        } else {
            $newValue = "$currentValue;$PathToAdd"
        }
    } else {
        $newValue = $PathToAdd
    }

    # Set the environment variable
    [System.Environment]::SetEnvironmentVariable($VariableName, $newValue, $Target)

    Write-Host "Successfully updated '$VariableName' with the value: $newValue."
}

# Determine the target (system or user)
if ($SystemPath) {
    $target = [System.EnvironmentVariableTarget]::Machine
} elseif ($UserPath) {
    $target = [System.EnvironmentVariableTarget]::User
} else {
    # If neither SystemPath nor UserPath is provided, default to UserPath
    $target = [System.EnvironmentVariableTarget]::User
    Write-Host "No target specified. Defaulting to user PATH."
}

# Set the environment variable
if ($Name) {
    Add-ToEnvVariable -PathToAdd $DirectoryPath -VariableName $Name -Target $target -Prepend:$Prepend -PrependText $PrependText -InsertPosition $InsertPosition
} else {
    Add-ToEnvVariable -PathToAdd $DirectoryPath -VariableName "PATH" -Target $target -Prepend:$Prepend -PrependText $PrependText -InsertPosition $InsertPosition
}
