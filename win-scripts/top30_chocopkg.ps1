# Unauthenticated request – no API key required
$top = 30
$uri = "https://community.chocolatey.org/api/v2/Packages()" +
       "?`$filter=IsLatestVersion%20eq%20true" +
       "&`$select=Id,Version,DownloadCount" +
       "&`$orderby=DownloadCount%20desc" +
       "&`$top=$top"

# Returns ATOM XML.  ConvertFrom-Xml then ConvertFrom-Json
[xml]$feed = Invoke-RestMethod -Uri $uri -Headers @{Accept='application/atom+xml'}
$list = $feed.feed.entry |
        Select-Object @{n='Package';e={$_.content.properties.Id}},      `
                      @{n='Version';e={$_.content.properties.Version}}, `
                      @{n='Downloads';e={$_.content.properties.DownloadCount}}

$list | Format-Table -AutoSize

