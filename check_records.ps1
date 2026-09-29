param(
    [Parameter(Mandatory)] [string]$InFile,
    [int]$Context = 20,          # chars of text to show around the first bad char
    [string]$ReportFile          # optional CSV output
)

$latin1 = [Text.Encoding]::GetEncoding(28591)   # 1 byte = 1 char, never alters bytes
$reader = [IO.StreamReader]::new($InFile, $latin1, $false)
$rx     = [regex]'[^\x00-\x7F]+'
$results = [Collections.Generic.List[object]]::new()
$n = 0

try {
    while ($null -ne ($line = $reader.ReadLine())) {
        $n++
        $ms = $rx.Matches($line)
        if ($ms.Count -eq 0) { continue }

        foreach ($m in $ms) {
            $hex = ($latin1.GetBytes($m.Value) | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            $results.Add([pscustomobject]@{
                Line = $n; Column = $m.Index + 1; Bytes = $hex; LineLen = $line.Length
            })
        }

        $first = $ms[0]
        $s = [Math]::Max(0, $first.Index - $Context)
        $e = [Math]::Min($line.Length, $first.Index + $first.Length + $Context)
        $cols = ($ms | ForEach-Object { $_.Index + 1 }) -join ','
        $hexAll = ($ms | ForEach-Object { ($latin1.GetBytes($_.Value) | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }) -join ' | '
        "Line $n : col(s) $cols  bytes [$hexAll]  len $($line.Length)"
        "    ...$($line.Substring($s, $e - $s))..."
    }
}
finally { $reader.Dispose() }

"`nLines with non-ASCII bytes: $(($results | Select-Object -Unique Line).Count)   Total occurrences: $($results.Count)"
if ($ReportFile) { $results | Export-Csv $ReportFile -NoTypeInformation; "Report: $ReportFile" }
