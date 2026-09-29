param(
    [Parameter(Mandatory)] [string]$InFile,
    [int]$MinLen   = 0,        # 0 = auto: dominant width minus $Slack
    [int]$Slack    = 5,
    [int]$MaxParts = 5,
    [switch]$ShowText,         # print the fragment text too
    [string]$ReportFile        # optional CSV output
)

# Pass 1: count lines and find the dominant record width (footer excluded)
$lens  = @{}
$total = 0
$prevLen = $null
foreach ($l in [IO.File]::ReadLines($InFile)) {
    if ($null -ne $prevLen) { $lens[$prevLen]++ }   # lags one line so the footer is never counted
    $prevLen = $l.Length
    $total++
}
if ($MinLen -le 0) {
    $dominant = $lens.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $MinLen = $dominant.Name - $Slack
    "Dominant record length: $($dominant.Name) ($($dominant.Value) lines). Using MinLen = $MinLen"
}
"Total lines: $total (line $total treated as footer and skipped)"

# Pass 2: find split records, stopping before the footer
$results = [Collections.Generic.List[object]]::new()
$n = 0; $buf = $null; $start = 0; $parts = 0; $partLines = $null

foreach ($line in [IO.File]::ReadLines($InFile)) {
    $n++
    if ($n -eq $total) { break }                    # footer, skip it

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

# A short record left over right before the footer
if ($null -ne $buf) {
    $last = $n - 1
    $results.Add([pscustomobject]@{ StartLine=$start; EndLine=$last; Parts=$parts; MergedLen=$buf.Length; Status='SHORT_BEFORE_FOOTER' })
    "Lines $start-$last : short record before footer (len $($buf.Length)) [SHORT_BEFORE_FOOTER]"
    if ($ShowText) { $partLines }
}

"`nSplit records found: $($results.Count)"
if ($ReportFile) { $results | Export-Csv $ReportFile -NoTypeInformation; "Report: $ReportFile" }
