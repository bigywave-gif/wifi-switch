$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path $PSScriptRoot -Parent
Set-Location $WindowsRoot
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
New-Item -ItemType Directory -Force artifacts, dist | Out-Null
dotnet run --project tests/WiFiSwitch.Tests -c Release
if ($LASTEXITCODE -ne 0) { throw 'Core tests failed' }
dotnet publish src/WiFiSwitch.Windows -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false -o artifacts/publish
if ($LASTEXITCODE -ne 0) { throw 'Publish failed' }
Copy-Item README.md artifacts/publish/README.txt -Force
$Makensis = (Get-Command makensis.exe -ErrorAction SilentlyContinue).Source
if (-not $Makensis) { $Makensis = "${env:ProgramFiles(x86)}\NSIS\makensis.exe" }
& $Makensis /DVERSION=0.1.10 "/DPAYLOAD=$WindowsRoot\artifacts\publish" `
    "/DOUTPUT=$WindowsRoot\dist\WiFi-Switch-0.1.10-windows-x64-setup.exe" installer/WiFiSwitch.nsi
if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
$Installer = Join-Path $WindowsRoot 'dist\WiFi-Switch-0.1.10-windows-x64-setup.exe'
$Hash = (Get-FileHash $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$Hash  WiFi-Switch-0.1.10-windows-x64-setup.exe" | Set-Content "$Installer.sha256" -Encoding ascii
Write-Host "Built: $Installer"
