function Edit-Profile {
    <#
    .SYNOPSIS
    Edits the PowerShell profile by appending, prepending, or inserting text at a specified line.

    .DESCRIPTION
    The Edit-Profile function allows you to modify your PowerShell profile by appending text to the end, 
    prepending text to the beginning, or inserting text at a specific line number. 
    The text can be supplied directly or from a file.

    .PARAMETER AppendText
    Specifies the text to append to the end of the profile script. If other options like PrependText or InsertAtLine are provided, 
    this option takes precedence.

    .PARAMETER PrependText
    Specifies the text to prepend to the beginning of the profile script. This is ignored if AppendText is provided.

    .PARAMETER InsertAtLine
    Specifies the line number where the text should be inserted in the profile script. This is ignored if AppendText is provided.

    .PARAMETER FilePath
    Specifies a file whose content should be used as the text input. The content is inserted based on the operation specified 
    (append, prepend, or insert at line).

    .EXAMPLE
    Edit-Profile -AppendText "function TestFunction { Write-Output 'This is a test function' }"

    This example appends the provided text to the end of the profile script.

    .EXAMPLE
    Edit-Profile -PrependText "Write-Output 'This is prepended text'"

    This example prepends the provided text to the beginning of the profile script.

    .EXAMPLE
    Edit-Profile -InsertAtLine 5 -AppendText "Write-Output 'Inserted at line 5'"

    This example inserts the provided text at line 5 of the profile script.

    .EXAMPLE
    Edit-Profile -FilePath "C:\path\to\file.txt" -InsertAtLine 3

    This example inserts the content of the specified file at line 3 of the profile script.

    .NOTES
    Author: Your Name
    The function supports only one operation at a time (append, prepend, or insert at line).
    If the line number specified in InsertAtLine exceeds the number of lines in the profile, an error is thrown.
    #>

    param (
        [string]$AppendText,
        [string]$PrependText,
        [string]$InsertAtLine,
        [string]$FilePath
    )

    # Get the profile path
    $profilePath = $PROFILE.CurrentUserAllHosts

    # If the profile script doesn't exist, create it
    if (-not (Test-Path -Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force
    }

    # Read the profile script content
    $profileContent = Get-Content -Path $profilePath -Raw

    # Define the text to be inserted
    $textToInsert = ""

    # If a file is provided, read content from the file
    if ($FilePath) {
        if (-not (Test-Path -Path $FilePath)) {
            Write-Error "The file at path '$FilePath' does not exist."
            return
        }
        $textToInsert = Get-Content -Path $FilePath -Raw
    } elseif ($AppendText) {
        $textToInsert = $AppendText
    } elseif ($PrependText) {
        $textToInsert = $PrependText
    } elseif ($InsertAtLine) {
        $textToInsert = $InsertAtLine
    }

    # Handle Append
    if ($AppendText) {
        Add-Content -Path $profilePath -Value "`n$textToInsert"
    }
    # Handle Prepend
    elseif ($PrependText) {
        $profileContent = "$textToInsert`n$profileContent"
        Set-Content -Path $profilePath -Value $profileContent
    }
    # Handle Insert at Line
    elseif ($InsertAtLine) {
        if ($InsertAtLine -match '^\d+$') {
            $lineNumber = [int]$InsertAtLine
            $contentArray = $profileContent -split "`n"
            if ($lineNumber -le $contentArray.Length) {
                $contentArray = $contentArray[0..($lineNumber - 2)] + $textToInsert + $contentArray[($lineNumber - 1)..($contentArray.Length - 1)]
                Set-Content -Path $profilePath -Value ($contentArray -join "`n")
            } else {
                Write-Error "Line number $lineNumber exceeds the number of lines in the profile."
            }
        } else {
            Write-Error "Please provide a valid line number for insertion."
        }
    } else {
        Write-Error "No valid operation specified. Please provide text to append, prepend, or a line number for insertion."
    }

    # Reload the profile
    . $profilePath
}

