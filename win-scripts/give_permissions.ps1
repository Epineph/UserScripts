$path = "C:\Program Files (x86)\Microsoft Visual Studio"
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# Create access rule with inheritance for folders
$folderAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $currentUser,
    "FullControl",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)

# Create access rule without inheritance for files
$fileAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $currentUser,
    "FullControl",
    "None",
    "None",
    "Allow"
)

# Process parent folder
try {
    $acl = Get-Acl -Path $path
    $acl.SetAccessRule($folderAccessRule)
    Set-Acl -Path $path -AclObject $acl
} catch {
    Write-Warning "Failed to set permissions on $path : $_"
}

# Process child items recursively
Get-ChildItem -Path $path -Recurse | ForEach-Object {
    try {
        $acl = Get-Acl -Path $_.FullName
        if ($_.PSIsContainer) {
            $acl.SetAccessRule($folderAccessRule)
        } else {
            $acl.SetAccessRule($fileAccessRule)
        }
        Set-Acl -Path $_.FullName -AclObject $acl
    } catch {
        Write-Warning "Failed to set permissions on $($_.FullName) : $_"
    }
}