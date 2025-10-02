# =====================================================================
# Script: Update-CognosSql.ps1
# Purpose: Scan Cognos XML reports, find <sqlText> nodes, and convert
#          DB2-flavored SQL into PostgreSQL-compatible SQL.
# Notes:
#   - Backups of originals go to "<input>\_backup\Report.xml".
#   - Updated files go to "<input>\_updated\Report_pgs.xml".
#   - Use -WhatIf to preview transformations without writing files.
#   - Use -UseFormatter to lightly pretty-print the resulting SQL.
# Author: (you)
# =====================================================================

param(
  # Input folder (e.g., XML) where new Cognos XML reports are dropped
  [Parameter(Mandatory = $true)][string]$InputFolder,

  # Output folder for updated files (separate from input)
  [string]$OutputFolder = "$InputFolder\_updated",

  # Preview-only mode: do not write files, just show diffs
  [switch]$WhatIf,

  # Optional: make SQL more readable (line breaks, indentation)
  [switch]$UseFormatter
)

# Backup folder sits under the input directory
$BackupFolder = "$InputFolder\_backup"
# Ensure both folders exist
New-Item -ItemType Directory -Force -Path $OutputFolder, $BackupFolder | Out-Null


# =====================================================================
# Function: Fix-SqlForPostgres
# Purpose : Apply regex-based rewrites to transform DB2 SQL → Postgres
# =====================================================================
function Fix-SqlForPostgres {
  param([string]$sql)

  # -------------------------------------------------------------------
  # 1) DB2 optimizer hints
  # -------------------------------------------------------------------
  # Remove DB2 "WITH UR" (uncommitted read) which Postgres doesn’t support
  # Example: "... FROM mytable WITH UR" → "... FROM mytable"
  $sql = $sql -replace '(?is)\s+with\s+ur\b', ''

  # -------------------------------------------------------------------
  # 2) Date/time arithmetic conversions
  # -------------------------------------------------------------------
  $cd = '(?i)\bcurrent[_\s]?date\b'   # matches "current_date" or "current date"

  # DB2 sometimes uses "+ -1" instead of "- 1"
  # Example: current_date + -1 DAY → current_date - INTERVAL '1 day'
  $sql = $sql -replace "$cd\s*\+\s*-1\s+day\b",   "current_date - INTERVAL '1 day'"
  $sql = $sql -replace "$cd\s*\+\s*-1\s+month\b", "current_date - INTERVAL '1 month'"
  $sql = $sql -replace "$cd\s*\+\s*-1\s+year\b",  "current_date - INTERVAL '1 year'"

  # Generic +/- forms
  # Example: current_date + 5 DAYS → current_date + INTERVAL '5 day'
  # Example: current_date - 2 MONTHS → current_date - INTERVAL '2 month'
  $sql = $sql -replace "$cd\s*\+\s*(\d+)\s+day(s)?\b",   "current_date + INTERVAL '$1 day'"
  $sql = $sql -replace "$cd\s*\-\s*(\d+)\s+day(s)?\b",   "current_date - INTERVAL '$1 day'"
  $sql = $sql -replace "$cd\s*\+\s*(\d+)\s+month(s)?\b", "current_date + INTERVAL '$1 month'"
  $sql = $sql -replace "$cd\s*\-\s*(\d+)\s+month(s)?\b", "current_date - INTERVAL '$1 month'"
  $sql = $sql -replace "$cd\s*\+\s*(\d+)\s+year(s)?\b",  "current_date + INTERVAL '$1 year'"
  $sql = $sql -replace "$cd\s*\-\s*(\d+)\s+year(s)?\b",  "current_date - INTERVAL '$1 year'"

  # Replace CURRENT TIMESTAMP with Postgres equivalent
  # Example: CURRENT TIMESTAMP → now()
  $sql = $sql -replace '(?is)\bcurrent\s+timestamp\b', 'now()'

  # -------------------------------------------------------------------
  # 3) CASTs / Types
  # -------------------------------------------------------------------

  # DATE(expr) → (expr)::date
  # Example: DATE(my_col) → (my_col)::date
  $sql = [regex]::Replace($sql, '(?is)\bDATE\s*\(\s*([^)]+?)\s*\)',
           { $('(' + $args[0].Groups[1].Value + ')::date') })

  # TIMESTAMP(expr) → (expr)::timestamp
  # Example: TIMESTAMP(order_date) → (order_date)::timestamp
  $sql = [regex]::Replace($sql, '(?is)\bTIMESTAMP\s*\(\s*([^)]+?)\s*\)',
           { $('(' + $args[0].Groups[1].Value + ')::timestamp') })

  # INTEGER(expr) → CAST(expr AS integer)
  # Example: INTEGER(price) → CAST(price AS integer)
  $sql = [regex]::Replace($sql, '(?is)\bINTEGER\s*\(\s*([^)]+?)\s*\)',
           { $('CAST(' + $args[0].Groups[1].Value + ' AS integer)') })

  # BIGINT(expr) → CAST(expr AS bigint)
  # Example: BIGINT(user_id) → CAST(user_id AS bigint)
  $sql = [regex]::Replace($sql, '(?is)\bBIGINT\s*\(\s*([^)]+?)\s*\)',
           { $('CAST(' + $args[0].Groups[1].Value + ' AS bigint)') })

  # DOUBLE(expr) → CAST(expr AS double precision)
  # Example: DOUBLE(salary) → CAST(salary AS double precision)
  $sql = [regex]::Replace($sql, '(?is)\bDOUBLE\s*\(\s*([^)]+?)\s*\)',
           { $('CAST(' + $args[0].Groups[1].Value + ' AS double precision)') })

  # DECIMAL(expr, p, s) → CAST(expr AS numeric(p,s))
  # Example: DECIMAL(amount, 10, 2) → CAST(amount AS numeric(10,2))
  $sql = [regex]::Replace($sql, '(?is)\bDECIMAL\s*\(\s*([^,]+?)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
           { $('CAST(' + $args[0].Groups[1].Value + ' AS numeric(' +
                  $args[0].Groups[2].Value + ',' + $args[0].Groups[3].Value + '))') })

  # -------------------------------------------------------------------
  # 4) Formatting helpers
  # -------------------------------------------------------------------

  # VARCHAR_FORMAT(expr, 'fmt') → to_char(expr, 'fmt')
  # Example: VARCHAR_FORMAT(order_date, 'YYYY-MM-DD') → to_char(order_date, 'YYYY-MM-DD')
  $sql = [regex]::Replace($sql, "(?is)\bVARCHAR_FORMAT\s*\(\s*([^,]+?)\s*,\s*'([^']*)'\s*\)",
           { 'to_char(' + $args[0].Groups[1].Value + ", '" + $args[0].Groups[2].Value + "')" })

  # CHAR(date/timestamp_expr) → to_char(expr, 'YYYY-MM-DD')
  # Example: CHAR(order_date) → to_char(order_date, 'YYYY-MM-DD')
  $sql = [regex]::Replace($sql, '(?is)\bCHAR\s*\(\s*([^)]+?\b(date|timestamp)\b[^)]*)\)',
           { 'to_char(' + $args[0].Groups[1].Value + ", 'YYYY-MM-DD')" })

  # CHAR(expr) → CAST(expr AS char)   (generic fallback)
  # Example: CHAR(customer_id) → CAST(customer_id AS char)
  $sql = [regex]::Replace($sql, '(?is)\bCHAR\s*\(\s*([^)]+?)\s*\)',
           { 'CAST(' + $args[0].Groups[1].Value + ' AS char)' })

  # FETCH FIRST n ROWS ONLY is valid in Postgres → no change

  return $sql
}


