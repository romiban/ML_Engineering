# =====================================================================
# Script: Update-CognosSql.ps1
# Purpose: Convert DB2-flavored SQL in Cognos XML <sqlText> → Postgres.
# Output: backups in "<input>\_backup\Report.xml"
#         updated  in "<input>\_updated\Report_pgs.xml"
# Notes : Skips files in _backup/_updated and skips *_pgs.xml inputs.
# =====================================================================

param(
  [Parameter(Mandatory = $true)][string]$InputFolder,
  [string]$OutputFolder = "$InputFolder\_updated",
  [switch]$WhatIf,
  [switch]$UseFormatter
)

$BackupFolder = "$InputFolder\_backup"
New-Item -ItemType Directory -Force -Path $OutputFolder, $BackupFolder | Out-Null

function Fix-SqlForPostgres {
  param([string]$sql)

  # 1) DB2 hint
  $sql = $sql -replace '(?is)\s+with\s+ur\b', ''

  # 2) Date/time arithmetic
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
  $sql = $sql -replace '(?is)\bcurrent\s+timestamp\b', 'now()'

  # 3) Casts / types
  $sql = [regex]::Replace($sql, '(?is)\bDATE\s*\(\s*([^)]+?)\s*\)',      { $('('+$args[0].Groups[1].Value+')::date') })
  $sql = [regex]::Replace($sql, '(?is)\bTIMESTAMP\s*\(\s*([^)]+?)\s*\)', { $('('+$args[0].Groups[1].Value+')::timestamp') })
  $sql = [regex]::Replace($sql, '(?is)\bINTEGER\s*\(\s*([^)]+?)\s*\)',   { $('CAST('+$args[0].Groups[1].Value+' AS integer)') })
  $sql = [regex]::Replace($sql, '(?is)\bBIGINT\s*\(\s*([^)]+?)\s*\)',    { $('CAST('+$args[0].Groups[1].Value+' AS bigint)') })
  $sql = [regex]::Replace($sql, '(?is)\bDOUBLE\s*\(\s*([^)]+?)\s*\)',    { $('CAST('+$args[0].Groups[1].Value+' AS double precision)') })
  $sql = [regex]::Replace(
           $sql, '(?is)\bDECIMAL\s*\(\s*([^,]+?)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
           { $('CAST('+$args[0].Groups[1].Value+' AS numeric('+$args[0].Groups[2].Value+','+$args[0].Groups[3].Value+'))') })

  # 4) Formatting helpers
  $sql = [regex]::Replace(
           $sql, "(?is)\bVARCHAR_FORMAT\s*\(\s*([^,]+?)\s*,\s*'([^']*)'\s*\)",
           { 'to_char('+$args[0].Groups[1].Value+", '"+$args[0].Groups[2].Value+"')" })
  $sql = [regex]::Replace(
           $sql, '(?is)\bCHAR\s*\(\s*([^)]+?\b(date|timestamp)\b[^)]*)\)',
           { 'to_char('+$args[0].Groups[1].Value+", 'YYYY-MM-DD')" })
  $sql = [regex]::Replace(
           $sql, '(?is)\bCHAR\s*\(\s*([^)]+?)\s*\)',
           { 'CAST('+$args[0].Groups[1].Value+' AS char)' })

  return $sql
}

function Format-Sql {
  param([string]$sql)
  $s = $sql
  $s = [regex]::Replace($s, '(?i)\b(select|from|where|group\s+by|having|order\s+by|union\s+all|union|except|intersect)\b', "`n$1")
  $s = [regex]::Replace($s, '(?i)\s+(and|or)\s+', "`n$1 ")
  $s = [regex]::Replace($s, '(?i)(select\s+)(.+?)(\s+from\b)', {
      $sel = $args[0].Groups[1].Value
      $cols = $args[0].Groups[2].Value -replace '\s*,\s*', ",`n  "
      $frm = $args[0].Groups[3].Value
      "$sel`n  $cols`n$frm"
  })
  $s = $s -replace '(`r?`n){3,}', "`n`n"
  $s.Trim()
}

# --------- ONLY enumerate original input XMLs (not _backup/_updated) ----------
Get-ChildItem -Path $InputFolder -Filter *.xml -File -Recurse |
  Where-Object {
    # skip anything inside _backup or _updated folders
    $_.FullName -notmatch '[\\/]_backup[\\/]'
    -and $_.FullName -notmatch '[\\/]_updated[\\/]'
    # skip files that already look like outputs
    -and $_.Name -notmatch '_pgs\.xml$'
  } |
  ForEach-Object {
    $inFile   = $_.FullName
    $baseName = [IO.Path]::GetFileNameWithoutExtension($_.Name)
    $outFile  = Join-Path $OutputFolder ($baseName + '_pgs.xml')
    $bakFile  = Join-Path $BackupFolder $_.Name

    # Always back up original once with original name
    if (-not $WhatIf) { Copy-Item -LiteralPath $inFile -Destination $bakFile -Force }

    # Load & transform
    $raw = Get-Content -LiteralPath $inFile -Raw
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($raw)

    $sqlNodes = $doc.SelectNodes("//*[local-name()='sqlText']")
    $changed = $false

    if ($sqlNodes -and $sqlNodes.Count -gt 0) {
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
    } else {
      Write-Host "No <sqlText> nodes: $inFile" -ForegroundColor DarkGray
    }

    # Save updated copy (always one _pgs.xml in _updated)
    if (-not $WhatIf) {
      $doc.Save($outFile)
      if ($changed) {
        Write-Host "Updated: $outFile" -ForegroundColor Green
      } else {
        Write-Host "No SQL changes (saved copy for consistency): $outFile" -ForegroundColor DarkGray
      }
    } else {
      Write-Host "Would write: $outFile" -ForegroundColor Yellow
    }
  }

Write-Host "Done." -ForegroundColor Cyan
