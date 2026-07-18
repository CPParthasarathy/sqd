[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^COM\d+$')]
    [string]$Port,

    [ValidateRange(115200, 2000000)]
    [int]$FlashBaud = 921600,

    [ValidateRange(9600, 2000000)]
    [int]$MonitorBaud = 115200,

    [ValidateRange(5, 300)]
    [int]$MonitorDurationSeconds = 15,

    [Parameter(Mandatory)]
    [switch]$ConfirmRecovery,

    [string]$RepoRoot = "D:\OneDrive\SQD",

    [string]$IdfPath = "D:\esp\v6.0.2\esp-idf",

    [string]$HardwareCompatibility = "heltec-wifi-lora-32-v3"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CommonLibrary = Join-Path $PSScriptRoot "B3.2_Common.ps1"
$EraseScript = Join-Path $PSScriptRoot "B3.2_Erase.ps1"
$FlashScript = Join-Path $PSScriptRoot "B3.2_Flash.ps1"
$MonitorScript = Join-Path $PSScriptRoot "B3.2_Monitor.ps1"

foreach ($RequiredScript in @(
    $CommonLibrary
    $EraseScript
    $FlashScript
    $MonitorScript
)) {
    if (-not (Test-Path -LiteralPath $RequiredScript -PathType Leaf)) {
        throw "Required B3.2 script is missing: $RequiredScript"
    }
}

. $CommonLibrary

$Timestamp = Get-B32Timestamp
$EvidenceDir = Get-B32EvidenceDirectory -RepoRoot $RepoRoot

$SummaryPath = Join-Path `
    $EvidenceDir `
    "B3.2_recovery_summary_${Timestamp}.txt"

$ResultPath = Join-Path `
    $EvidenceDir `
    "B3.2_recovery_result_${Timestamp}.json"

$TranscriptPath = Join-Path `
    $EvidenceDir `
    "B3.2_recovery_transcript_${Timestamp}.txt"

function Get-B32NewestRecoveryEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Filter,

        [Parameter(Mandatory)]
        [datetime]$NotBeforeUtc,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $Match = Get-ChildItem `
        -LiteralPath $EvidenceDir `
        -Filter $Filter `
        -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTimeUtc -ge $NotBeforeUtc.AddSeconds(-2)
        } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $Match) {
        throw "No new $Description matched '$Filter' after $($NotBeforeUtc.ToString('o'))."
    }

    $Match
}

function Read-B32RecoveryJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $ResolvedPath = Assert-B32File -Path $Path -Description $Description

    try {
        Get-Content -LiteralPath $ResolvedPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "$Description is not valid JSON: $ResolvedPath`n$($_.Exception.Message)"
    }
}