# =====================================================================
# Function: Format-Sql (Optional pretty-printer for readability)
# =====================================================================
function Format-Sql {
  param([string]$sql)
  $s = $sql

  # Insert newline before major SQL clauses
  # Example: "...SELECT...FROM..." → "...SELECT\nFROM..."
  $s = [regex]::Replace($s,
        '(?i)\b(select|from|where|group\s+by|having|order\s+by|union\s+all|union|except|intersect)\b',
        "`n$1")

  # Place AND/OR on their own lines
  # Example: "... WHERE a=1 AND b=2" → "... WHERE a=1\nAND b=2"
  $s = [regex]::Replace($s, '(?i)\s+(and|or)\s+', "`n$1 ")

  # Break SELECT lists into multiple lines at commas
  # Example: "SELECT a,b,c FROM..." → "SELECT\n  a,\n  b,\n  c\nFROM..."
  $s = [regex]::Replace($s, '(?i)(select\s+)(.+?)(\s+from\b)', {
      $sel = $args[0].Groups[1].Value
      $cols = $args[0].Groups[2].Value -replace '\s*,\s*', ",`n  "
      $frm = $args[0].Groups[3].Value
      "$sel`n  $cols`n$frm"
  })

  # Collapse triple blank lines to just one
  $s = $s -replace '(`r?`n){3,}', "`n`n"
  $s.Trim()
}


# =====================================================================
# Main: process XML reports in $InputFolder (no recursion)
# =====================================================================
Get-ChildItem -Path $InputFolder -Filter *.xml -File | ForEach-Object {
  $inFile   = $_.FullName
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
  $outFile  = Join-Path $OutputFolder ($baseName + '_pgs.xml')
  $bakFile  = Join-Path $BackupFolder $_.Name

  # Always back up original file to _backup with original name
  if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $bakFile -Force }

  # Load XML with whitespace preserved
  $raw = Get-Content -LiteralPath $inFile -Raw
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.LoadXml($raw)

  # Find all <sqlText> nodes
  $sqlNodes = $doc.SelectNodes("//*[local-name()='sqlText']")
  $changed = $false

  if ($sqlNodes -and $sqlNodes.Count -gt 0) {
    foreach ($node in $sqlNodes) {
      # Check if SQL is wrapped in CDATA (preserve it if so)
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
          # Replace text, keeping CDATA if it was used
          $node.RemoveAll() | Out-Null
          if ($hadCdata) { $null = $node.AppendChild($doc.CreateCDataSection($fixed)) }
          else           { $null = $node.AppendChild($doc.CreateTextNode($fixed)) }
        }
      }
    }
  } else {
    Write-Host "No <sqlText> nodes in: $inFile" -ForegroundColor DarkGray
  }

  # Save updated file with "_pgs.xml" suffix into _updated
  if (-not $WhatIf) {
    $doc.Save($outFile)
    if ($changed) {
      Write-Host "Updated: $outFile" -ForegroundColor Green
    } else {
      Write-Host "No SQL changes (copied with suffix): $outFile" -ForegroundColor DarkGray
    }
  } else {
    Write-Host "Would write: $outFile" -ForegroundColor Yellow
  }
}

Write-Host "Done." -ForegroundColor Cyan
