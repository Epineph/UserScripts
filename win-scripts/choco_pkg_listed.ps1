param([int]$Top = 30)

$uri = 'https://community.chocolatey.org/api/v2/Packages()' +
       '?$filter=IsLatestVersion eq true' +
       '&$select=Id,Version,DownloadCount' +
       '&$orderby=DownloadCount desc' +
       "&$top=$Top"

# Note the header – no $format query option required
$resp = Invoke-RestMethod -Uri $uri -Headers @{Accept='application/json;odata=verbose'}

$list = $resp.d.results |                   # plain PowerShell objects
        Select-Object @{n='Package';e={$_.Id}},
                      @{n='Version';e={$_.Version}},
                      @{n='Downloads';e={[int]$_.DownloadCount}}

$list | Format-Table -AutoSize

