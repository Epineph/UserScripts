function Clone-Repo {
    param (
        [Parameter(Mandatory=$true, ValueFromRemainingArguments=$true)]
        [string[]]$repos,
        [string]$instance = "github.com",
        [switch]$recurse
    )

    foreach ($repo in $repos) {
        # Construct the Git clone command
        $userRepo = $repo -split '/'
        if ($userRepo.Length -eq 2) {
            $url = "git@$instance:$repo.git"
        } else {
            $url = $repo
        }

        # Add recursive option if the switch is provided
        $cloneCommand = "git clone"
        if ($recurse.IsPresent) {
            $cloneCommand += " --recurse-submodules"
        }
        $cloneCommand += " $url"

        # Execute the Git clone command
        Write-Host "Cloning repository from $url..."
        Invoke-Expression $cloneCommand
    }
}

# Alias for shorter usage
Set-Alias -Name clone -Value Clone-Repo
