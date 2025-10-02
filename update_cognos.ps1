# =====================================================================
# Script: Update-CognosSql.ps1
# Purpose: Scan Cognos XML reports, find <sqlText> nodes, and convert
#          DB2-flavored SQL into PostgreSQL-compatible SQL.
# Notes:
#   - Safe by default: makes a backup copy of each input file.
#   - Use -WhatIf to preview transformations without writing files.
#   - Use -UseFormatter to lightly pretty-print the resulting SQL.
# Author: (you)
# =====================================================================

param(
  # Folder containing Cognos XML report files
  [Parameter(Mandatory = $true)][string]$InputFolder,

  # Where to write the updated XML files
  [string]$OutputFolder = "$InputFolder\_updated",

  # Preview only: do not write output files; just print diffs
  [switch]$WhatIf,

  # Optional readability: add line breaks/indentation to SQL
  [switch]$UseFormatter
)

# Create output + backup folders if they don't exist
$BackupFolder = "$InputFolder\_backup"
New-Item -ItemType Directory -Force -Path $OutputFolder, $BackupFolder | Out-Null


# =====================================================================
# Function: Fix-SqlForPostgres
# Purpose : Apply regex-based rewrites to transform DB2 SQL → Postgres
#           while keeping original whitespace unless -UseFormatter set.
# =====================================================================
function Fix-SqlForPostgres {
  param([string]$sql)

  # -------------------------------------------------------------------
  # 1) DB2 optimizer hints
  # -------------------------------------------------------------------
  # Remove DB2 "WITH UR" (uncommitted read) clause which Postgres ignores.
  # Example: "... FROM t WITH UR"  →  "... FROM t"
  $sql = $sql -replace '(?is)\s+with\s+ur\b', ''

  # -------------------------------------------------------------------
  # 2) Date/time arithmetic
  #    Normalize (current_date +/- N {day|month|year}) to Postgres INTERVAL
  # -------------------------------------------------------------------
  $cd = '(?i)\bcurrent[_\s]?date\b'   # matches current_date / current date

  # Handle the DB2 pattern using "+ -1" (e.g., current_date + -1 DAY)
  # (current_date + -1 DAY)   → current_date - INTERVAL '1 day'
  # (current_date + -1 MONTH) → current_date - INTERVAL '1 month'
  # (current_date + -1 YEAR)  → current_date - INTERVAL '1 year'
  $sql = $sql -replace "$cd\s*\+\s*-1\s+day\b",   "current_date - INTERVAL '1 day'"
  $sql = $sql -replace "$cd\s*\+\s*-1\s+month\b", "current_date - INTERVAL '1 month'"
  $sql = $sql -replace "$cd\s*\+\s*-1\s+year\b",  "current_date - INTERVAL '1 year'"

  # Generic +/- N forms
  # current_date + 5 DAYS  → current_date + INTERVAL '5 day'
  # current_date - 2 MONTHS → current_date - INTERVAL '2 month'
  $sql = $sql -replace "$cd\s*\+\s*(\d+)\s+day(s)?\b",   "current_date + INTERVAL '$1 day'"
  $sql = $sql -replace "$cd\s*\-\s*(\d+)\s+day(s)?\b",   "current_date - INTERVAL '$1 day'"
  $sql = $sql -replace "$cd\s*\+\s*(\d+)\s+month(s)?\b", "current_date + INTERVAL '$1 month'"
  $sql = $sql -replace "$cd\s*\-\s*(\d+)\s+month(s)?\b", "current_date - INTERVAL '$1 month'"
  $sql = $sql -replace "$cd\s*\+\s*(\d+)\s+year(s)?\b",  "current_date + INTERVAL '$1 year'"
  $sql = $sql -replace "$cd\s*\-\s*(\d+)\s+year(s)?\b",  "current_date - INTERVAL '$1 year'"

  # CURRENT TIMESTAMP → now() (Postgres builtin)
  # Example: CURRENT TIMESTAMP → now()
  $sql = $sql -replace '(?is)\bcurrent\s+timestamp\b', 'now()'

  # -------------------------------------------------------------------
  # 3) CASTs / types  (DB2 → Postgres)
  #     Each block below shows:   DB2 input  →  Postgres output
  # -------------------------------------------------------------------

  # DATE(expr) → (expr)::date
  # Example: DATE(my_col) → (my_col)::date
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bDATE\s*\(\s*([^)]+?)\s*\)',
            { $('(' + $args[0].Groups[1].Value + ')::date') })

  # TIMESTAMP(expr) → (expr)::timestamp
  # Example: TIMESTAMP(order_date) → (order_date)::timestamp
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bTIMESTAMP\s*\(\s*([^)]+?)\s*\)',
            { $('(' + $args[0].Groups[1].Value + ')::timestamp') })

  # INTEGER(expr) → CAST(expr AS integer)
  # Example: INTEGER(price) → CAST(price AS integer)
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bINTEGER\s*\(\s*([^)]+?)\s*\)',
            { $('CAST(' + $args[0].Groups[1].Value + ' AS integer)') })

  # BIGINT(expr) → CAST(expr AS bigint)
  # Example: BIGINT(user_id) → CAST(user_id AS bigint)
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bBIGINT\s*\(\s*([^)]+?)\s*\)',
            { $('CAST(' + $args[0].Groups[1].Value + ' AS bigint)') })

  # DOUBLE(expr) → CAST(expr AS double precision)
  # Example: DOUBLE(salary) → CAST(salary AS double precision)
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bDOUBLE\s*\(\s*([^)]+?)\s*\)',
            { $('CAST(' + $args[0].Groups[1].Value + ' AS double precision)') })

  # DECIMAL(expr, p, s) → CAST(expr AS numeric(p,s))
  # Example: DECIMAL(amount, 10, 2) → CAST(amount AS numeric(10,2))
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bDECIMAL\s*\(\s*([^,]+?)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
            { $('CAST(' + $args[0].Groups[1].Value + ' AS numeric(' + $args[0].Groups[2].Value + ',' + $args[0].Groups[3].Value + '))') })

  # -------------------------------------------------------------------
  # 4) Formatting helpers  (DB2 → Postgres)
  # -------------------------------------------------------------------

  # VARCHAR_FORMAT(expr, 'fmt') → to_char(expr, 'fmt')
  # Example: VARCHAR_FORMAT(order_date,'YYYY-MM-DD') → to_char(order_date,'YYYY-MM-DD')
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, "(?is)\bVARCHAR_FORMAT\s*\(\s*([^,]+?)\s*,\s*'([^']*)'\s*\)",
            { 'to_char(' + $args[0].Groups[1].Value + ", '" + $args[0].Groups[2].Value + "')" })

  # CHAR(expr) when expr is date/timestamp → to_char(expr,'YYYY-MM-DD')
  # Example: CHAR(order_date) → to_char(order_date,'YYYY-MM-DD')
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bCHAR\s*\(\s*([^)]+?\b(date|timestamp)\b[^)]*)\)',
            { 'to_char(' + $args[0].Groups[1].Value + ", 'YYYY-MM-DD')" })

  # Generic CHAR(expr) → CAST(expr AS char)
  # Example: CHAR(customer_id) → CAST(customer_id AS char)
  $sql = [System.Text.RegularExpressions.Regex]::Replace(
            $sql, '(?is)\bCHAR\s*\(\s*([^)]+?)\s*\)',
            { 'CAST(' + $args[0].Groups[1].Value + ' AS char)' })

  # Note: DB2 "FETCH FIRST n ROWS ONLY" is accepted by Postgres; no change.

  return $sql
}


