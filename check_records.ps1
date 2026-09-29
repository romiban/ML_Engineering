param(
    [Parameter(Mandatory)] [string]$InFile,
    [int]$MinLen   = 0,        # 0 = auto: dominant width minus $Slack
    [int]$Slack    = 5,
    [int]$MaxParts = 5,
    [switch]$ShowText,         # print the fragment text too
    [string]$ReportFile        # optional CSV output
)

# Pass 1: auto-detect record width
if ($MinLen -le 0) {
    $lens = @{}
    foreach ($l in [IO.File]::ReadLines($InFile)) { $lens[$l.Length]++ }
    $dominant = ($lens.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    $MinLen = $dominant.Name - $Slack
    "Dominant record length: $($dominant.Name) ($($dominant.Value) lines). Using MinLen = $MinLen"
}

# Pass 2: find split records
$results = [Collections.Generic.List[object]]::new()
$n = 0; $buf = $null; $start = 0; $parts = 0; $partLines = $null

foreach ($line in [IO.File]::ReadLines($InFile)) {
    $n++
    if ($null -eq $buf) {
        $buf = $line; $start = $n; $parts = 1
        $partLines = [Collections.Generic.List[string]]::new()
    } else {
        $buf += ' ' + $line; $parts++
    }
    $partLines.Add("  L$n (len $($line.Length)): $line")

    if ($buf.Length -ge $MinLen -or $parts -ge $MaxParts) {
        if ($parts -gt 1) {
            $status = if ($buf.Length -lt $MinLen) { 'STILL_SHORT' } else { 'OK' }
            $results.Add([pscustomobject]@{
                StartLine = $start; EndLine = $n; Parts = $parts
                MergedLen = $buf.Length; Status = $status
            })
            "Lines $start-$n : $parts parts, merged len $($buf.Length) [$status]"
            if ($ShowText) { $partLines }
        }
        $buf = $null
    }
}
if ($null -ne $buf -and $parts -ge 1 -and $buf.Length -lt $MinLen) {
    $results.Add([pscustomobject]@{ StartLine=$start; EndLine=$n; Parts=$parts; MergedLen=$buf.Length; Status='EOF_SHORT' })
    "Lines $start-$n : short record at EOF (len $($buf.Length)) [EOF_SHORT]"
}

"`nTotal lines: $n   Split records found: $($results.Count)"
if ($ReportFile) { $results | Export-Csv $ReportFile -NoTypeInformation; "Report: $ReportFile" }


.\Find-SplitRows.ps1 -InFile D:\data\file.dat
.\Find-SplitRows.ps1 -InFile D:\data\file.dat -ShowText -ReportFile D:\data\split_report.csv
