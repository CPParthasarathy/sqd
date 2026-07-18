[CmdletBinding()]
param(
    [string]$RepoRoot = "D:\OneDrive\SQD",

    [string]$IdfPath = "D:\esp\v6.0.2\esp-idf",

    [string]$HardwareCompatibility = "heltec-wifi-lora-32-v3",

    [switch]$RequireDevice
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CommonLibrary = Join-Path $PSScriptRoot "B3.2_Common.ps1"

if (-not (Test-Path -LiteralPath $CommonLibrary -PathType Leaf)) {
    throw "B3.2 common library is missing: $CommonLibrary"
}

. $CommonLibrary

$Timestamp = Get-B32Timestamp
$EvidenceDir = Get-B32EvidenceDirectory -RepoRoot $RepoRoot

$SummaryPath = Join-Path `
    $EvidenceDir `
    "B3.2_verification_summary_${Timestamp}.txt"

$ResultPath = Join-Path `
    $EvidenceDir `
    "B3.2_verification_result_${Timestamp}.json"

$CsvPath = Join-Path `
    $EvidenceDir `
    "B3.2_verification_results_${Timestamp}.csv"

$ManifestPath = Join-Path `
    $EvidenceDir `
    "B3.2_verification_manifest_${Timestamp}.json"

$Checks = New-Object System.Collections.Generic.List[object]
$ManifestRecords = New-Object System.Collections.Generic.List[object]

function Add-B32VerificationCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [ValidateSet("PASS", "FAIL")]
        [string]$Status,

        [string]$Evidence = "",

        [string]$Details = ""
    )

    $Checks.Add(
        [PSCustomObject]@{
            Id = $Id
            Category = $Category
            Description = $Description
            Status = $Status
            Evidence = $Evidence
            Details = $Details
        }
    )
}

function Get-B32LatestEvidenceFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [string]$Filter,

        [string]$Description = "evidence file"
    )

    $Match = Get-ChildItem `
        -LiteralPath $Directory `
        -Filter $Filter `
        -File `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $Match) {
        throw "No $Description matched '$Filter' in $Directory."
    }

    $Match
}

function Read-B32JsonEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Description = "JSON evidence"
    )

    $ResolvedPath = Assert-B32File -Path $Path -Description $Description

    try {
        Get-Content -LiteralPath $ResolvedPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "$Description is not valid JSON: $ResolvedPath`n$($_.Exception.Message)"
    }
}

function Add-B32ManifestRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Role
    )

    $Record = Get-B32FileRecord `
        -Path $Path `
        -Role $Role `
        -RepoRoot $RepoRoot

    $ManifestRecords.Add($Record)
    $Record
}

function Invoke-B32Check {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    try {
        $Outcome = & $Action

        $Evidence = ""
        $Details = ""

        if ($null -ne $Outcome) {
            if ($Outcome -is [string]) {
                $Evidence = $Outcome
            }
            elseif ($Outcome.PSObject.Properties.Name -contains "Evidence") {
                $Evidence = [string]$Outcome.Evidence

                if ($Outcome.PSObject.Properties.Name -contains "Details") {
                    $Details = [string]$Outcome.Details
                }
            }
            else {
                $Details = [string]$Outcome
            }
        }

        Add-B32VerificationCheck `
            -Id $Id `
            -Category $Category `
            -Description $Description `
            -Status "PASS" `
            -Evidence $Evidence `
            -Details $Details

        Write-Host "[PASS] $Id - $Description"
    }
    catch {
        Add-B32VerificationCheck `
            -Id $Id `
            -Category $Category `
            -Description $Description `
            -Status "FAIL" `
            -Details $_.Exception.Message

        Write-Host "[FAIL] $Id - $Description" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

