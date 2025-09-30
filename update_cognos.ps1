param(
    [Parameter(Mandatory=$true)]
    [string]$InputFolder,
    [string]$OutputFolder = "$InputFolder\_updated",
    [switch]$WhatIf   # dry run: show changes, don't write files
)

# Create output and backup folders
$BackupFolder = "$InputFolder\_backup"
New-Item -ItemType Directory -Force -Path $OutputFolder, $BackupFolder | Out-Null

# Helper: apply SQL text transforms safely
function Fix-SqlForPostgres {
    param([string]$sql)

    # 1) Remove DB2 "WITH UR" (uncommitted read) hints
    $sql = $sql -replace '(?is)\s+with\s+ur\b', ''

    # 2) Date arithmetic conversions (examples shown; add more as needed)
    $sql = $sql -replace '(?is)current_date\s*\+\s*-1\s+day\b', "current_date - INTERVAL '1 day'"
    $sql = $sql -replace '(?is)current_date\s*\+\s*(\d+)\s+day\b', "current_date + INTERVAL '$1 day'"
    $sql = $sql -replace '(?is)current_date\s*\-\s*(\d+)\s+day\b', "current_date - INTERVAL '$1 day'"
    $sql = $sql -replace '(?is)current_date\s*\+\s*(\d+)\s+days\b', "current_date + INTERVAL '$1 day'"
    $sql = $sql -replace '(?is)current_date\s*\-\s*(\d+)\s+days\b', "current_date - INTERVAL '$1 day'"

    # Add month/year examples if you need them:
    $sql = $sql -replace '(?is)current_date\s*\+\s*(\d+)\s+month\b', "current_date + INTERVAL '$1 month'"
    $sql = $sql -replace '(?is)current_date\s*\-\s*(\d+)\s+month\b', "current_date - INTERVAL '$1 month'"
    $sql = $sql -replace '(?is)current_date\s*\+\s*(\d+)\s+year\b',  "current_date + INTERVAL '$1 year'"
    $sql = $sql -replace '(?is)current_date\s*\-\s*(\d+)\s+year\b',  "current_date - INTERVAL '$1 year'"

    # 3) Optional: translate DB2 CURRENT TIMESTAMP → Postgres now()
    $sql = $sql -replace '(?is)\bcurrent\s+timestamp\b', 'now()'

    # 4) Trim extra whitespace introduced by removals
    $sql = $sql -replace '[\t ]{2,}', ' '
    $sql = $sql -replace '\s+\)', ')'
    $sql = $sql -replace '\(\s+', '('
    return $sql.Trim()
}

Get-ChildItem -Path $InputFolder -Filter *.xml -File -Recurse | ForEach-Object {
    $inFile  = $_.FullName
    $outFile = Join-Path $OutputFolder $_.Name
    $bakFile = Join-Path $BackupFolder $_.Name

    # Load XML
    [xml]$doc = Get-Content -LiteralPath $inFile -Raw

    # Find all <sql> nodes ignoring namespaces
    $sqlNodes = $doc.SelectNodes("//*[local-name()='sql']")

    if ($sqlNodes -and $sqlNodes.Count -gt 0) {
        # Backup original once per file
        if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $bakFile -Force }

        $changed = $false
        foreach ($node in $sqlNodes) {
            # Get/Set inner text
            $orig = $node.InnerText
            $fixed = Fix-SqlForPostgres -sql $orig
            if ($fixed -ne $orig) {
                $changed = $true
                if ($WhatIf) {
                    Write-Host "Would change $inFile" -ForegroundColor Yellow
                    Write-Host "Old SQL:" -ForegroundColor DarkGray
                    Write-Host $orig
                    Write-Host "New SQL:" -ForegroundColor Green
                    Write-Host $fixed
                } else {
                    # Replace text node safely
                    $node.RemoveAll() | Out-Null
                    $node.AppendChild($doc.CreateTextNode($fixed)) | Out-Null
                }
            }
        }

        if (-not $WhatIf) {
            if ($changed) {
                $doc.Save($outFile)
                Write-Host "Updated: $outFile" -ForegroundColor Green
            } else {
                # No changes; just copy original to output for consistency
                Copy-Item -LiteralPath $inFile -Destination $outFile -Force
                Write-Host "No SQL changes: $inFile" -ForegroundColor DarkGray
            }
        }
    } else {
        # No <sql> nodes—copy through
        if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $outFile -Force }
        Write-Host "No <sql> nodes: $inFile" -ForegroundColor DarkGray
    }
}

Write-Host "Done." -ForegroundColor Cyan