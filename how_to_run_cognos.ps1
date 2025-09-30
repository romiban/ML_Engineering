# If scripts are restricted in your session:
# (You don't need admin rights for this one-time session)
powershell -ExecutionPolicy Bypass -File .\Update-CognosSql.ps1 -InputFolder "C:\Cognos\Specs" -WhatIf

# If the preview looks good, run for real:
powershell -ExecutionPolicy Bypass -File .\Update-CognosSql.ps1 -InputFolder "C:\Cognos\Specs"