try {
    Write-B32Section -Title "B3.2 CONSOLIDATED VERIFICATION"

    $Environment = Initialize-B32IdfEnvironment `
        -RepoRoot $RepoRoot `
        -IdfPath $IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $RepositoryState = Get-B32RepositoryState -RepoRoot $Environment.RepoRoot

    Invoke-B32Check `
        -Id "V01" `
        -Category "Repository" `
        -Description "Feature branch is correct" `
        -Action {
            $Branch = Assert-B32FeatureBranch -RepoRoot $Environment.RepoRoot

            [PSCustomObject]@{
                Evidence = $Environment.RepoRoot
                Details = "Branch=$Branch"
            }
        }

    Invoke-B32Check `
        -Id "V02" `
        -Category "Repository" `
        -Description "Tracked repository tree is clean" `
        -Action {
            Assert-B32TrackedTreeClean -RepoRoot $Environment.RepoRoot | Out-Null

            [PSCustomObject]@{
                Evidence = $Environment.RepoRoot
                Details = "Tracked files clean; untracked B3.2 deliverables are permitted before commit."
            }
        }

    Invoke-B32Check `
        -Id "V03" `
        -Category "Toolchain" `
        -Description "ESP-IDF version and target environment are controlled" `
        -Action {
            if ($Environment.IdfVersion -notmatch '^ESP-IDF v6\.0\.2(?:\b|$)') {
                throw "Unexpected ESP-IDF version: $($Environment.IdfVersion)"
            }

            [PSCustomObject]@{
                Evidence = $Environment.IdfPath
                Details = "Version=$($Environment.IdfVersion); Target=esp32s3"
            }
        }

    $RequiredScripts = @(
        "B3.2_Common.ps1"
        "B3.2_Build.ps1"
        "B3.2_Flash.ps1"
        "B3.2_Monitor.ps1"
        "B3.2_Erase.ps1"
        "B3.2_Bootstrap.ps1"
        "B3.2_Release.ps1"
        "B3.2_Recovery.ps1"
        "B3.2_HardwareCheck.ps1"
        "B3.2_Verify.ps1"
    )

    Invoke-B32Check `
        -Id "V04" `
        -Category "Tooling" `
        -Description "All controlled tooling entry points exist" `
        -Action {
            $Paths = @(
                foreach ($ScriptName in $RequiredScripts) {
                    $ScriptPath = Assert-B32File `
                        -Path (Join-Path $PSScriptRoot $ScriptName) `
                        -Description $ScriptName

                    Add-B32ManifestRecord `
                        -Path $ScriptPath `
                        -Role "controlled-script-$ScriptName" |
                        Out-Null

                    $ScriptPath
                }
            )

            [PSCustomObject]@{
                Evidence = ($Paths -join "; ")
                Details = "Count=$($Paths.Count)"
            }
        }

    Invoke-B32Check `
        -Id "V05" `
        -Category "Tooling" `
        -Description "All controlled PowerShell scripts pass parser validation" `
        -Action {
            $Failures = New-Object System.Collections.Generic.List[string]

            foreach ($ScriptName in $RequiredScripts) {
                $ScriptPath = Join-Path $PSScriptRoot $ScriptName
                $Tokens = $null
                $Errors = $null

                [System.Management.Automation.Language.Parser]::ParseFile(
                    $ScriptPath,
                    [ref]$Tokens,
                    [ref]$Errors
                ) | Out-Null

                foreach ($ParserError in @($Errors)) {
                    $Failures.Add(
                        "${ScriptName}:$($ParserError.Extent.StartLineNumber):$($ParserError.Extent.StartColumnNumber): $($ParserError.Message)"
                    )
                }
            }

            if ($Failures.Count -gt 0) {
                throw ($Failures -join [Environment]::NewLine)
            }

            [PSCustomObject]@{
                Evidence = $PSScriptRoot
                Details = "Scripts parsed=$($RequiredScripts.Count)"
            }
        }

    Invoke-B32Check `
        -Id "V06" `
        -Category "Configuration" `
        -Description "Common and profile sdkconfig defaults are present" `
        -Action {
            $ConfigPaths = New-Object System.Collections.Generic.List[string]

            foreach ($Profile in Get-B32ProfileNames) {
                $Defaults = Get-B32ProfileDefaults `
                    -RepoRoot $Environment.RepoRoot `
                    -Profile $Profile

                foreach ($ConfigPath in @($Defaults.Common, $Defaults.Overlay)) {
                    if (-not $ConfigPaths.Contains($ConfigPath)) {
                        $ConfigPaths.Add($ConfigPath)

                        Add-B32ManifestRecord `
                            -Path $ConfigPath `
                            -Role "sdkconfig-defaults" |
                            Out-Null
                    }
                }
            }

            [PSCustomObject]@{
                Evidence = ($ConfigPaths -join "; ")
                Details = "Profiles=debug,validation,production"
            }
        }

    foreach ($Profile in Get-B32ProfileNames) {
        $UpperProfile = $Profile.ToUpperInvariant()
        $CheckId = switch ($Profile) {
            "debug" { "V07" }
            "validation" { "V08" }
            "production" { "V09" }
        }

        Invoke-B32Check `
            -Id $CheckId `
            -Category "Build" `
            -Description "$UpperProfile controlled build and artifacts are valid" `
            -Action {
                $Layout = Get-B32BuildLayout `
                    -RepoRoot $Environment.RepoRoot `
                    -Profile $Profile

                Assert-B32Directory `
                    -Path $Layout.BuildDir `
                    -Description "$Profile build" |
                    Out-Null

                Assert-B32GeneratedConfiguration `
                    -SdkconfigPath $Layout.Sdkconfig `
                    -Profile $Profile |
                    Out-Null

                $Artifacts = @(Get-B32ProjectArtifacts -BuildDir $Layout.BuildDir)

                if ($Artifacts.Count -eq 0) {
                    throw "No build artifacts found in $($Layout.BuildDir)."
                }

                foreach ($Artifact in $Artifacts) {
                    Add-B32ManifestRecord `
                        -Path $Artifact.Path `
                        -Role "$Profile-$($Artifact.Role)" |
                        Out-Null
                }

                $BuildJsonFile = Get-B32LatestEvidenceFile `
                    -Directory $EvidenceDir `
                    -Filter "B3.2_${Profile}_build_result_*.json" `
                    -Description "$Profile build result"

                $BuildSummaryFile = Get-B32LatestEvidenceFile `
                    -Directory $EvidenceDir `
                    -Filter "B3.2_${Profile}_build_summary_*.txt" `
                    -Description "$Profile build summary"

                $BuildManifestCsv = Get-B32LatestEvidenceFile `
                    -Directory $EvidenceDir `
                    -Filter "B3.2_${Profile}_artifact_manifest_*.csv" `
                    -Description "$Profile build manifest CSV"

                $BuildManifestJson = Get-B32LatestEvidenceFile `
                    -Directory $EvidenceDir `
                    -Filter "B3.2_${Profile}_artifact_manifest_*.json" `
                    -Description "$Profile build manifest JSON"

                $BuildEvidence = Read-B32JsonEvidence `
                    -Path $BuildJsonFile.FullName `
                    -Description "$Profile build result"

                if ([string]$BuildEvidence.status -ne "PASS") {
                    throw "$Profile build result status is not PASS."
                }

                if ([string]$BuildEvidence.profile -ne $Profile) {
                    throw "$Profile build result profile mismatch."
                }

                foreach ($EvidenceFile in @(
                    $BuildJsonFile
                    $BuildSummaryFile
                    $BuildManifestCsv
                    $BuildManifestJson
                )) {
                    Add-B32ManifestRecord `
                        -Path $EvidenceFile.FullName `
                        -Role "$Profile-build-evidence" |
                        Out-Null
                }

                [PSCustomObject]@{
                    Evidence = $BuildJsonFile.FullName
                    Details = "Artifacts=$($Artifacts.Count); BuildDir=$($Layout.BuildDir)"
                }
            }
    }

    Invoke-B32Check `
        -Id "V10" `
        -Category "Flash" `
        -Description "Debug controlled flash evidence is PASS" `
        -Action {
            $FlashFile = Get-B32LatestEvidenceFile `
                -Directory $EvidenceDir `
                -Filter "B3.2_debug_flash_result_*.json" `
                -Description "debug flash result"

            $FlashEvidence = Read-B32JsonEvidence `
                -Path $FlashFile.FullName `
                -Description "debug flash result"

            if ([string]$FlashEvidence.status -ne "PASS") {
                throw "Debug flash result status is not PASS."
            }

            Add-B32ManifestRecord `
                -Path $FlashFile.FullName `
                -Role "debug-flash-evidence" |
                Out-Null

            $FlashFile.FullName
        }

    Invoke-B32Check `
        -Id "V11" `
        -Category "Erase" `
        -Description "Controlled flash erase evidence is PASS" `
        -Action {
            $EraseFile = Get-B32LatestEvidenceFile `
                -Directory $EvidenceDir `
                -Filter "B3.2_erase_result_*.json" `
                -Description "erase result"

            $EraseEvidence = Read-B32JsonEvidence `
                -Path $EraseFile.FullName `
                -Description "erase result"

            if ([string]$EraseEvidence.status -ne "PASS") {
                throw "Erase result status is not PASS."
            }

            if (-not [bool]$EraseEvidence.authorization.confirm_erase) {
                throw "Erase result does not record explicit authorization."
            }

            Add-B32ManifestRecord `
                -Path $EraseFile.FullName `
                -Role "erase-evidence" |
                Out-Null

            $EraseFile.FullName
        }

    Invoke-B32Check `
        -Id "V12" `
        -Category "Monitor" `
        -Description "Debug heartbeat monitor evidence is PASS" `
        -Action {
            $MonitorFile = Get-B32LatestEvidenceFile `
                -Directory $EvidenceDir `
                -Filter "B3.2_debug_monitor_result_*.json" `
                -Description "debug monitor result"

            $MonitorEvidence = Read-B32JsonEvidence `
                -Path $MonitorFile.FullName `
                -Description "debug monitor result"

            if ([string]$MonitorEvidence.status -ne "PASS") {
                throw "Debug monitor result status is not PASS."
            }

            if ([int]$MonitorEvidence.monitor.heartbeat_records -lt 1) {
                throw "Debug monitor evidence contains no heartbeat records."
            }

            $TranscriptPath = [string]$MonitorEvidence.monitor.transcript
            Assert-B32File `
                -Path $TranscriptPath `
                -Description "debug monitor transcript" |
                Out-Null

            Add-B32ManifestRecord `
                -Path $MonitorFile.FullName `
                -Role "debug-monitor-result" |
                Out-Null

            Add-B32ManifestRecord `
                -Path $TranscriptPath `
                -Role "debug-monitor-transcript" |
                Out-Null

            [PSCustomObject]@{
                Evidence = $MonitorFile.FullName
                Details = "Heartbeats=$($MonitorEvidence.monitor.heartbeat_records)"
            }
        }

    Invoke-B32Check `
        -Id "V13" `
        -Category "Bootstrap" `
        -Description "Controlled tooling bootstrap evidence is PASS" `
        -Action {
            $BootstrapFile = Get-B32LatestEvidenceFile `
                -Directory $EvidenceDir `
                -Filter "B3.2_bootstrap_result_*.json" `
                -Description "bootstrap result"

            $BootstrapEvidence = Read-B32JsonEvidence `
                -Path $BootstrapFile.FullName `
                -Description "bootstrap result"

            if ([string]$BootstrapEvidence.status -ne "PASS") {
                throw "Bootstrap result status is not PASS."
            }

            Add-B32ManifestRecord `
                -Path $BootstrapFile.FullName `
                -Role "bootstrap-evidence" |
                Out-Null

            $BootstrapFile.FullName
        }

    Invoke-B32Check `
        -Id "V14" `
        -Category "Release" `
        -Description "Production release archive and hash are valid" `
        -Action {
            $ReleaseFile = Get-B32LatestEvidenceFile `
                -Directory $EvidenceDir `
                -Filter "B3.2_production_release_result_*.json" `
                -Description "production release result"

            $ReleaseEvidence = Read-B32JsonEvidence `
                -Path $ReleaseFile.FullName `
                -Description "production release result"

            if ([string]$ReleaseEvidence.status -ne "PASS") {
                throw "Production release result status is not PASS."
            }

            $ArchivePath = [string]$ReleaseEvidence.release.archive
            $ArchiveExpectedHash = [string]$ReleaseEvidence.release.archive_sha256

            $ArchiveRecord = Get-B32FileRecord `
                -Path $ArchivePath `
                -Role "production-release-archive" `
                -RepoRoot $Environment.RepoRoot

            if ($ArchiveRecord.SHA256 -ne $ArchiveExpectedHash) {
                throw "Release archive SHA256 mismatch. Expected $ArchiveExpectedHash; calculated $($ArchiveRecord.SHA256)."
            }

            if ([int64]$ArchiveRecord.SizeBytes -le 0) {
                throw "Release archive is empty."
            }

            $PackageManifestCsv = [string]$ReleaseEvidence.release.package_manifest_csv
            $PackageManifestJson = [string]$ReleaseEvidence.release.package_manifest_json
            $ReleaseMetadata = [string]$ReleaseEvidence.release.release_metadata
            $Readme = [string]$ReleaseEvidence.release.readme

            foreach ($RequiredReleaseFile in @(
                $PackageManifestCsv
                $PackageManifestJson
                $ReleaseMetadata
                $Readme
            )) {
                Assert-B32File `
                    -Path $RequiredReleaseFile `
                    -Description "release package metadata" |
                    Out-Null

                Add-B32ManifestRecord `
                    -Path $RequiredReleaseFile `
                    -Role "release-package-metadata" |
                    Out-Null
            }

            Add-B32ManifestRecord `
                -Path $ReleaseFile.FullName `
                -Role "production-release-result" |
                Out-Null

            $ManifestRecords.Add($ArchiveRecord)

            [PSCustomObject]@{
                Evidence = $ArchivePath
                Details = "Size=$($ArchiveRecord.SizeBytes); SHA256=$($ArchiveRecord.SHA256)"
            }
        }

    Invoke-B32Check `
        -Id "V15" `
        -Category "Recovery" `
        -Description "Dedicated destructive recovery test is PASS" `
        -Action {
            $RecoveryFile = Get-B32LatestEvidenceFile `
                -Directory $EvidenceDir `
                -Filter "B3.2_recovery_result_*.json" `
                -Description "dedicated recovery result"

            $RecoveryEvidence = Read-B32JsonEvidence `
                -Path $RecoveryFile.FullName `
                -Description "Dedicated recovery result"

            if ([string]$RecoveryEvidence.status -ne "PASS") {
                throw "Dedicated recovery result status is not PASS."
            }

            if (-not [bool]$RecoveryEvidence.authorization.confirm_recovery) {
                throw "Dedicated recovery result does not record explicit authorization."
            }

            if ([string]$RecoveryEvidence.stages.erase.status -ne "PASS") {
                throw "Dedicated recovery erase stage is not PASS."
            }

            if ([string]$RecoveryEvidence.stages.flash_production.status -ne "PASS") {
                throw "Dedicated recovery production-flash stage is not PASS."
            }

            if ([string]$RecoveryEvidence.stages.verify_production_boot.status -ne "PASS") {
                throw "Dedicated recovery boot-verification stage is not PASS."
            }

            $ExpectedImageHash = [string]$RecoveryEvidence.production_image.sha256
            $FlashedImageHash = [string]$RecoveryEvidence.stages.flash_production.image_sha256

            if (
                [string]::IsNullOrWhiteSpace($ExpectedImageHash) -or
                $ExpectedImageHash -ne $FlashedImageHash
            ) {
                throw "Dedicated recovery image hash validation failed."
            }

            if (
                -not [bool]$RecoveryEvidence.stages.verify_production_boot.rom_banner_detected -or
                -not [bool]$RecoveryEvidence.stages.verify_production_boot.reset_reason_detected -or
                -not [bool]$RecoveryEvidence.stages.verify_production_boot.entry_point_detected
            ) {
                throw "Dedicated recovery boot-sequence evidence is incomplete."
            }

            if ([int]$RecoveryEvidence.stages.verify_production_boot.fatal_markers -ne 0) {
                throw "Dedicated recovery boot verification detected fatal markers."
            }

            $RecoveryTranscript = Assert-B32File `
                -Path ([string]$RecoveryEvidence.evidence.recovery_transcript) `
                -Description "Dedicated recovery transcript"

            foreach ($RecoveryEvidencePath in @(
                $RecoveryFile.FullName
                $RecoveryTranscript
                [string]$RecoveryEvidence.stages.erase.result_json
                [string]$RecoveryEvidence.stages.flash_production.result_json
                [string]$RecoveryEvidence.stages.verify_production_boot.result_json
                [string]$RecoveryEvidence.stages.verify_production_boot.transcript
            )) {
                Add-B32ManifestRecord `
                    -Path $RecoveryEvidencePath `
                    -Role "dedicated-recovery-evidence" |
                    Out-Null
            }

            [PSCustomObject]@{
                Evidence = $RecoveryFile.FullName
                Details = "Erase=PASS; Flash=PASS; Boot=PASS; SHA256=$ExpectedImageHash; FatalMarkers=0"
            }
        }

    Invoke-B32Check `
        -Id "V16" `
        -Category "Hardware" `
        -Description "Hardware identity, transport, and production boot checks are PASS" `
        -Action {
            $HardwareFile = Get-B32LatestEvidenceFile `
                -Directory $EvidenceDir `
                -Filter "B3.2_hardware_identity_result_*.json" `
                -Description "hardware identity result"

            $HardwareEvidence = Read-B32JsonEvidence `
                -Path $HardwareFile.FullName `
                -Description "Hardware identity result"

            if ([string]$HardwareEvidence.status -ne "PASS") {
                throw "Hardware identity result status is not PASS."
            }

            if ([string]$HardwareEvidence.scope -ne "identity-transport-and-production-boot") {
                throw "Hardware identity result scope is unexpected."
            }

            if ([string]$HardwareEvidence.device.chip -ne "ESP32-S3") {
                throw "Hardware result does not identify an ESP32-S3."
            }

            if ([string]$HardwareEvidence.device.flash_size -ne "8MB") {
                throw "Hardware result does not identify 8 MB flash."
            }

            if ([string]$HardwareEvidence.device.crystal -ne "40MHz") {
                throw "Hardware result does not identify the expected 40 MHz crystal."
            }

            if ([int]$HardwareEvidence.totals.fail -ne 0) {
                throw "Hardware identity result contains failed checks."
            }

            if ([int]$HardwareEvidence.totals.pass -lt 8) {
                throw "Hardware identity result contains fewer than eight passed checks."
            }

            $IdentityChecks = @(
                $HardwareEvidence.checks |
                Where-Object {
                    $_.Id -match '^H0[1-8]$'
                }
            )

            if ($IdentityChecks.Count -ne 8) {
                throw "Hardware identity result does not contain checks H01 through H08."
            }

            $IdentityFailures = @(
                $IdentityChecks |
                Where-Object {
                    [string]$_.Status -ne "PASS"
                }
            )

            if ($IdentityFailures.Count -gt 0) {
                throw "One or more hardware identity checks H01-H08 are not PASS."
            }

            if ($RequireDevice.IsPresent) {
                $CurrentPorts = @(Get-B32SerialPorts)

                if ($CurrentPorts.Count -eq 0) {
                    throw "No serial device is currently detected."
                }

                $EvidencePort = [string]$HardwareEvidence.device.serial_port
                $CurrentPortMatch = @(
                    $CurrentPorts |
                    Where-Object {
                        [string]$_.Port -eq $EvidencePort
                    }
                )

                if ($CurrentPortMatch.Count -eq 0) {
                    throw "Hardware evidence port '$EvidencePort' is not currently detected."
                }
            }

            foreach ($HardwareEvidencePath in @(
                $HardwareFile.FullName
                [string]$HardwareEvidence.evidence.results_csv
                [string]$HardwareEvidence.evidence.chip_stdout
                [string]$HardwareEvidence.evidence.flash_stdout
                [string]$HardwareEvidence.evidence.production_monitor_result
                [string]$HardwareEvidence.evidence.production_monitor_transcript
            )) {
                Add-B32ManifestRecord `
                    -Path $HardwareEvidencePath `
                    -Role "hardware-identity-evidence" |
                    Out-Null
            }

            [PSCustomObject]@{
                Evidence = $HardwareFile.FullName
                Details = "MCU=ESP32-S3; Flash=8MB; Crystal=40MHz; IdentityChecks=8 PASS; Fail=0"
            }
        }

    Invoke-B32Check `
        -Id "V17" `
        -Category "Hardware" `
        -Description "Unexercised board peripherals are explicitly recorded as NOT_TESTED" `
        -Action {
            $HardwareFile = Get-B32LatestEvidenceFile `
                -Directory $EvidenceDir `
                -Filter "B3.2_hardware_identity_result_*.json" `
                -Description "hardware identity result"

            $HardwareEvidence = Read-B32JsonEvidence `
                -Path $HardwareFile.FullName `
                -Description "Hardware identity result"

            $PeripheralChecks = @(
                $HardwareEvidence.checks |
                Where-Object {
                    $_.Id -match '^H(09|10|11|12|13|14|15)$'
                }
            )

            if ($PeripheralChecks.Count -ne 7) {
                throw "Hardware result does not contain all seven peripheral coverage records H09-H15."
            }

            $IncorrectStatuses = @(
                $PeripheralChecks |
                Where-Object {
                    [string]$_.Status -ne "NOT_TESTED"
                }
            )

            if ($IncorrectStatuses.Count -gt 0) {
                throw "One or more unexercised peripherals are not recorded as NOT_TESTED."
            }

            if ([int]$HardwareEvidence.totals.not_tested -ne 7) {
                throw "Hardware result NOT_TESTED total is not seven."
            }

            $ExpectedPeripheralTerms = @(
                "LoRa"
                "OLED"
                "button"
                "LED"
                "Battery"
                "Wi-Fi"
                "Bluetooth"
            )

            $Descriptions = @(
                $PeripheralChecks |
                ForEach-Object {
                    [string]$_.Description
                }
            ) -join " "

            foreach ($Term in $ExpectedPeripheralTerms) {
                if ($Descriptions -notmatch [regex]::Escape($Term)) {
                    throw "Peripheral coverage record is missing '$Term'."
                }
            }

            [PSCustomObject]@{
                Evidence = $HardwareFile.FullName
                Details = "H09-H15=NOT_TESTED; dedicated peripheral self-test firmware still required"
            }
        }

    $PassCount = @($Checks | Where-Object Status -eq "PASS").Count
    $FailCount = @($Checks | Where-Object Status -eq "FAIL").Count
    $OverallStatus = if ($FailCount -eq 0) {
        "PASS"
    }
    else {
        "FAIL"
    }

    $Checks |
        Export-Csv `
            -LiteralPath $CsvPath `
            -NoTypeInformation `
            -Encoding UTF8

    $UniqueManifestRecords = @(
        $ManifestRecords |
        Group-Object Path |
        ForEach-Object {
            $_.Group | Select-Object -First 1
        } |
        Sort-Object RelativePath, Role
    )

    Write-B32JsonFile `
        -InputObject $UniqueManifestRecords `
        -Path $ManifestPath `
        -Depth 10 |
        Out-Null

    # PowerShell 5.1 can throw "Argument types do not match" when a
    # generic List[object] is embedded through @($Checks) in a hashtable.
    # Convert it explicitly to a native object array before serialization.
    [object[]]$CheckArray = $Checks.ToArray()

    $Result = [ordered]@{
        work_package = "B3.2"
        operation = "consolidated-verification"
        status = $OverallStatus
        timestamp_local = (Get-Date).ToString("o")
        repository = [ordered]@{
            root = $Environment.RepoRoot
            branch = $RepositoryState.Branch
            commit = $RepositoryState.Commit
            commit_short = $RepositoryState.CommitShort
            tracked_status = $RepositoryState.TrackedStatusPorcelain
        }
        toolchain = [ordered]@{
            idf_path = $Environment.IdfPath
            idf_version = $Environment.IdfVersion
            target = "esp32s3"
        }
        hardware_compatibility = $HardwareCompatibility
        device_required = $RequireDevice.IsPresent
        totals = [ordered]@{
            pass = $PassCount
            fail = $FailCount
            total = $Checks.Count
        }
        checks = $CheckArray
        evidence = [ordered]@{
            summary = $SummaryPath
            result_json = $ResultPath
            results_csv = $CsvPath
            verification_manifest = $ManifestPath
        }
    }

    Write-B32JsonFile `
        -InputObject $Result `
        -Path $ResultPath `
        -Depth 16 |
        Out-Null

    $CheckLines = @(
        foreach ($Check in $Checks) {
            "[$($Check.Status)] $($Check.Id) $($Check.Category) - $($Check.Description)"
        }
    )

    $Summary = @(
        "============================================================"
        "B3.2 CONSOLIDATED VERIFICATION"
        "============================================================"
        "Status:                    $OverallStatus"
        "Timestamp:                 $((Get-Date).ToString('o'))"
        "Repository:                $($Environment.RepoRoot)"
        "Branch:                    $($RepositoryState.Branch)"
        "Commit:                    $($RepositoryState.Commit)"
        "ESP-IDF:                   $($Environment.IdfVersion)"
        "Target:                    esp32s3"
        "Hardware compatibility:    $HardwareCompatibility"
        "Device required:            $($RequireDevice.IsPresent)"
        "Checks passed:             $PassCount"
        "Checks failed:             $FailCount"
        "Checks total:              $($Checks.Count)"
        ""
        "Verification checks"
        "-------------------"
        $CheckLines
        ""
        "Results CSV:               $CsvPath"
        "Result JSON:               $ResultPath"
        "Verification manifest:     $ManifestPath"
        ""
        "B3.2 CONSOLIDATED VERIFICATION $OverallStatus"
    ) -join [Environment]::NewLine

    Write-B32TextFile `
        -Content ($Summary + [Environment]::NewLine) `
        -Path $SummaryPath |
        Out-Null

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONSOLIDATED VERIFICATION $OverallStatus"
    Write-Host "============================================================"
    Write-Host "PASS:      $PassCount"
    Write-Host "FAIL:      $FailCount"
    Write-Host "Summary:   $SummaryPath"
    Write-Host "Result:    $ResultPath"
    Write-Host "CSV:       $CsvPath"
    Write-Host "Manifest:  $ManifestPath"

    if ($FailCount -gt 0) {
        throw "B3.2 consolidated verification failed with $FailCount failed check(s)."
    }
}
catch {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONSOLIDATED VERIFICATION FAILED"
    Write-Host "============================================================"
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
