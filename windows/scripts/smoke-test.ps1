param([string]$AppPath = "$env:LOCALAPPDATA\Programs\WiFi Switch\WiFiSwitch.exe")
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $AppPath)) { throw "Application not found: $AppPath" }
$Report = Join-Path $env:TEMP ("WiFiSwitch-selftest-" + [guid]::NewGuid().ToString('N') + '.json')
$Process = Start-Process -FilePath $AppPath -ArgumentList @('--self-test', "`"$Report`"") -PassThru -Wait
if (-not (Test-Path $Report)) { throw 'Self-test did not produce its report' }
$Result = Get-Content $Report -Raw | ConvertFrom-Json
$Result | ConvertTo-Json -Depth 8
if ($Process.ExitCode -ne 0 -or -not $Result.success) { throw "Self-test failed; see $Report" }
Write-Host "PASS: Windows Credential Manager and persistence. No real Wi-Fi operation. Report: $Report"
