$p = 'C:\Users\JiHuanyu\.dsh\storages\workspace.json'
$d = Get-Content $p -Raw | ConvertFrom-Json
$removed = @('session-7514de31-6e29-4def-a9c7-065ca39bc786', 'session-9d5182c5-35b3-4b6c-b350-848c78898db2', 'session-e10361ca-c65b-47dc-9581-e9b1305c2a1b', 'session-1fa6a58d-ab4c-469a-b012-3cd2c85de29b')
$ids = $d.global.archivedSessionIds | Where-Object { $_ -notin $removed }
$d.global.archivedSessionIds = $ids
$d | ConvertTo-Json -Depth 10 | Set-Content $p -NoNewline
Write-Output 'done'
