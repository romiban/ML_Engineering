param(
  [Parameter(Mandatory = $true)][string]$InputFolder,
  [string]$OutputFolder = "$InputFolder\_updated",
  [switch]$WhatIf,
  [switch]$UseFormatter  # turn on to lightly pretty-print
)

$BackupFolder = "$InputFolder\_backup"
New-Item -ItemType Directory -Force -Path $OutputFolder, $BackupFolder | Out-Null

function Fix-SqlForPostgres {
  param([string]$sql)

  # ---- Transformations (no whitespace smashing) ----

  # 1) DB2 "WITH UR" hint
  $sql = $sql -replace '(?is)\s+with\s+ur\b', ''

  # 2) Date arithmetic
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

  $sql = $sql -replace '(?is)\bcurrent\s+timestamp\b', 'now()'   # or current_timestamp

  # 3) CASTs / types
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bDATE\s*\(\s*([^)]+?)\s*\)', { $('(' + $args[0].Groups[1].Value + ')::date') })

  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bTIMESTAMP\s*\(\s*([^)]+?)\s*\)', { $('(' + $args[0].Groups[1].Value + ')::timestamp') })

  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bINTEGER\s*\(\s*([^)]+?)\s*\)', { $('CAST(' + $args[0].Groups[1].Value + ' AS integer)') })

  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bBIGINT\s*\(\s*([^)]+?)\s*\)', { $('CAST(' + $args[0].Groups[1].Value + ' AS bigint)') })

  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bDOUBLE\s*\(\s*([^)]+?)\s*\)', { $('CAST(' + $args[0].Groups[1].Value + ' AS double precision)') })

  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bDECIMAL\s*\(\s*([^,]+?)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
            { $('CAST(' + $args[0].Groups[1].Value + ' AS numeric(' + $args[0].Groups[2].Value + ',' + $args[0].Groups[3].Value + '))') })

  # 4) Formatting functions
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, "(?is)\bVARCHAR_FORMAT\s*\(\s*([^,]+?)\s*,\s*'([^']*)'\s*\)",
            { 'to_char(' + $args[0].Groups[1].Value + ", '" + $args[0].Groups[2].Value + "')" }
        )

  # Dates/timestamps via CHAR()
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bCHAR\s*\(\s*([^)]+?\b(date|timestamp)\b[^)]*)\)',
            { 'to_char(' + $args[0].Groups[1].Value + ", 'YYYY-MM-DD')" }
        )

  # Generic CHAR(expr)
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bCHAR\s*\(\s*([^)]+?)\s*\)', { 'CAST(' + $args[0].Groups[1].Value + ' AS char)' })

  # FETCH FIRST n ROWS ONLY -> allowed in Postgres; leave as-is.
  # To force LIMIT n instead:
  # $sql = $sql -replace '(?is)\bFETCH\s+FIRST\s+(\d+)\s+ROWS?\s+ONLY\b', 'LIMIT $1'

  return $sql
}

# OPTIONAL: minimal “nice lines” formatter (off unless -UseFormatter)
function Format-Sql {
  param([string]$sql)
  $s = $sql

  # Insert newlines before major clauses (case-insensitive)
  $s = [regex]::Replace($s, '(?i)\b(select|from|where|group\s+by|having|order\s+by|union\s+all|union|except|intersect)\b', "`n$1")
  # Put AND/OR on their own lines when in WHERE/HAVING
  $s = [regex]::Replace($s, '(?i)\s+(and|or)\s+', "`n$1 ")
  # Newline after commas in SELECT lists (rough heuristic)
  $s = [regex]::Replace($s, '(?i)(select\s+)(.+?)(\s+from\b)', {
      $sel = $args[0].Groups[1].Value
      $cols = $args[0].Groups[2].Value -replace '\s*,\s*', ",`n  "
      $frm = $args[0].Groups[3].Value
      "$sel`n  $cols`n$frm"
  })

  # Clean up extra blank lines
  $s = $s -replace '(`r?`n){3,}', "`n`n"
  $s.Trim()
}

Get-ChildItem -Path $InputFolder -Filter *.xml -File -Recurse | ForEach-Object {
  $inFile  = $_.FullName
  $outFile = Join-Path $OutputFolder $_.Name
  $bakFile = Join-Path $BackupFolder $_.Name

  # Load with whitespace preserved
  $raw = Get-Content -LiteralPath $inFile -Raw
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.LoadXml($raw)

  $sqlNodes = $doc.SelectNodes("//*[local-name()='sqlText']")

  if ($sqlNodes -and $sqlNodes.Count -gt 0) {
    if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $bakFile -Force }
    $changed = $false

    foreach ($node in $sqlNodes) {
      $hadCdata = $false
      foreach ($child in $node.ChildNodes) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::CData) { $hadCdata = $true; break }
      }

      $orig  = $node.InnerText
      $fixed = Fix-SqlForPostgres $orig
      if ($UseFormatter) { $fixed = Format-Sql $fixed }

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
      $doc.Save($outFile)
      if ($changed) {
        Write-Host "Updated: $outFile" -ForegroundColor Green
      } else {
        Write-Host "No SQL changes: $inFile" -ForegroundColor DarkGray
      }
    }
  } else {
    if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $outFile -Force }
    Write-Host "No <sqlText> nodes: $inFile" -ForegroundColor DarkGray
  }
}

Write-Host "Done." -ForegroundColor Cyan