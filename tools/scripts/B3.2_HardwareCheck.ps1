[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^COM\d+$')]
    [string]$Port,

    [ValidateRange(115200, 921600)]
    [int]$Baud = 115200,

    [ValidateRange(5, 60)]
    [int]$BootCaptureSeconds = 10,

    [string]$RepoRoot = "D:\OneDrive\SQD",

    [string]$IdfPath = "D:\esp\v6.0.2\esp-idf",

    [string]$HardwareCompatibility = "heltec-wifi-lora-32-v3"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CommonLibrary = Join-Path $PSScriptRoot "B3.2_Common.ps1"
$MonitorScript = Join-Path $PSScriptRoot "B3.2_Monitor.ps1"

foreach ($RequiredScript in @($CommonLibrary, $MonitorScript)) {
    if (-not (Test-Path -LiteralPath $RequiredScript -PathType Leaf)) {
        throw "Required B3.2 script is missing: $RequiredScript"
    }
}

. $CommonLibrary

$Timestamp = Get-B32Timestamp
$EvidenceDir = Get-B32EvidenceDirectory -RepoRoot $RepoRoot

$SummaryPath = Join-Path `
    $EvidenceDir `
    "B3.2_hardware_identity_summary_${Timestamp}.txt"

$ResultPath = Join-Path `
    $EvidenceDir `
    "B3.2_hardware_identity_result_${Timestamp}.json"

$CsvPath = Join-Path `
    $EvidenceDir `
    "B3.2_hardware_identity_results_${Timestamp}.csv"

$ChipStdoutPath = Join-Path `
    $EvidenceDir `
    "B3.2_hardware_chip_id_stdout_${Timestamp}.txt"

$ChipStderrPath = Join-Path `
    $EvidenceDir `
    "B3.2_hardware_chip_id_stderr_${Timestamp}.txt"

$FlashStdoutPath = Join-Path `
    $EvidenceDir `
    "B3.2_hardware_flash_id_stdout_${Timestamp}.txt"

$FlashStderrPath = Join-Path `
    $EvidenceDir `
    "B3.2_hardware_flash_id_stderr_${Timestamp}.txt"

$Checks = New-Object System.Collections.Generic.List[object]

function Add-B32HardwareCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [ValidateSet("PASS", "FAIL", "NOT_TESTED")]
        [string]$Status,

        [string]$Observed = "",

        [string]$Expected = "",

        [string]$Evidence = ""
    )

    $Checks.Add(
        [PSCustomObject]@{
            Id = $Id
            Description = $Description
            Status = $Status
            Expected = $Expected
            Observed = $Observed
            Evidence = $Evidence
        }
    )
}

function Assert-B32Pattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [Parameter(Mandatory)]
        [string]$FailureMessage
    )

    if ($Text -notmatch $Pattern) {
        throw $FailureMessage
    }

    $Matches
}

function Get-B32NewestHardwareEvidence {
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
        throw "No new $Description matched '$Filter'."
    }

    $Match
}

