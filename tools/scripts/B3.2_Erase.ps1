[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^COM\d+$')]
    [string]$Port,

    [ValidateRange(115200, 2000000)]
    [int]$Baud = 921600,

    [Parameter(Mandatory)]
    [switch]$ConfirmErase,

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
$EvidenceDir = Get-B32EvidenceDirectory -RepoRoot $RepoRoot

$SummaryPath = Join-Path `
    $EvidenceDir `
    "B3.2_erase_summary_${Timestamp}.txt"

$ResultPath = Join-Path `
    $EvidenceDir `
    "B3.2_erase_result_${Timestamp}.json"

try {
    Write-B32Section -Title "B3.2 CONTROLLED FLASH ERASE"

    if (-not $ConfirmErase.IsPresent) {
        throw "Flash erase was not authorized. Re-run with -ConfirmErase."
    }

    $Environment = Initialize-B32IdfEnvironment `
        -RepoRoot $RepoRoot `
        -IdfPath $IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $Branch = Assert-B32FeatureBranch -RepoRoot $Environment.RepoRoot
    Assert-B32TrackedTreeClean -RepoRoot $Environment.RepoRoot | Out-Null

    $RepositoryState = Get-B32RepositoryState -RepoRoot $Environment.RepoRoot
    $ResolvedPort = Resolve-B32SerialPort -Port $Port

    $EraseArguments = @(
        "-p"
        $ResolvedPort.Port
        "-b"
        [string]$Baud
        "erase-flash"
    )

    Write-Host "Branch:        $Branch"
    Write-Host "Commit:        $($RepositoryState.Commit)"
    Write-Host "ESP-IDF:       $($Environment.IdfVersion)"
    Write-Host "Port:          $($ResolvedPort.Port)"
    Write-Host "Device:        $($ResolvedPort.Name)"
    Write-Host "Baud:          $Baud"
    Write-Host "Hardware:      $HardwareCompatibility"
    Write-Host ""
    Write-Host "WARNING: The complete external SPI flash will be erased."
    Write-Host ""

    $EraseResult = Invoke-B32Idf `
        -Environment $Environment `
        -Arguments $EraseArguments `
        -Operation "erase_flash" `
        -EvidenceStem "B3.2" `
        -Timestamp $Timestamp

    $Result = [ordered]@{
        work_package = "B3.2"
        operation = "controlled-flash-erase"
        status = "PASS"
        timestamp_local = (Get-Date).ToString("o")
        authorization = [ordered]@{
            confirm_erase = $ConfirmErase.IsPresent
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
            python = $Environment.PythonExe
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
        erase = [ordered]@{
            duration_seconds = $EraseResult.DurationSeconds
            stdout = $EraseResult.StdoutPath
            stderr = $EraseResult.StderrPath
        }
    }

    Write-B32JsonFile `
        -InputObject $Result `
        -Path $ResultPath `
        -Depth 12 |
        Out-Null

    $Summary = @(
        "============================================================"
        "B3.2 CONTROLLED FLASH ERASE"
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
        "Baud:                      $Baud"
        "Erase authorized:          $($ConfirmErase.IsPresent)"
        "Erase duration seconds:    $($EraseResult.DurationSeconds)"
        "Erase stdout:              $($EraseResult.StdoutPath)"
        "Erase stderr:              $($EraseResult.StderrPath)"
        "Result JSON:               $ResultPath"
        ""
        "B3.2 CONTROLLED FLASH ERASE PASSED"
    ) -join [Environment]::NewLine

    Write-B32TextFile `
        -Content ($Summary + [Environment]::NewLine) `
        -Path $SummaryPath |
        Out-Null

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED FLASH ERASE PASSED"
    Write-Host "============================================================"
    Write-Host "Port:        $($ResolvedPort.Port)"
    Write-Host "Baud:        $Baud"
    Write-Host "Summary:     $SummaryPath"
    Write-Host "Result JSON: $ResultPath"
}
catch {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED FLASH ERASE FAILED"
    Write-Host "============================================================"
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