# =====================================================================
# Function: Format-Sql
# Purpose : Optional, lightweight pretty-printer for readability only.
#           (Does not alter semantics—just adds line breaks.)
# =====================================================================
function Format-Sql {
  param([string]$sql)
  $s = $sql

  # Newline before common clauses (case-insensitive)
  $s = [regex]::Replace(
        $s, '(?i)\b(select|from|where|group\s+by|having|order\s+by|union\s+all|union|except|intersect)\b',
        "`n$1")

  # Put AND/OR on their own lines
  $s = [regex]::Replace($s, '(?i)\s+(and|or)\s+', "`n$1 ")

  # Break up SELECT column lists after commas
  $s = [regex]::Replace($s, '(?i)(select\s+)(.+?)(\s+from\b)', {
      $sel = $args[0].Groups[1].Value
      $cols = $args[0].Groups[2].Value -replace '\s*,\s*', ",`n  "
      $frm = $args[0].Groups[3].Value
      "$sel`n  $cols`n$frm"
  })

  # Collapse excessive blank lines
  $s = $s -replace '(`r?`n){3,}', "`n`n"
  $s.Trim()
}


# =====================================================================
# Main: enumerate XML files, update <sqlText>, write outputs/backups
# =====================================================================
Get-ChildItem -Path $InputFolder -Filter *.xml -File -Recurse | ForEach-Object {
  $inFile  = $_.FullName
  $outFile = Join-Path $OutputFolder $_.Name
  $bakFile = Join-Path $BackupFolder $_.Name

  # Load XML with whitespace preserved so Cognos structure stays intact
  $raw = Get-Content -LiteralPath $inFile -Raw
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.LoadXml($raw)

  # Target all <sqlText> nodes regardless of namespace
  $sqlNodes = $doc.SelectNodes("//*[local-name()='sqlText']")

  if ($sqlNodes -and $sqlNodes.Count -gt 0) {
    # Keep original as backup unless -WhatIf
    if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $bakFile -Force }

    $changed = $false

    foreach ($node in $sqlNodes) {
      # Remember whether the SQL was wrapped in CDATA so we can preserve it
      $hadCdata = $false
      foreach ($child in $node.ChildNodes) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::CData) { $hadCdata = $true; break }
      }

      # Original SQL text
      $orig  = $node.InnerText

      # Apply DB2 → Postgres rewrites
      $fixed = Fix-SqlForPostgres $orig
      if ($UseFormatter) { $fixed = Format-Sql $fixed }

      if ($fixed -ne $orig) {
        $changed = $true
        if ($WhatIf) {
          # Dry-run: show before/after but do not modify file
          Write-Host "Would change $inFile" -ForegroundColor Yellow
          Write-Host "Old SQL:`n$orig" -ForegroundColor DarkGray
          Write-Host "New SQL:`n$fixed" -ForegroundColor Green
        } else {
          # Replace node content, preserving CDATA vs text
          $node.RemoveAll() | Out-Null
          if ($hadCdata) { $null = $node.AppendChild($doc.CreateCDataSection($fixed)) }
          else           { $null = $node.AppendChild($doc.CreateTextNode($fixed)) }
        }
      }
    }

    # Write updated XML (or just report no-op)
    if (-not $WhatIf) {
      $doc.Save($outFile)
      if ($changed) {
        Write-Host "Updated: $outFile" -ForegroundColor Green
      } else {
        Write-Host "No SQL changes: $inFile" -ForegroundColor DarkGray
      }
    }
  } else {
    # File has no <sqlText>; copy it through so the output tree mirrors input
    if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $outFile -Force }
    Write-Host "No <sqlText> nodes: $inFile" -ForegroundColor DarkGray
  }
}

Write-Host "Done." -ForegroundColor Cyan