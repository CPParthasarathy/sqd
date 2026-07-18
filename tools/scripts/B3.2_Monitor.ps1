[CmdletBinding()]
param(
    [ValidateSet("debug", "validation", "production")]
    [string]$Profile = "debug",

    [Parameter(Mandatory)]
    [ValidatePattern('^COM\d+$')]
    [string]$Port,

    [ValidateRange(9600, 2000000)]
    [int]$Baud = 115200,

    [ValidateRange(5, 300)]
    [int]$DurationSeconds = 15,

    [string]$RepoRoot = "D:\OneDrive\SQD",

    [string]$IdfPath = "D:\esp\v6.0.2\esp-idf",

    [string]$HardwareCompatibility = "heltec-wifi-lora-32-v3"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CommonLibrary = Join-Path $PSScriptRoot "B3.2_Common.ps1"

if (-not (Test-Path -LiteralPath $CommonLibrary -PathType Leaf)) {
    throw "B3.2 common library is missing: $CommonLibrary"
}

. $CommonLibrary

$Timestamp = Get-B32Timestamp
$NormalizedProfile = Assert-B32Profile -Profile $Profile
$EvidenceDir = Get-B32EvidenceDirectory -RepoRoot $RepoRoot

$TranscriptPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_monitor_transcript_${Timestamp}.txt"

$SummaryPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_monitor_summary_${Timestamp}.txt"

$ResultPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_monitor_result_${Timestamp}.json"

$Serial = $null

try {
    Write-B32Section -Title "B3.2 CONTROLLED MONITOR: $($NormalizedProfile.ToUpperInvariant())"

    $Environment = Initialize-B32IdfEnvironment `
        -RepoRoot $RepoRoot `
        -IdfPath $IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $Branch = Assert-B32FeatureBranch -RepoRoot $Environment.RepoRoot
    Assert-B32TrackedTreeClean -RepoRoot $Environment.RepoRoot | Out-Null

    $RepositoryState = Get-B32RepositoryState -RepoRoot $Environment.RepoRoot

    $Layout = Get-B32BuildLayout `
        -RepoRoot $Environment.RepoRoot `
        -Profile $NormalizedProfile

    $ResolvedPort = Resolve-B32SerialPort -Port $Port

    Assert-B32Directory `
        -Path $Layout.BuildDir `
        -Description "$NormalizedProfile build" |
        Out-Null

    Assert-B32GeneratedConfiguration `
        -SdkconfigPath $Layout.Sdkconfig `
        -Profile $NormalizedProfile |
        Out-Null

    $ProjectDescription = Get-B32ProjectDescription -BuildDir $Layout.BuildDir
    $ProjectName = [string]$ProjectDescription.project_name

    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        throw "project_description.json does not contain project_name."
    }

    $ElfPath = Assert-B32File `
        -Path (Join-Path $Layout.BuildDir "$ProjectName.elf") `
        -Description "Application ELF"

    $ElfRecord = Get-B32FileRecord `
        -Path $ElfPath `
        -Role "application-elf" `
        -RepoRoot $Environment.RepoRoot

    Write-Host "Profile:       $NormalizedProfile"
    Write-Host "Branch:        $Branch"
    Write-Host "Commit:        $($RepositoryState.Commit)"
    Write-Host "ESP-IDF:       $($Environment.IdfVersion)"
    Write-Host "Build dir:     $($Layout.BuildDir)"
    Write-Host "Port:          $($ResolvedPort.Port)"
    Write-Host "Device:        $($ResolvedPort.Name)"
    Write-Host "Baud:          $Baud"
    Write-Host "Duration:      $DurationSeconds seconds"
    Write-Host "ELF:           $ElfPath"
    Write-Host "ELF SHA256:    $($ElfRecord.SHA256)"
    Write-Host "Transcript:    $TranscriptPath"
    Write-Host ""

    $Header = @(
        "============================================================"
        "B3.2 CONTROLLED SERIAL CAPTURE"
        "============================================================"
        "Started:                   $((Get-Date).ToString('o'))"
        "Profile:                   $NormalizedProfile"
        "Branch:                    $($RepositoryState.Branch)"
        "Commit:                    $($RepositoryState.Commit)"
        "ESP-IDF:                   $($Environment.IdfVersion)"
        "Target:                    esp32s3"
        "Hardware compatibility:    $HardwareCompatibility"
        "Build directory:           $($Layout.BuildDir)"
        "Serial port:               $($ResolvedPort.Port)"
        "Serial device:             $($ResolvedPort.Name)"
        "Baud:                      $Baud"
        "Capture duration seconds:  $DurationSeconds"
        "Application ELF:           $ElfPath"
        "ELF SHA256:                $($ElfRecord.SHA256)"
        "============================================================"
        ""
    ) -join [Environment]::NewLine

    $CaptureBuffer = New-Object System.Text.StringBuilder

    $Serial = New-Object System.IO.Ports.SerialPort
    $Serial.PortName = $ResolvedPort.Port
    $Serial.BaudRate = $Baud
    $Serial.Parity = [System.IO.Ports.Parity]::None
    $Serial.DataBits = 8
    $Serial.StopBits = [System.IO.Ports.StopBits]::One
    $Serial.Handshake = [System.IO.Ports.Handshake]::None
    $Serial.ReadTimeout = 250
    $Serial.WriteTimeout = 250
    $Serial.DtrEnable = $false
    $Serial.RtsEnable = $false
    $Serial.Encoding = New-Object System.Text.UTF8Encoding($false)

    $Serial.Open()
    $Serial.DiscardInBuffer()

    # Force a normal hardware reset so ROM/boot output is captured even when
    # the production profile suppresses application INFO logging.
    $Serial.DtrEnable = $false
    $Serial.RtsEnable = $true
    Start-Sleep -Milliseconds 120
    $Serial.RtsEnable = $false
    Start-Sleep -Milliseconds 100

    $CaptureStartUtc = [DateTime]::UtcNow
    $CaptureEndUtc = $CaptureStartUtc.AddSeconds($DurationSeconds)

    Write-Host "Capturing serial output..."
    Write-Host ""

    while ([DateTime]::UtcNow -lt $CaptureEndUtc) {
        $Chunk = $Serial.ReadExisting()

        if (-not [string]::IsNullOrEmpty($Chunk)) {
            [void]$CaptureBuffer.Append($Chunk)
            Write-Host -NoNewline $Chunk
        }

        Start-Sleep -Milliseconds 50
    }

    $CaptureStopUtc = [DateTime]::UtcNow
    $ActualDurationSeconds = [math]::Round(
        ($CaptureStopUtc - $CaptureStartUtc).TotalSeconds,
        3
    )

    $Serial.Close()
    $Serial.Dispose()
    $Serial = $null

    $CaptureText = $CaptureBuffer.ToString()
    $HeartbeatMatches = [regex]::Matches(
        $CaptureText,
        'B1\.2:\s+Heartbeat:\s+\d+'
    )

    $HeartbeatCount = $HeartbeatMatches.Count
    $CapturedCharacterCount = $CaptureText.Length

    $RomBannerDetected = [regex]::IsMatch(
        $CaptureText,
        'ESP-ROM:esp32s3-'
    )

    $ResetReasonDetected = [regex]::IsMatch(
        $CaptureText,
        'rst:0x[0-9a-fA-F]+'
    )

    $EntryPointDetected = [regex]::IsMatch(
        $CaptureText,
        'entry 0x[0-9a-fA-F]+'
    )

    $FatalMatches = [regex]::Matches(
        $CaptureText,
        '(?im)Guru Meditation Error|panic(?:''ed)?|Brownout detector was triggered|invalid header|abort\(\)'
    )

    $FatalCount = $FatalMatches.Count

    $ValidationMode = if ($NormalizedProfile -eq "production") {
        "boot-sequence"
    }
    else {
        "heartbeat"
    }

    $Status = if ($NormalizedProfile -eq "production") {
        if (
            $RomBannerDetected -and
            $ResetReasonDetected -and
            $EntryPointDetected -and
            $FatalCount -eq 0
        ) {
            "PASS"
        }
        else {
            "FAIL"
        }
    }
    elseif ($HeartbeatCount -gt 0 -and $FatalCount -eq 0) {
        "PASS"
    }
    else {
        "FAIL"
    }

    $Footer = @(
        ""
        "============================================================"
        "Capture ended:             $((Get-Date).ToString('o'))"
        "Actual duration seconds:   $ActualDurationSeconds"
        "Validation mode:           $ValidationMode"
        "Captured characters:       $CapturedCharacterCount"
        "Heartbeat records:         $HeartbeatCount"
        "ROM banner detected:       $RomBannerDetected"
        "Reset reason detected:     $ResetReasonDetected"
        "Entry point detected:      $EntryPointDetected"
        "Fatal markers:             $FatalCount"
        "Status:                    $Status"
        "============================================================"
        ""
    ) -join [Environment]::NewLine

    $Transcript = $Header + $CaptureText + $Footer

    Write-B32TextFile `
        -Content $Transcript `
        -Path $TranscriptPath |
        Out-Null

    $Result = [ordered]@{
        work_package = "B3.2"
        operation = "controlled-monitor"
        status = $Status
        timestamp_local = (Get-Date).ToString("o")
        profile = $NormalizedProfile
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
            baud = $Baud
            hardware_compatibility = $HardwareCompatibility
        }
        build = [ordered]@{
            directory = $Layout.BuildDir
            generated_sdkconfig = $Layout.Sdkconfig
            application_elf = $ElfRecord.Path
            application_elf_sha256 = $ElfRecord.SHA256
        }
        monitor = [ordered]@{
            validation_mode = $ValidationMode
            requested_duration_seconds = $DurationSeconds
            actual_duration_seconds = $ActualDurationSeconds
            captured_characters = $CapturedCharacterCount
            heartbeat_records = $HeartbeatCount
            rom_banner_detected = $RomBannerDetected
            reset_reason_detected = $ResetReasonDetected
            entry_point_detected = $EntryPointDetected
            fatal_markers = $FatalCount
            transcript = $TranscriptPath
        }
    }

    Write-B32JsonFile `
        -InputObject $Result `
        -Path $ResultPath `
        -Depth 12 |
        Out-Null

    $Summary = @(
        "============================================================"
        "B3.2 CONTROLLED MONITOR"
        "============================================================"
        "Status:                    $Status"
        "Timestamp:                 $((Get-Date).ToString('o'))"
        "Profile:                   $NormalizedProfile"
        "Repository:                $($Environment.RepoRoot)"
        "Branch:                    $($RepositoryState.Branch)"
        "Commit:                    $($RepositoryState.Commit)"
        "ESP-IDF:                   $($Environment.IdfVersion)"
        "Target:                    esp32s3"
        "Hardware compatibility:    $HardwareCompatibility"
        "Build directory:           $($Layout.BuildDir)"
        "Serial port:               $($ResolvedPort.Port)"
        "Serial device:             $($ResolvedPort.Name)"
        "Baud:                      $Baud"
        "Requested duration:        $DurationSeconds"
        "Actual duration:           $ActualDurationSeconds"
        "Validation mode:           $ValidationMode"
        "Captured characters:       $CapturedCharacterCount"
        "Heartbeat records:         $HeartbeatCount"
        "ROM banner detected:       $RomBannerDetected"
        "Reset reason detected:     $ResetReasonDetected"
        "Entry point detected:      $EntryPointDetected"
        "Fatal markers:             $FatalCount"
        "Application ELF:           $ElfRecord.Path"
        "ELF SHA256:                $($ElfRecord.SHA256)"
        "Transcript:                $TranscriptPath"
        "Result JSON:               $ResultPath"
        ""
        "B3.2 CONTROLLED MONITOR $Status"
    ) -join [Environment]::NewLine

    Write-B32TextFile `
        -Content ($Summary + [Environment]::NewLine) `
        -Path $SummaryPath |
        Out-Null

    if ($Status -ne "PASS") {
        if ($NormalizedProfile -eq "production") {
            throw "Production boot-sequence validation failed on $($ResolvedPort.Port). Transcript: $TranscriptPath"
        }

        throw "Firmware heartbeat validation failed on $($ResolvedPort.Port). Transcript: $TranscriptPath"
    }

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED MONITOR PASSED"
    Write-Host "============================================================"
    Write-Host "Profile:       $NormalizedProfile"
    Write-Host "Port:          $($ResolvedPort.Port)"
    Write-Host "Baud:          $Baud"
    Write-Host "Validation:    $ValidationMode"
    Write-Host "Heartbeats:    $HeartbeatCount"
    Write-Host "ROM banner:    $RomBannerDetected"
    Write-Host "Reset reason:  $ResetReasonDetected"
    Write-Host "Entry point:   $EntryPointDetected"
    Write-Host "Fatal markers: $FatalCount"
    Write-Host "Transcript:    $TranscriptPath"
    Write-Host "Summary:       $SummaryPath"
    Write-Host "Result JSON:   $ResultPath"
}
catch {
    if ($null -ne $Serial) {
        try {
            if ($Serial.IsOpen) {
                $Serial.Close()
            }

            $Serial.Dispose()
        }
        catch {
        }
    }

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED MONITOR FAILED"
    Write-Host "============================================================"
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