try {
    Write-B32Section -Title "B3.2 HARDWARE IDENTITY AND TRANSPORT CHECK"

    $Environment = Initialize-B32IdfEnvironment `
        -RepoRoot $RepoRoot `
        -IdfPath $IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $Branch = Assert-B32FeatureBranch -RepoRoot $Environment.RepoRoot
    Assert-B32TrackedTreeClean -RepoRoot $Environment.RepoRoot | Out-Null

    $RepositoryState = Get-B32RepositoryState -RepoRoot $Environment.RepoRoot
    $ResolvedPort = Resolve-B32SerialPort -Port $Port

    Write-Host "Branch:        $Branch"
    Write-Host "Commit:        $($RepositoryState.Commit)"
    Write-Host "ESP-IDF:       $($Environment.IdfVersion)"
    Write-Host "Port:          $($ResolvedPort.Port)"
    Write-Host "Device:        $($ResolvedPort.Name)"
    Write-Host "Baud:          $Baud"
    Write-Host "Hardware:      $HardwareCompatibility"
    Write-Host ""

    $ChipArguments = @(
        "-m"
        "esptool"
        "-p"
        $ResolvedPort.Port
        "-b"
        [string]$Baud
        "--chip"
        "esp32s3"
        "chip-id"
    )

    $ChipResult = Invoke-B32CapturedProcess `
        -FilePath $Environment.PythonExe `
        -ArgumentList $ChipArguments `
        -WorkingDirectory $Environment.RepoRoot `
        -StdoutPath $ChipStdoutPath `
        -StderrPath $ChipStderrPath `
        -Operation "ESP32-S3 chip identity"

    $ChipText = @(
        $ChipResult.Stdout
        $ChipResult.Stderr
    ) -join [Environment]::NewLine

    $FlashArguments = @(
        "-m"
        "esptool"
        "-p"
        $ResolvedPort.Port
        "-b"
        [string]$Baud
        "--chip"
        "esp32s3"
        "flash-id"
    )

    $FlashResult = Invoke-B32CapturedProcess `
        -FilePath $Environment.PythonExe `
        -ArgumentList $FlashArguments `
        -WorkingDirectory $Environment.RepoRoot `
        -StdoutPath $FlashStdoutPath `
        -StderrPath $FlashStderrPath `
        -Operation "ESP32-S3 flash identity"

    $FlashText = @(
        $FlashResult.Stdout
        $FlashResult.Stderr
    ) -join [Environment]::NewLine

    $ChipMatch = Assert-B32Pattern `
        -Text $ChipText `
        -Pattern '(?im)Connected to\s+ESP32-S3' `
        -FailureMessage "esptool did not identify an ESP32-S3."

    Add-B32HardwareCheck `
        -Id "H01" `
        -Description "MCU family identity" `
        -Status "PASS" `
        -Expected "ESP32-S3" `
        -Observed "ESP32-S3" `
        -Evidence $ChipStdoutPath

    $RevisionMatch = Assert-B32Pattern `
        -Text $ChipText `
        -Pattern '(?im)Chip type:\s*ESP32-S3.*revision\s+v([0-9.]+)' `
        -FailureMessage "ESP32-S3 silicon revision was not reported."

    $ChipRevision = [string]$RevisionMatch[1]

    Add-B32HardwareCheck `
        -Id "H02" `
        -Description "MCU silicon revision reported" `
        -Status "PASS" `
        -Expected "Reported by esptool" `
        -Observed "v$ChipRevision" `
        -Evidence $ChipStdoutPath

    $FeatureMatch = Assert-B32Pattern `
        -Text $ChipText `
        -Pattern '(?im)Features:\s*(.+)$' `
        -FailureMessage "ESP32-S3 feature line was not reported."

    $FeatureText = ([string]$FeatureMatch[1]).Trim()

    if (
        $FeatureText -notmatch '(?i)Wi-?Fi' -or
        $FeatureText -notmatch '(?i)BT\s*5'
    ) {
        throw "Expected Wi-Fi and BT 5 capabilities were not both reported: $FeatureText"
    }

    Add-B32HardwareCheck `
        -Id "H03" `
        -Description "Integrated radio capabilities" `
        -Status "PASS" `
        -Expected "Wi-Fi and BT 5" `
        -Observed $FeatureText `
        -Evidence $ChipStdoutPath

    $CrystalMatch = Assert-B32Pattern `
        -Text $ChipText `
        -Pattern '(?im)Crystal frequency:\s*([0-9]+MHz)' `
        -FailureMessage "Crystal frequency was not reported."

    $CrystalFrequency = [string]$CrystalMatch[1]

    if ($CrystalFrequency -ne "40MHz") {
        throw "Unexpected crystal frequency: $CrystalFrequency"
    }

    Add-B32HardwareCheck `
        -Id "H04" `
        -Description "Crystal frequency" `
        -Status "PASS" `
        -Expected "40MHz" `
        -Observed $CrystalFrequency `
        -Evidence $ChipStdoutPath

    $MacMatch = Assert-B32Pattern `
        -Text $ChipText `
        -Pattern '(?im)MAC:\s*([0-9A-Fa-f:]{17})' `
        -FailureMessage "Device MAC address was not reported."

    $MacAddress = ([string]$MacMatch[1]).ToLowerInvariant()

    Add-B32HardwareCheck `
        -Id "H05" `
        -Description "Unique device MAC address" `
        -Status "PASS" `
        -Expected "Valid 48-bit MAC" `
        -Observed $MacAddress `
        -Evidence $ChipStdoutPath

    $FlashSizeMatch = Assert-B32Pattern `
        -Text $FlashText `
        -Pattern '(?im)(?:Detected flash size|Flash size):\s*(8MB)' `
        -FailureMessage "The expected 8 MB flash size was not reported."

    $FlashSize = [string]$FlashSizeMatch[1]

    Add-B32HardwareCheck `
        -Id "H06" `
        -Description "External SPI flash capacity" `
        -Status "PASS" `
        -Expected "8MB" `
        -Observed $FlashSize `
        -Evidence $FlashStdoutPath

    $UsbUartPass = (
        $ResolvedPort.Name -match '(?i)CP210x|Silicon Labs' -or
        $ResolvedPort.Description -match '(?i)CP210x|Silicon Labs'
    )

    if (-not $UsbUartPass) {
        throw "COM port does not identify the expected Silicon Labs CP210x USB-UART bridge."
    }

    Add-B32HardwareCheck `
        -Id "H07" `
        -Description "USB-to-UART transport identity" `
        -Status "PASS" `
        -Expected "Silicon Labs CP210x" `
        -Observed $ResolvedPort.Name `
        -Evidence $ResolvedPort.PnpDeviceId

    $MonitorStartUtc = [DateTime]::UtcNow

    & $MonitorScript `
        -Profile production `
        -Port $ResolvedPort.Port `
        -Baud 115200 `
        -DurationSeconds $BootCaptureSeconds `
        -RepoRoot $Environment.RepoRoot `
        -IdfPath $Environment.IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $MonitorResultFile = Get-B32NewestHardwareEvidence `
        -Filter "B3.2_production_monitor_result_*.json" `
        -NotBeforeUtc $MonitorStartUtc `
        -Description "production monitor result"

    $MonitorEvidence = Get-Content `
        -LiteralPath $MonitorResultFile.FullName `
        -Raw |
        ConvertFrom-Json

    if ([string]$MonitorEvidence.status -ne "PASS") {
        throw "Production boot monitor did not report PASS."
    }

    if (
        -not [bool]$MonitorEvidence.monitor.rom_banner_detected -or
        -not [bool]$MonitorEvidence.monitor.reset_reason_detected -or
        -not [bool]$MonitorEvidence.monitor.entry_point_detected -or
        [int]$MonitorEvidence.monitor.fatal_markers -ne 0
    ) {
        throw "Production boot-sequence evidence is incomplete or contains fatal markers."
    }

    Add-B32HardwareCheck `
        -Id "H08" `
        -Description "Production boot over physical hardware" `
        -Status "PASS" `
        -Expected "ROM, reset reason, entry point, zero fatal markers" `
        -Observed "ROM=True; Reset=True; Entry=True; Fatal=0" `
        -Evidence $MonitorResultFile.FullName

    foreach ($Peripheral in @(
        [PSCustomObject]@{
            Id = "H09"
            Name = "SX1262 LoRa radio functional test"
        }
        [PSCustomObject]@{
            Id = "H10"
            Name = "OLED display functional test"
        }
        [PSCustomObject]@{
            Id = "H11"
            Name = "User button and reset-button input test"
        }
        [PSCustomObject]@{
            Id = "H12"
            Name = "Board LED output test"
        }
        [PSCustomObject]@{
            Id = "H13"
            Name = "Battery-voltage ADC test"
        }
        [PSCustomObject]@{
            Id = "H14"
            Name = "Wi-Fi RF association test"
        }
        [PSCustomObject]@{
            Id = "H15"
            Name = "Bluetooth LE advertising test"
        }
    )) {
        Add-B32HardwareCheck `
            -Id $Peripheral.Id `
            -Description $Peripheral.Name `
            -Status "NOT_TESTED" `
            -Expected "Dedicated hardware self-test firmware" `
            -Observed "Not exercised by the current minimal firmware" `
            -Evidence ""
    }

    [object[]]$CheckArray = $Checks.ToArray()

    $PassCount = @(
        $CheckArray |
        Where-Object Status -eq "PASS"
    ).Count

    $FailCount = @(
        $CheckArray |
        Where-Object Status -eq "FAIL"
    ).Count

    $NotTestedCount = @(
        $CheckArray |
        Where-Object Status -eq "NOT_TESTED"
    ).Count

    $OverallStatus = if ($FailCount -eq 0) {
        "PASS"
    }
    else {
        "FAIL"
    }

    $CheckArray |
        Export-Csv `
            -LiteralPath $CsvPath `
            -NoTypeInformation `
            -Encoding UTF8

    $Result = [ordered]@{
        work_package = "B3.2"
        operation = "hardware-identity-and-transport-check"
        scope = "identity-transport-and-production-boot"
        status = $OverallStatus
        timestamp_local = (Get-Date).ToString("o")
        limitation = "Board peripheral functions require dedicated self-test firmware and are recorded as NOT_TESTED."
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
            esptool = "5.3.1 or active ESP-IDF environment version"
            target = "esp32s3"
        }
        device = [ordered]@{
            hardware_compatibility = $HardwareCompatibility
            serial_port = $ResolvedPort.Port
            serial_device = $ResolvedPort.Name
            pnp_device_id = $ResolvedPort.PnpDeviceId
            chip = "ESP32-S3"
            revision = "v$ChipRevision"
            features = $FeatureText
            crystal = $CrystalFrequency
            flash_size = $FlashSize
            mac = $MacAddress
        }
        totals = [ordered]@{
            pass = $PassCount
            fail = $FailCount
            not_tested = $NotTestedCount
            total = $CheckArray.Count
        }
        checks = $CheckArray
        evidence = [ordered]@{
            summary = $SummaryPath
            result_json = $ResultPath
            results_csv = $CsvPath
            chip_stdout = $ChipStdoutPath
            chip_stderr = $ChipStderrPath
            flash_stdout = $FlashStdoutPath
            flash_stderr = $FlashStderrPath
            production_monitor_result = $MonitorResultFile.FullName
            production_monitor_transcript = [string]$MonitorEvidence.monitor.transcript
        }
    }

    Write-B32JsonFile `
        -InputObject $Result `
        -Path $ResultPath `
        -Depth 16 |
        Out-Null

    $CheckLines = @(
        foreach ($Check in $CheckArray) {
            "[$($Check.Status)] $($Check.Id) - $($Check.Description): $($Check.Observed)"
        }
    )

    $Summary = @(
        "============================================================"
        "B3.2 HARDWARE IDENTITY AND TRANSPORT CHECK"
        "============================================================"
        "Status:                    $OverallStatus"
        "Scope:                     Identity, transport, production boot"
        "Timestamp:                 $((Get-Date).ToString('o'))"
        "Repository:                $($Environment.RepoRoot)"
        "Branch:                    $($RepositoryState.Branch)"
        "Commit:                    $($RepositoryState.Commit)"
        "ESP-IDF:                   $($Environment.IdfVersion)"
        "Hardware compatibility:    $HardwareCompatibility"
        "Serial port:               $($ResolvedPort.Port)"
        "Serial device:             $($ResolvedPort.Name)"
        "MCU:                       ESP32-S3"
        "Silicon revision:          v$ChipRevision"
        "Features:                  $FeatureText"
        "Crystal:                   $CrystalFrequency"
        "Flash capacity:            $FlashSize"
        "MAC:                       $MacAddress"
        "Checks passed:             $PassCount"
        "Checks failed:             $FailCount"
        "Checks not tested:         $NotTestedCount"
        "Checks total:              $($CheckArray.Count)"
        ""
        "Limitation"
        "----------"
        "LoRa, OLED, buttons, LED, battery ADC, Wi-Fi association, and BLE"
        "advertising require dedicated self-test firmware. They are not"
        "claimed as passed by this B3.2 identity-and-transport check."
        ""
        "Checks"
        "------"
        $CheckLines
        ""
        "Results CSV:               $CsvPath"
        "Result JSON:               $ResultPath"
        "Chip stdout:               $ChipStdoutPath"
        "Chip stderr:               $ChipStderrPath"
        "Flash stdout:              $FlashStdoutPath"
        "Flash stderr:              $FlashStderrPath"
        "Production monitor result: $($MonitorResultFile.FullName)"
        ""
        "B3.2 HARDWARE IDENTITY AND TRANSPORT CHECK $OverallStatus"
    ) -join [Environment]::NewLine

    Write-B32TextFile `
        -Content ($Summary + [Environment]::NewLine) `
        -Path $SummaryPath |
        Out-Null

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 HARDWARE IDENTITY AND TRANSPORT CHECK $OverallStatus"
    Write-Host "============================================================"
    Write-Host "MCU:         ESP32-S3"
    Write-Host "Revision:    v$ChipRevision"
    Write-Host "Flash:       $FlashSize"
    Write-Host "Crystal:     $CrystalFrequency"
    Write-Host "MAC:         $MacAddress"
    Write-Host "USB-UART:    $($ResolvedPort.Name)"
    Write-Host "Production:  BOOT PASS"
    Write-Host "PASS:        $PassCount"
    Write-Host "FAIL:        $FailCount"
    Write-Host "NOT TESTED:  $NotTestedCount"
    Write-Host "Summary:     $SummaryPath"
    Write-Host "Result JSON: $ResultPath"
    Write-Host "Results CSV: $CsvPath"

    if ($FailCount -gt 0) {
        throw "B3.2 hardware identity and transport check failed with $FailCount failed check(s)."
    }
}
catch {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 HARDWARE IDENTITY AND TRANSPORT CHECK FAILED"
    Write-Host "============================================================"
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
