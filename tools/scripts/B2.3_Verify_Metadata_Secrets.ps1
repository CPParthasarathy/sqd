[CmdletBinding()]
param(
    [string]$RepoRoot = "D:\OneDrive\SQD",
    [string]$GitExe = "D:\Programs\Git\cmd\git.exe",
    [string]$IDFPath = "D:\esp\v6.0.2\esp-idf",
    [string]$IDFToolsPath = "$env:USERPROFILE\.espressif"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Join-Path $RepoRoot "verification\b2_3_metadata"
$EvidenceDir = Join-Path $RepoRoot "docs\evidence\logs\B2.3"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$TranscriptPath = Join-Path $EvidenceDir "B2.3_verification_$Timestamp.txt"
$CsvPath = Join-Path $EvidenceDir "B2.3_verification_results_$Timestamp.csv"
$ManifestPath = Join-Path $EvidenceDir "B2.3_binary_metadata_manifest_$Timestamp.json"
$SecretReportPath = Join-Path $EvidenceDir "B2.3_gitleaks_history_$Timestamp.json"
$SecretLogPath = Join-Path $EvidenceDir "B2.3_gitleaks_history_$Timestamp.txt"
$ForbiddenPathReport = Join-Path $EvidenceDir "B2.3_forbidden_tracked_paths_$Timestamp.txt"
$Results = [System.Collections.Generic.List[object]]::new()
$TranscriptStarted = $false
$script:Version = $null
$script:PythonExe = $null
$script:GitleaksExe = $null

function Add-Result {
    param([string]$Check,[ValidateSet("PASS","FAIL")][string]$Result,[string]$Details)
    $Results.Add([pscustomobject]@{Timestamp=(Get-Date).ToString("s");Check=$Check;Result=$Result;Details=$Details})
    $Color = if ($Result -eq "PASS") { "Green" } else { "Red" }
    Write-Host "[$Result] $Check - $Details" -ForegroundColor $Color
}
function Test-Step {
    param([string]$Name,[scriptblock]$Action)
    try { Add-Result $Name "PASS" ([string](& $Action)) }
    catch { Add-Result $Name "FAIL" $_.Exception.Message }
}
function Git-Capture {
    param([string[]]$Arguments)
    $Output = & $GitExe -C $RepoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($Output -join ' ')" }
    (($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
}
function Resolve-Gitleaks {
    $Command = Get-Command gitleaks.exe -ErrorAction SilentlyContinue
    if ($Command) { return $Command.Source }
    $Root = Join-Path $env:LOCALAPPDATA "SQD\tools\gitleaks"
    $File = Get-ChildItem $Root -Filter gitleaks.exe -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($File) { return $File.FullName }
    throw "Gitleaks is missing. Run tools\scripts\B2.3_Install_Gitleaks.ps1."
}
function Invoke-Idf {
    param([string[]]$Arguments)
    Push-Location $ProjectRoot
    try {
        & $script:PythonExe (Join-Path $IDFPath "tools\idf.py") @Arguments
        if ($LASTEXITCODE -ne 0) { throw "idf.py $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
    } finally { Pop-Location }
}

New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null

try {
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
    $TranscriptStarted = $true
    Write-Host "B2.3 firmware metadata and secret-control verification"
    Write-Host "Repository: $RepoRoot"
    Write-Host "Project:    $ProjectRoot"
    Write-Host ""

    Test-Step "Committed feature-branch state" {
        $Branch = Git-Capture @("branch","--show-current")
        if ($Branch -eq "main") { throw "Run this acceptance check on the committed B2.3 feature branch." }
        $Changes = & $GitExe -C $RepoRoot status --porcelain --untracked-files=no
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect tracked files." }
        if ($Changes) { throw "Tracked files are modified: $($Changes -join '; ')" }
        "Branch=$Branch; tracked tree clean"
    }

    Test-Step "Semantic version" {
        $script:Version = (Get-Content (Join-Path $RepoRoot "VERSION") -Raw).Trim()
        $Pattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
        if ($script:Version -notmatch $Pattern) { throw "Invalid SemVer: $script:Version" }
        $script:Version
    }

    Test-Step "Required B2.3 files" {
        $Required = @(
            "components\build_metadata\CMakeLists.txt",
            "components\build_metadata\sqd_build_metadata.c",
            "components\build_metadata\include\sqd_build_metadata.h",
            "components\build_metadata\include\sqd_build_metadata_generated.h.in",
            "verification\b2_3_metadata\CMakeLists.txt",
            "verification\b2_3_metadata\main\CMakeLists.txt",
            "verification\b2_3_metadata\main\b2_3_metadata_main.c",
            ".gitleaks.toml", ".gitleaksignore",
            "docs\phase-b\B2.3_Firmware_Metadata_and_Secret_Controls.md"
        )
        $Missing = $Required | Where-Object { -not (Test-Path (Join-Path $RepoRoot $_) -PathType Leaf) }
        if ($Missing) { throw "Missing: $($Missing -join ', ')" }
        "$($Required.Count) files present"
    }

    Test-Step "ESP-IDF environment" {
        if (-not (Test-Path (Join-Path $IDFPath "export.ps1") -PathType Leaf)) { throw "ESP-IDF export.ps1 is missing." }
        $env:IDF_PATH = $IDFPath
        $env:IDF_TOOLS_PATH = $IDFToolsPath
        $env:ESP_IDF_VERSION = "6.0.2"
        $env:SQD_BUILD_PROFILE = "baseline"
        $env:SQD_HARDWARE_COMPATIBILITY = "heltec-wifi-lora-32-v3"
        . (Join-Path $IDFPath "export.ps1")
        $Python = Get-Command python.exe -ErrorAction Stop
        $script:PythonExe = $Python.Source
        $Output = & $script:PythonExe (Join-Path $IDFPath "tools\idf.py") --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "idf.py --version failed: $($Output -join ' ')" }
        "$($Output -join ' ') [$script:PythonExe]"
    }

    Test-Step "Clean ESP32-S3 metadata build" {
        Invoke-Idf @("set-target","esp32s3")
        Invoke-Idf @("fullclean")
        Invoke-Idf @("build")
        $Binary = Join-Path $ProjectRoot "build\sqd_b2_3_metadata.bin"
        $Elf = Join-Path $ProjectRoot "build\sqd_b2_3_metadata.elf"
        if (-not (Test-Path $Binary -PathType Leaf)) { throw "Binary is missing: $Binary" }
        if (-not (Test-Path $Elf -PathType Leaf)) { throw "ELF is missing: $Elf" }
        "sqd_b2_3_metadata.bin=$((Get-Item $Binary).Length) bytes"
    }

    Test-Step "Binary provenance" {
        $Binary = Join-Path $ProjectRoot "build\sqd_b2_3_metadata.bin"
        $Inspector = Join-Path $RepoRoot "tools\scripts\B2.3_Inspect_Binary.py"
        $Commit = Git-Capture @("rev-parse","HEAD")
        $Short = Git-Capture @("rev-parse","--short=12","HEAD")
        $Args = @($Inspector,"--binary",$Binary,"--manifest",$ManifestPath)
        $Tokens = @("SQD_META_V1","version=$script:Version","git=$Commit","profile=baseline","target=esp32s3","hardware=heltec-wifi-lora-32-v3","compiler=","v6.0.2",$Short)
        foreach ($Token in $Tokens) { $Args += @("--token",$Token) }
        & $script:PythonExe @Args
        if ($LASTEXITCODE -ne 0) { throw "Required provenance token is missing from the binary." }
        $ManifestPath
    }

    Test-Step "Forbidden tracked sensitive paths" {
        $Tracked = & $GitExe -C $RepoRoot ls-files
        if ($LASTEXITCODE -ne 0) { throw "git ls-files failed." }
        $Patterns = @('(^|/)secrets/','(^|/)credentials/','(^|/)private_keys/','(^|/)\.env(?:\.|$)','\.(?:key|pem|p12|pfx|jks|keystore)$','(^|/)id_rsa(?:\.pub)?$','(^|/)id_ed25519(?:\.pub)?$')
        $Forbidden = @($Tracked | Where-Object { $Path=$_; @($Patterns | Where-Object { $Path -match $_ }).Count -gt 0 })
        if ($Forbidden) { $Forbidden | Set-Content $ForbiddenPathReport -Encoding UTF8; throw "Forbidden tracked paths: $($Forbidden -join ', ')" }
        "No forbidden tracked sensitive paths." | Set-Content $ForbiddenPathReport -Encoding UTF8
        $ForbiddenPathReport
    }

    Test-Step "Pinned secret scanner" {
        $script:GitleaksExe = Resolve-Gitleaks
        $Output = & $script:GitleaksExe version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Gitleaks version failed." }
        "$($Output -join ' ') [$script:GitleaksExe]"
    }

    Test-Step "Complete Git-history secret scan" {
        $Args = @(
            "git", $RepoRoot,
            "--config", (Join-Path $RepoRoot ".gitleaks.toml"),
            "--gitleaks-ignore-path", (Join-Path $RepoRoot ".gitleaksignore"),
            "--log-opts=--all",
            "--report-format", "json",
            "--report-path", $SecretReportPath,
            "--redact=100", "--no-banner", "--no-color", "--exit-code", "1"
        )

        # Gitleaks writes normal progress information to stderr. Windows PowerShell 5.1
        # can promote redirected native stderr to a terminating NativeCommandError when
        # ErrorActionPreference is Stop. Start-Process preserves the real process exit
        # code and captures both streams without misclassifying informational output.
        $StdoutPath = Join-Path $EvidenceDirectory "B2.3_gitleaks_stdout_$Timestamp.tmp"
        $StderrPath = Join-Path $EvidenceDirectory "B2.3_gitleaks_stderr_$Timestamp.tmp"

        Remove-Item -LiteralPath $StdoutPath, $StderrPath -Force -ErrorAction SilentlyContinue

        $Process = Start-Process `
            -FilePath $script:GitleaksExe `
            -ArgumentList $Args `
            -WorkingDirectory $RepoRoot `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $StdoutPath `
            -RedirectStandardError $StderrPath

        $CapturedOutput = New-Object System.Collections.Generic.List[string]

        if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) {
            Get-Content -LiteralPath $StdoutPath | ForEach-Object {
                [void]$CapturedOutput.Add([string]$_)
            }
        }

        if (Test-Path -LiteralPath $StderrPath -PathType Leaf) {
            Get-Content -LiteralPath $StderrPath | ForEach-Object {
                [void]$CapturedOutput.Add([string]$_)
            }
        }

        $CapturedOutput | Set-Content -LiteralPath $SecretLogPath -Encoding UTF8
        Remove-Item -LiteralPath $StdoutPath, $StderrPath -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $SecretReportPath -PathType Leaf)) {
            "[]" | Set-Content -LiteralPath $SecretReportPath -Encoding UTF8
        }

        $Text = (Get-Content -LiteralPath $SecretReportPath -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($Text)) {
            $Text = "[]"
            "[]" | Set-Content -LiteralPath $SecretReportPath -Encoding UTF8
        }

        try {
            $Findings = @($Text | ConvertFrom-Json)
        }
        catch {
            throw "Gitleaks report is not valid JSON. Exit code=$($Process.ExitCode). Review $SecretLogPath and $SecretReportPath."
        }

        if ($Findings.Count -ne 0) {
            throw "Gitleaks found $($Findings.Count) unresolved secret finding(s). Review the redacted report: $SecretReportPath"
        }

        if ($Process.ExitCode -ne 0) {
            throw "Gitleaks failed with exit code $($Process.ExitCode) but produced no findings. Review execution log: $SecretLogPath"
        }

        "Zero unresolved findings across complete Git history; commits scanned successfully; report=$SecretReportPath"
    }
}
finally {
    $Results | Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8
    $Pass = @($Results | Where-Object Result -eq "PASS").Count
    $Fail = @($Results | Where-Object Result -eq "FAIL").Count
    Write-Host ""
    Write-Host "B2.3 verification summary"
    Write-Host "PASS: $Pass"
    Write-Host "FAIL: $Fail"
    Write-Host "Transcript:    $TranscriptPath"
    Write-Host "CSV:           $CsvPath"
    Write-Host "Metadata:      $ManifestPath"
    Write-Host "Secret report: $SecretReportPath"
    Write-Host "Secret log:    $SecretLogPath"
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
}
if (@($Results | Where-Object Result -eq "FAIL").Count -gt 0) { Write-Host "B2.3 verification FAILED." -ForegroundColor Red; exit 1 }
Write-Host "B2.3 verification PASSED." -ForegroundColor Green
exit 0
