param(
  [Parameter(Mandatory=$true)][string]$InputFolder,
  [string]$OutputFolder = "$InputFolder\_updated",
  [switch]$WhatIf
)

$BackupFolder = "$InputFolder\_backup"
New-Item -ItemType Directory -Force -Path $OutputFolder, $BackupFolder | Out-Null

function Fix-SqlForPostgres {
  param([string]$sql)

  # remove DB2 isolation hint
  $sql = $sql -replace '(?is)\s+with\s+ur\b', ''

  # date arithmetic
  $sql = $sql -replace '(?is)current_date\s*\+\s*-1\s+day\b', "current_date - INTERVAL '1 day'"
  $sql = $sql -replace '(?is)current_date\s*\+\s*(\d+)\s+day(s)?\b', "current_date + INTERVAL '$1 day'"
  $sql = $sql -replace '(?is)current_date\s*\-\s*(\d+)\s+day(s)?\b', "current_date - INTERVAL '$1 day'"
  $sql = $sql -replace '(?is)current_date\s*\+\s*(\d+)\s+month(s)?\b', "current_date + INTERVAL '$1 month'"
  $sql = $sql -replace '(?is)current_date\s*\-\s*(\d+)\s+month(s)?\b', "current_date - INTERVAL '$1 month'"
  $sql = $sql -replace '(?is)current_date\s*\+\s*(\d+)\s+year(s)?\b',  "current_date + INTERVAL '$1 year'"
  $sql = $sql -replace '(?is)current_date\s*\-\s*(\d+)\s+year(s)?\b',  "current_date - INTERVAL '$1 year'"

  # current timestamp
  $sql = $sql -replace '(?is)\bcurrent\s+timestamp\b', 'now()'

  # tidy spaces
  $sql = $sql -replace '[\t ]{2,}', ' '
  $sql = $sql -replace '\s+\)', ')'
  $sql = $sql -replace '\(\s+', '('
  $sql.Trim()
}

Get-ChildItem -Path $InputFolder -Filter *.xml -File -Recurse | ForEach-Object {
  $inFile  = $_.FullName
  $outFile = Join-Path $OutputFolder $_.Name
  $bakFile = Join-Path $BackupFolder $_.Name

  [xml]$doc = Get-Content -LiteralPath $inFile -Raw

  # find <sqlText> nodes (namespace-agnostic)
  $sqlNodes = $doc.SelectNodes("//*[local-name()='sqlText']")

  if ($sqlNodes -and $sqlNodes.Count -gt 0) {
    if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $bakFile -Force }

    $changed = $false
    foreach ($node in $sqlNodes) {
      # detect if original payload was CDATA
      $hadCdata = $false
      foreach ($child in $node.ChildNodes) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::CData) { $hadCdata = $true; break }
      }

      $orig  = $node.InnerText
      $fixed = Fix-SqlForPostgres $orig

      if ($fixed -ne $orig) {
        $changed = $true
        if ($WhatIf) {
          Write-Host "Would change $inFile" -ForegroundColor Yellow
          Write-Host "Old SQL:`n$orig" -ForegroundColor DarkGray
          Write-Host "New SQL:`n$fixed" -ForegroundColor Green
        } else {
          $node.RemoveAll() | Out-Null
          if ($hadCdata) {
            $null = $node.AppendChild($doc.CreateCDataSection($fixed))
          } else {
            $null = $node.AppendChild($doc.CreateTextNode($fixed))
          }
        }
      }
    }

    if (-not $WhatIf) {
      if ($changed) {
        $doc.Save($outFile)
        Write-Host "Updated: $outFile" -ForegroundColor Green
      } else {
        Copy-Item -LiteralPath $inFile -Destination $outFile -Force
        Write-Host "No SQL changes: $inFile" -ForegroundColor DarkGray
      }
    }
  } else {
    if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $outFile -Force }
    Write-Host "No <sqlText> nodes: $inFile" -ForegroundColor DarkGray
  }
}

Write-Host "Done." -ForegroundColor Cyan