try {
    Write-B32Section -Title "B3.2 DESTRUCTIVE RECOVERY TEST"

    if (-not $ConfirmRecovery.IsPresent) {
        throw "Recovery test was not authorized. Re-run with -ConfirmRecovery."
    }

    $RecoveryStartUtc = [DateTime]::UtcNow

    $Environment = Initialize-B32IdfEnvironment `
        -RepoRoot $RepoRoot `
        -IdfPath $IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $Branch = Assert-B32FeatureBranch -RepoRoot $Environment.RepoRoot
    Assert-B32TrackedTreeClean -RepoRoot $Environment.RepoRoot | Out-Null

    $RepositoryState = Get-B32RepositoryState -RepoRoot $Environment.RepoRoot
    $ResolvedPort = Resolve-B32SerialPort -Port $Port

    $ProductionLayout = Get-B32BuildLayout `
        -RepoRoot $Environment.RepoRoot `
        -Profile "production"

    Assert-B32Directory `
        -Path $ProductionLayout.BuildDir `
        -Description "Production build" |
        Out-Null

    Assert-B32GeneratedConfiguration `
        -SdkconfigPath $ProductionLayout.Sdkconfig `
        -Profile "production" |
        Out-Null

    $ProductionArtifacts = @(
        Get-B32ProjectArtifacts -BuildDir $ProductionLayout.BuildDir
    )

    $ApplicationArtifact = @(
        $ProductionArtifacts |
        Where-Object Role -eq "application-bin"
    ) |
        Select-Object -First 1

    if ($null -eq $ApplicationArtifact) {
        throw "Production application binary is missing. Run B3.2_Build.ps1 -Profile production first."
    }

    $ApplicationRecord = Get-B32FileRecord `
        -Path $ApplicationArtifact.Path `
        -Role "production-application-bin" `
        -RepoRoot $Environment.RepoRoot

    Write-Host "Branch:             $Branch"
    Write-Host "Commit:             $($RepositoryState.Commit)"
    Write-Host "ESP-IDF:            $($Environment.IdfVersion)"
    Write-Host "Port:               $($ResolvedPort.Port)"
    Write-Host "Device:             $($ResolvedPort.Name)"
    Write-Host "Flash baud:         $FlashBaud"
    Write-Host "Monitor baud:       $MonitorBaud"
    Write-Host "Monitor duration:   $MonitorDurationSeconds seconds"
    Write-Host "Production binary:  $($ApplicationRecord.Path)"
    Write-Host "Binary SHA256:      $($ApplicationRecord.SHA256)"
    Write-Host ""
    Write-Host "WARNING: This test erases the complete external SPI flash."
    Write-Host "The production image will then be reflashed and boot-verified."
    Write-Host ""

    $TranscriptLines = New-Object System.Collections.Generic.List[string]

    $TranscriptLines.Add("============================================================")
    $TranscriptLines.Add("B3.2 DESTRUCTIVE RECOVERY TEST")
    $TranscriptLines.Add("============================================================")
    $TranscriptLines.Add("Started:                   $((Get-Date).ToString('o'))")
    $TranscriptLines.Add("Repository:                $($Environment.RepoRoot)")
    $TranscriptLines.Add("Branch:                    $($RepositoryState.Branch)")
    $TranscriptLines.Add("Commit:                    $($RepositoryState.Commit)")
    $TranscriptLines.Add("ESP-IDF:                   $($Environment.IdfVersion)")
    $TranscriptLines.Add("Target:                    esp32s3")
    $TranscriptLines.Add("Hardware compatibility:    $HardwareCompatibility")
    $TranscriptLines.Add("Serial port:               $($ResolvedPort.Port)")
    $TranscriptLines.Add("Serial device:             $($ResolvedPort.Name)")
    $TranscriptLines.Add("Production binary:         $($ApplicationRecord.Path)")
    $TranscriptLines.Add("Production binary SHA256:  $($ApplicationRecord.SHA256)")
    $TranscriptLines.Add("")

    $EraseStartUtc = [DateTime]::UtcNow
    $TranscriptLines.Add("STEP 1 START: ERASE FLASH - $((Get-Date).ToString('o'))")

    & $EraseScript `
        -Port $ResolvedPort.Port `
        -Baud $FlashBaud `
        -ConfirmErase `
        -RepoRoot $Environment.RepoRoot `
        -IdfPath $Environment.IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $EraseEndUtc = [DateTime]::UtcNow

    $EraseResultFile = Get-B32NewestRecoveryEvidence `
        -Filter "B3.2_erase_result_*.json" `
        -NotBeforeUtc $EraseStartUtc `
        -Description "erase result"

    $EraseResult = Read-B32RecoveryJson `
        -Path $EraseResultFile.FullName `
        -Description "Recovery erase result"

    if ([string]$EraseResult.status -ne "PASS") {
        throw "Recovery erase stage did not report PASS."
    }

    $TranscriptLines.Add("STEP 1 PASS:  ERASE FLASH - $((Get-Date).ToString('o'))")
    $TranscriptLines.Add("Evidence:     $($EraseResultFile.FullName)")
    $TranscriptLines.Add("")

    $FlashStartUtc = [DateTime]::UtcNow
    $TranscriptLines.Add("STEP 2 START: FLASH PRODUCTION - $((Get-Date).ToString('o'))")

    & $FlashScript `
        -Profile production `
        -Port $ResolvedPort.Port `
        -Baud $FlashBaud `
        -RepoRoot $Environment.RepoRoot `
        -IdfPath $Environment.IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $FlashEndUtc = [DateTime]::UtcNow

    $FlashResultFile = Get-B32NewestRecoveryEvidence `
        -Filter "B3.2_production_flash_result_*.json" `
        -NotBeforeUtc $FlashStartUtc `
        -Description "production flash result"

    $FlashResult = Read-B32RecoveryJson `
        -Path $FlashResultFile.FullName `
        -Description "Recovery production flash result"

    if ([string]$FlashResult.status -ne "PASS") {
        throw "Recovery production flash stage did not report PASS."
    }

    if ([string]$FlashResult.profile -ne "production") {
        throw "Recovery flash evidence does not identify the production profile."
    }

    $FlashedHash = [string]$FlashResult.application_binary.sha256

    if ($FlashedHash -ne $ApplicationRecord.SHA256) {
        throw "Recovery flash binary hash mismatch. Expected $($ApplicationRecord.SHA256); recorded $FlashedHash."
    }

    $TranscriptLines.Add("STEP 2 PASS:  FLASH PRODUCTION - $((Get-Date).ToString('o'))")
    $TranscriptLines.Add("Evidence:     $($FlashResultFile.FullName)")
    $TranscriptLines.Add("SHA256:       $FlashedHash")
    $TranscriptLines.Add("")

    $MonitorStartUtc = [DateTime]::UtcNow
    $TranscriptLines.Add("STEP 3 START: VERIFY PRODUCTION BOOT - $((Get-Date).ToString('o'))")

    & $MonitorScript `
        -Profile production `
        -Port $ResolvedPort.Port `
        -Baud $MonitorBaud `
        -DurationSeconds $MonitorDurationSeconds `
        -RepoRoot $Environment.RepoRoot `
        -IdfPath $Environment.IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $MonitorEndUtc = [DateTime]::UtcNow

    $MonitorResultFile = Get-B32NewestRecoveryEvidence `
        -Filter "B3.2_production_monitor_result_*.json" `
        -NotBeforeUtc $MonitorStartUtc `
        -Description "production monitor result"

    $MonitorResult = Read-B32RecoveryJson `
        -Path $MonitorResultFile.FullName `
        -Description "Recovery production monitor result"

    if ([string]$MonitorResult.status -ne "PASS") {
        throw "Recovery production monitor stage did not report PASS."
    }

    if ([string]$MonitorResult.monitor.validation_mode -ne "boot-sequence") {
        throw "Recovery production monitor did not use boot-sequence validation."
    }

    if (-not [bool]$MonitorResult.monitor.rom_banner_detected) {
        throw "Recovery monitor did not detect the ESP32-S3 ROM banner."
    }

    if (-not [bool]$MonitorResult.monitor.reset_reason_detected) {
        throw "Recovery monitor did not detect the reset reason."
    }

    if (-not [bool]$MonitorResult.monitor.entry_point_detected) {
        throw "Recovery monitor did not detect the boot entry point."
    }

    if ([int]$MonitorResult.monitor.fatal_markers -ne 0) {
        throw "Recovery monitor detected fatal firmware markers."
    }

    $MonitorTranscript = Assert-B32File `
        -Path ([string]$MonitorResult.monitor.transcript) `
        -Description "Recovery production monitor transcript"

    $TranscriptLines.Add("STEP 3 PASS:  VERIFY PRODUCTION BOOT - $((Get-Date).ToString('o'))")
    $TranscriptLines.Add("Evidence:     $($MonitorResultFile.FullName)")
    $TranscriptLines.Add("Transcript:   $MonitorTranscript")
    $TranscriptLines.Add("ROM banner:   $($MonitorResult.monitor.rom_banner_detected)")
    $TranscriptLines.Add("Reset reason: $($MonitorResult.monitor.reset_reason_detected)")
    $TranscriptLines.Add("Entry point:  $($MonitorResult.monitor.entry_point_detected)")
    $TranscriptLines.Add("Fatal markers:$($MonitorResult.monitor.fatal_markers)")
    $TranscriptLines.Add("")

    $RecoveryEndUtc = [DateTime]::UtcNow

    $EraseDurationSeconds = [math]::Round(
        ($EraseEndUtc - $EraseStartUtc).TotalSeconds,
        3
    )

    $FlashDurationSeconds = [math]::Round(
        ($FlashEndUtc - $FlashStartUtc).TotalSeconds,
        3
    )

    $MonitorStageDurationSeconds = [math]::Round(
        ($MonitorEndUtc - $MonitorStartUtc).TotalSeconds,
        3
    )

    $TotalDurationSeconds = [math]::Round(
        ($RecoveryEndUtc - $RecoveryStartUtc).TotalSeconds,
        3
    )

    $Result = [ordered]@{
        work_package = "B3.2"
        operation = "destructive-recovery-test"
        status = "PASS"
        timestamp_local = (Get-Date).ToString("o")
        authorization = [ordered]@{
            confirm_recovery = $ConfirmRecovery.IsPresent
            destructive_flash_erase = $true
        }
        repository = [ordered]@{
            root = $Environment.RepoRoot
            branch = $RepositoryState.Branch
            commit = $RepositoryState.Commit
            commit_short = $RepositoryState.CommitShort
            tracked_tree_clean = $true
        }
        toolchain = [ordered]@{
            idf_path = $Environment.IdfPath
            idf_version = $Environment.IdfVersion
            target = "esp32s3"
        }
        device = [ordered]@{
            port = $ResolvedPort.Port
            name = $ResolvedPort.Name
            description = $ResolvedPort.Description
            pnp_device_id = $ResolvedPort.PnpDeviceId
            flash_baud = $FlashBaud
            monitor_baud = $MonitorBaud
            hardware_compatibility = $HardwareCompatibility
        }
        production_image = [ordered]@{
            path = $ApplicationRecord.Path
            size_bytes = $ApplicationRecord.SizeBytes
            sha256 = $ApplicationRecord.SHA256
        }
        stages = [ordered]@{
            erase = [ordered]@{
                status = "PASS"
                duration_seconds = $EraseDurationSeconds
                result_json = $EraseResultFile.FullName
            }
            flash_production = [ordered]@{
                status = "PASS"
                duration_seconds = $FlashDurationSeconds
                result_json = $FlashResultFile.FullName
                image_sha256 = $FlashedHash
            }
            verify_production_boot = [ordered]@{
                status = "PASS"
                duration_seconds = $MonitorStageDurationSeconds
                result_json = $MonitorResultFile.FullName
                transcript = $MonitorTranscript
                validation_mode = [string]$MonitorResult.monitor.validation_mode
                rom_banner_detected = [bool]$MonitorResult.monitor.rom_banner_detected
                reset_reason_detected = [bool]$MonitorResult.monitor.reset_reason_detected
                entry_point_detected = [bool]$MonitorResult.monitor.entry_point_detected
                fatal_markers = [int]$MonitorResult.monitor.fatal_markers
            }
        }
        total_duration_seconds = $TotalDurationSeconds
        evidence = [ordered]@{
            summary = $SummaryPath
            result_json = $ResultPath
            recovery_transcript = $TranscriptPath
        }
    }

    Write-B32JsonFile `
        -InputObject $Result `
        -Path $ResultPath `
        -Depth 16 |
        Out-Null

    $TranscriptLines.Add("============================================================")
    $TranscriptLines.Add("B3.2 DESTRUCTIVE RECOVERY TEST PASSED")
    $TranscriptLines.Add("============================================================")
    $TranscriptLines.Add("Completed:                 $((Get-Date).ToString('o'))")
    $TranscriptLines.Add("Erase duration seconds:    $EraseDurationSeconds")
    $TranscriptLines.Add("Flash duration seconds:    $FlashDurationSeconds")
    $TranscriptLines.Add("Monitor duration seconds:  $MonitorStageDurationSeconds")
    $TranscriptLines.Add("Total duration seconds:    $TotalDurationSeconds")
    $TranscriptLines.Add("Result JSON:               $ResultPath")
    $TranscriptLines.Add("")

    Write-B32TextFile `
        -Content (($TranscriptLines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine) `
        -Path $TranscriptPath |
        Out-Null

    $Summary = @(
        "============================================================"
        "B3.2 DESTRUCTIVE RECOVERY TEST"
        "============================================================"
        "Status:                    PASS"
        "Timestamp:                 $((Get-Date).ToString('o'))"
        "Repository:                $($Environment.RepoRoot)"
        "Branch:                    $($RepositoryState.Branch)"
        "Commit:                    $($RepositoryState.Commit)"
        "ESP-IDF:                   $($Environment.IdfVersion)"
        "Target:                    esp32s3"
        "Hardware compatibility:    $HardwareCompatibility"
        "Serial port:               $($ResolvedPort.Port)"
        "Serial device:             $($ResolvedPort.Name)"
        "Recovery authorized:       $($ConfirmRecovery.IsPresent)"
        "Production binary:         $($ApplicationRecord.Path)"
        "Production binary bytes:   $($ApplicationRecord.SizeBytes)"
        "Production binary SHA256:  $($ApplicationRecord.SHA256)"
        "Erase status:              PASS"
        "Erase duration seconds:    $EraseDurationSeconds"
        "Erase result:              $($EraseResultFile.FullName)"
        "Production flash status:   PASS"
        "Flash duration seconds:    $FlashDurationSeconds"
        "Production flash result:   $($FlashResultFile.FullName)"
        "Boot verification status:  PASS"
        "Boot validation mode:      $($MonitorResult.monitor.validation_mode)"
        "ROM banner detected:       $($MonitorResult.monitor.rom_banner_detected)"
        "Reset reason detected:     $($MonitorResult.monitor.reset_reason_detected)"
        "Entry point detected:      $($MonitorResult.monitor.entry_point_detected)"
        "Fatal markers:             $($MonitorResult.monitor.fatal_markers)"
        "Monitor result:            $($MonitorResultFile.FullName)"
        "Monitor transcript:        $MonitorTranscript"
        "Total duration seconds:    $TotalDurationSeconds"
        "Recovery transcript:       $TranscriptPath"
        "Result JSON:               $ResultPath"
        ""
        "B3.2 DESTRUCTIVE RECOVERY TEST PASSED"
    ) -join [Environment]::NewLine

    Write-B32TextFile `
        -Content ($Summary + [Environment]::NewLine) `
        -Path $SummaryPath |
        Out-Null

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 DESTRUCTIVE RECOVERY TEST PASSED"
    Write-Host "============================================================"
    Write-Host "Port:          $($ResolvedPort.Port)"
    Write-Host "Production:    $($ApplicationRecord.Path)"
    Write-Host "SHA256:        $($ApplicationRecord.SHA256)"
    Write-Host "Erase:         PASS"
    Write-Host "Flash:         PASS"
    Write-Host "Boot verify:   PASS"
    Write-Host "Fatal markers: $($MonitorResult.monitor.fatal_markers)"
    Write-Host "Total seconds: $TotalDurationSeconds"
    Write-Host "Transcript:    $TranscriptPath"
    Write-Host "Summary:       $SummaryPath"
    Write-Host "Result JSON:   $ResultPath"
}
catch {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 DESTRUCTIVE RECOVERY TEST FAILED"
    Write-Host "============================================================"
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
