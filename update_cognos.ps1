param(
  [Parameter(Mandatory=$true)][string]$InputFolder,
  [string]$OutputFolder = "$InputFolder\_updated",
  [switch]$WhatIf
)

$BackupFolder = "$InputFolder\_backup"
New-Item -ItemType Directory -Force -Path $OutputFolder, $BackupFolder | Out-Null

function Fix-SqlForPostgres {
  param([string]$sql)

  # ---- 0) Normalization helpers ----
  # Collapse long whitespace (after major edits we'll tidy again)
  $sql = $sql -replace '[\r\n]+', ' '
  $sql = $sql -replace '[\t ]{2,}', ' '

  # ---- 1) DB2 "WITH UR" isolation hint -> remove ----
  $sql = $sql -replace '(?is)\s+with\s+ur\b', ''

  # ---- 2) Date arithmetic (DB2 -> Postgres intervals) ----
  # Support "current_date" and "current date" forms (any case)
  $cd = '(?i)\bcurrent[_\s]?date\b'
  $sql = $sql -replace "$cd\s*\+\s*-1\s+day\b",   "current_date - INTERVAL '1 day'"
  $sql = $sql -replace "$cd\s*\+\s*-1\s+month\b", "current_date - INTERVAL '1 month'"
  $sql = $sql -replace "$cd\s*\+\s*-1\s+year\b",  "current_date - INTERVAL '1 year'"

  $sql = $sql -replace "$cd\s*\+\s*(\d+)\s+day(s)?\b",   "current_date + INTERVAL '$1 day'"
  $sql = $sql -replace "$cd\s*\-\s*(\d+)\s+day(s)?\b",   "current_date - INTERVAL '$1 day'"
  $sql = $sql -replace "$cd\s*\+\s*(\d+)\s+month(s)?\b", "current_date + INTERVAL '$1 month'"
  $sql = $sql -replace "$cd\s*\-\s*(\d+)\s+month(s)?\b", "current_date - INTERVAL '$1 month'"
  $sql = $sql -replace "$cd\s*\+\s*(\d+)\s+year(s)?\b",  "current_date + INTERVAL '$1 year'"
  $sql = $sql -replace "$cd\s*\-\s*(\d+)\s+year(s)?\b",  "current_date - INTERVAL '$1 year'"

  # If the column is timestamp, sometimes folks compare against date.
  # Optional: translate CURRENT TIMESTAMP-style comparisons.
  $sql = $sql -replace '(?is)\bcurrent\s+timestamp\b', 'now()'   # or current_timestamp

  # ---- 3) CASTs / type functions ----
  # DATE(expr)        -> expr::date
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bDATE\s*\(\s*([^)]+?)\s*\)', {'$('+$args[0].Groups[1].Value+')::date'})

  # TIMESTAMP(expr)   -> expr::timestamp
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bTIMESTAMP\s*\(\s*([^)]+?)\s*\)', {'$('+$args[0].Groups[1].Value+')::timestamp'})

  # INTEGER(expr)     -> CAST(expr AS integer)
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bINTEGER\s*\(\s*([^)]+?)\s*\)', {'CAST('+$args[0].Groups[1].Value+' AS integer)'})

  # BIGINT(expr)      -> CAST(expr AS bigint)
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bBIGINT\s*\(\s*([^)]+?)\s*\)', {'CAST('+$args[0].Groups[1].Value+' AS bigint)'})

  # DOUBLE(expr)      -> CAST(expr AS double precision)
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bDOUBLE\s*\(\s*([^)]+?)\s*\)', {'CAST('+$args[0].Groups[1].Value+' AS double precision)'})

  # DECIMAL(expr,p,s) -> CAST(expr AS numeric(p,s))
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bDECIMAL\s*\(\s*([^,]+?)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
            {'CAST('+$args[0].Groups[1].Value+' AS numeric('+$args[0].Groups[2].Value+','+$args[0].Groups[3].Value+'))'})

  # ---- 4) Formatting functions ----
  # VARCHAR_FORMAT(ts, 'YYYY-MM-DD') -> to_char(ts, 'YYYY-MM-DD')
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, "(?is)\bVARCHAR_FORMAT\s*\(\s*([^,]+?)\s*,\s*'([^']*)'\s*\)",
            {'to_char('+$args[0].Groups[1].Value+", '"+$args[0].Groups[2].Value+"')"}
        )

  # CHAR(datecol) — ambiguous in general; ONLY convert if arg looks like date/timestamp keywords.
  # If you prefer a generic cast instead, comment this block and use the fallback right below.
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bCHAR\s*\(\s*([^)]+?\b(date|timestamp)\b[^)]*)\)',
            {'to_char('+$args[0].Groups[1].Value+", 'YYYY-MM-DD')"}
        )
  # Generic (safer) fallback: CHAR(expr) -> CAST(expr AS char)
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bCHAR\s*\(\s*([^)]+?)\s*\)', {'CAST('+$args[0].Groups[1].Value+' AS char)'})

  # ---- 5) FETCH FIRST n ROWS ONLY ----
  # Postgres supports this syntax; we can leave it.
  # If you prefer LIMIT n, uncomment the next line:
  # $sql = $sql -replace '(?is)\bFETCH\s+FIRST\s+(\d+)\s+ROWS?\s+ONLY\b', 'LIMIT $1'

  # ---- 6) Tidy whitespace around parentheses/commas ----
  $sql = $sql -replace '\(\s+', '('
  $sql = $sql -replace '\s+\)', ')'
  $sql = $sql -replace '\s+,', ', '
  $sql = $sql -replace '[\t ]{2,}', ' '
  return $sql.Trim()
}

Get-ChildItem -Path $InputFolder -Filter *.xml -File -Recurse | ForEach-Object {
  $inFile  = $_.FullName
  $outFile = Join-Path $OutputFolder $_.Name
  $bakFile = Join-Path $BackupFolder $_.Name

  [xml]$doc = Get-Content -LiteralPath $inFile -Raw

  # Target <sqlText> (namespace-agnostic). Add 'or local-name()="sql"' if needed.
  $sqlNodes = $doc.SelectNodes("//*[local-name()='sqlText']")

  if ($sqlNodes -and $sqlNodes.Count -gt 0) {
    if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $bakFile -Force }
    $changed = $false

    foreach ($node in $sqlNodes) {
      # Detect CDATA
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
          if ($hadCdata) { $null = $node.AppendChild($doc.CreateCDataSection($fixed)) }
          else           { $null = $node.AppendChild($doc.CreateTextNode($fixed)) }
        }
      }
    }

    if (-not $WhatIf) {
      if ($changed) { $doc.Save($outFile); Write-Host "Updated: $outFile" -ForegroundColor Green }
      else { Copy-Item -LiteralPath $inFile -Destination $outFile -Force; Write-Host "No SQL changes: $inFile" -ForegroundColor DarkGray }
    }
  } else {
    if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $outFile -Force }
    Write-Host "No <sqlText> nodes: $inFile" -ForegroundColor DarkGray
  }
}

Write-Host "Done." -ForegroundColor Cyan