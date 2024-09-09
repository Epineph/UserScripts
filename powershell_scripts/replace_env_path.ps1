# Define the backup directory
$backupDir = "C:\PathBackup"

# Create backup directory if it doesn't exist
if (-not (Test-Path $backupDir)) {
    New-Item -Path $backupDir -ItemType Directory
}

# Backup current user and system PATH
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$userPathBackupFile = Join-Path $backupDir "user_path_backup_$timestamp.txt"
$systemPathBackupFile = Join-Path $backupDir "system_path_backup_$timestamp.txt"

# Get current user and system PATH values
$currentUserPath = [Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
$currentSystemPath = [Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)

# Write current PATH values to backup files
Set-Content -Path $userPathBackupFile -Value $currentUserPath
Set-Content -Path $systemPathBackupFile -Value $currentSystemPath

# Define the new user PATH (with environment variables properly encapsulated)
$newUserPath = @"
C:\Users\heini\Gpg4win\bin;
%WIN_APPS%;
C:\Users\heini\scoop\apps\perl\5.38.2.2\c\bin\;
%MAKE_BIN%;
%HOME_BIN%;
%DOS2UNIX_BIN%;
%WINGET_BIN%;
C:\tools\fvim\;
C:\tools\emacs\bin\;
C:\tools\neovim\nvim-win64\bin\;
%USERPROFILE%\scoop\apps\perl\current\perl\site\bin;
%USERPROFILE%\scoop\apps\perl\current\perl\bin;
%USERPROFILE%\go\bin;
%USERPROFILE%\scoop\apps\ruby\current\bin;
%USERPROFILE%\scoop\apps\ruby\current\gems\bin;
%ProgramFiles%\WindowsApps\Microsoft.PowerShellPreview_7.5.4.0_x64__8wekyb3d8bbwe;
%ProgramFiles%\Notepad++;
%USERPROFILE%\AppData\Local\nvim;
%USERPROFILE%\powershell_scripts;
%ProgramFiles%\Amazon Corretto\jdk21.0.4_7\bin;
%ProgramFiles(x86)%\Common Files\Oracle\Java\java8path;
%ProgramFiles(x86)%\Common Files\Oracle\Java\javapath;
C:\Python27\Lib\site-packages\PyQt4;
%ProgramData%\scoop\apps\python\current\Scripts;
%ProgramData%\scoop\apps\python\current;
%ProgramData%\scoop\shims;
%windir%\system32;
%windir%;
%windir%\System32\Wbem;
%windir%\System32\WindowsPowerShell\v1.0\;
%windir%\System32\OpenSSH\;
%ProgramFiles%\Git\cmd;
%ProgramFiles%\Git\mingw64\bin;
%ProgramFiles%\Git\usr\bin;
%ProgramData%\chocolatey\bin;
%ProgramFiles(x86)%\gnupg\bin;
%ProgramFiles%\Neovide\;
%ProgramFiles%\dotnet\;
%ProgramFiles%\CMake\bin;
%ProgramFiles%\neovim-qt 0.2.18\bin;
%ProgramFiles(x86)%\Subversion\bin;
%ProgramFiles%\TortoiseSVN\bin;
C:\tools\php83;
%ProgramData%\chocolatey\lib\maven\apache-maven-3.9.9\bin;
%ProgramFiles%\Java\jdk1.8.0_211\bin;
%WINGET_BIN%;
"@

# Define the new system PATH (with environment variables properly encapsulated)
$newSystemPath = @"
C:\Users\heini\scoop\apps\perl\5.38.2.2\c\bin\;
C:\Users\heini\Gpg4win\bin;
%WINGET_BIN%;
%WIN_APPS%;
%MAKE_BIN%;
%HOME_BIN%;
C:\tools\emacs\bin\;
C:\tools\fvim\;
C:\tools\neovim\nvim-win64\bin\;
%USERPROFILE%\scoop\shims;
%ProgramFiles%\Eclipse Adoptium\jre-11.0.24.8-hotspot\bin;
%ProgramFiles%\Notepad++;
%USERPROFILE%\AppData\Local\nvim;
%USERPROFILE%\powershell_scripts;
%ProgramFiles%\Amazon Corretto\jdk21.0.4_7\bin;
%ProgramFiles(x86)%\Common Files\Oracle\Java\java8path;
%ProgramFiles(x86)%\Common Files\Oracle\Java\javapath;
C:\Python27\Lib\site-packages\PyQt4;
%ProgramData%\scoop\apps\python\current\Scripts;
%ProgramData%\scoop\apps\python\current;
%ProgramData%\scoop\shims;
%windir%\system32;
%windir%;
%windir%\System32\Wbem;
%windir%\System32\WindowsPowerShell\v1.0\;
%windir%\System32\OpenSSH\;
%ProgramFiles%\Git\cmd;
%ProgramFiles%\Git\mingw64\bin;
%ProgramFiles%\Git\usr\bin;
%ProgramData%\chocolatey\bin;
%ProgramFiles(x86)%\gnupg\bin;
%ProgramFiles%\Neovide\;
%ProgramFiles%\dotnet\;
%ProgramFiles%\CMake\bin;
%ProgramFiles%\neovim-qt 0.2.18\bin;
%ProgramFiles(x86)%\Subversion\bin;
%ProgramFiles%\TortoiseSVN\bin;
C:\tools\php83;
%ProgramData%\chocolatey\lib\maven\apache-maven-3.9.9\bin;
%ProgramFiles%\Java\jdk1.8.0_211\bin;
C:\Strawberry\c\bin;
C:\Strawberry\perl\site\bin;
C:\Strawberry\perl\bin;
%ProgramFiles(x86)%\Box\Box Edit\;
%USERPROFILE%\AppData\Roaming\nvm;
%ProgramFiles%\nodejs;
%USERPROFILE%\AppData\Local\Microsoft\WinGet\Packages\Mamba.Micromamba_Microsoft.Winget.Source_8wekyb3d8bbwe;
%USERPROFILE%\repos\fzf\bin;
%USERPROFILE%\repos\vcpkg;
%USERPROFILE%\R\R-4.4.1\bin\;
%USERPROFILE%\R\R-4.4.1\bin\x64;
C:\rtools44;
%ProgramFiles%\Microsoft\Azure Functions Core Tools\;
%WINGET_BIN%
"@

# Set the new PATH values
[Environment]::SetEnvironmentVariable("PATH", $newUserPath, [System.EnvironmentVariableTarget]::User)
[Environment]::SetEnvironmentVariable("PATH", $newSystemPath, [System.EnvironmentVariableTarget]::Machine)

# Confirm the changes
Write-Host "User PATH has been updated and backed up to $userPathBackupFile"
Write-Host "System PATH has been updated and backed up to $systemPathBackupFile"

