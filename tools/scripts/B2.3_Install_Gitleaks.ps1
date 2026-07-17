[CmdletBinding()]
param(
    [string]$Version = "8.30.1",
    [string]$InstallRoot = "$env:LOCALAPPDATA\SQD\tools\gitleaks"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Destination = Join-Path $InstallRoot $Version
$Executable = Join-Path $Destination "gitleaks.exe"
if (Test-Path $Executable -PathType Leaf) { & $Executable version; Write-Host $Executable; exit 0 }
$Headers = @{Accept="application/vnd.github+json";"X-GitHub-Api-Version"="2022-11-28";"User-Agent"="SQD-B2.3"}
$Release = Invoke-RestMethod "https://api.github.com/repos/gitleaks/gitleaks/releases/tags/v$Version" -Headers $Headers
$Zip = $Release.assets | Where-Object name -match 'windows_x64\.zip$' | Select-Object -First 1
$Checksums = $Release.assets | Where-Object name -match 'checksums\.txt$' | Select-Object -First 1
if (-not $Zip -or -not $Checksums) { throw "Required official release assets were not found." }
$Temp = Join-Path $env:TEMP "SQD_B2.3_gitleaks_$Version"
Remove-Item $Temp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Temp -Force | Out-Null
$ZipPath = Join-Path $Temp $Zip.name
$ChecksumPath = Join-Path $Temp $Checksums.name
Invoke-WebRequest $Zip.browser_download_url -OutFile $ZipPath
Invoke-WebRequest $Checksums.browser_download_url -OutFile $ChecksumPath
$Line = Get-Content $ChecksumPath | Where-Object { $_ -match [regex]::Escape($Zip.name) } | Select-Object -First 1
if (-not $Line) { throw "Checksum entry not found for $($Zip.name)." }
$Expected = (($Line -split '\s+')[0]).ToUpperInvariant()
$Actual = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($Expected -ne $Actual) { throw "Checksum mismatch. Expected $Expected; actual $Actual." }
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
Expand-Archive $ZipPath -DestinationPath $Destination -Force
if (-not (Test-Path $Executable -PathType Leaf)) { throw "gitleaks.exe was not extracted." }
& $Executable version
if ($LASTEXITCODE -ne 0) { throw "Installed Gitleaks failed its version check." }
Write-Host "Installed: $Executable" -ForegroundColor Green
Write-Host "Archive SHA256: $Actual"
Remove-Item $Temp -Recurse -Force -ErrorAction SilentlyContinue
exit 0
