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
    "B3.2_bootstrap_summary_${Timestamp}.txt"

$ResultPath = Join-Path `
    $EvidenceDir `
    "B3.2_bootstrap_result_${Timestamp}.json"

$ManifestCsvPath = Join-Path `
    $EvidenceDir `
    "B3.2_bootstrap_file_manifest_${Timestamp}.csv"

$ManifestJsonPath = Join-Path `
    $EvidenceDir `
    "B3.2_bootstrap_file_manifest_${Timestamp}.json"

try {
    Write-B32Section -Title "B3.2 CONTROLLED TOOLING BOOTSTRAP"

    $Environment = Initialize-B32IdfEnvironment `
        -RepoRoot $RepoRoot `
        -IdfPath $IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $Branch = Assert-B32FeatureBranch -RepoRoot $Environment.RepoRoot
    Assert-B32TrackedTreeClean -RepoRoot $Environment.RepoRoot | Out-Null

    $RepositoryState = Get-B32RepositoryState -RepoRoot $Environment.RepoRoot

    $RequiredFiles = @(
        [PSCustomObject]@{
            Role = "common-library"
            Path = Join-Path $Environment.RepoRoot "tools\scripts\B3.2_Common.ps1"
        }
        [PSCustomObject]@{
            Role = "build-entry-point"
            Path = Join-Path $Environment.RepoRoot "tools\scripts\B3.2_Build.ps1"
        }
        [PSCustomObject]@{
            Role = "flash-entry-point"
            Path = Join-Path $Environment.RepoRoot "tools\scripts\B3.2_Flash.ps1"
        }
        [PSCustomObject]@{
            Role = "monitor-entry-point"
            Path = Join-Path $Environment.RepoRoot "tools\scripts\B3.2_Monitor.ps1"
        }
        [PSCustomObject]@{
            Role = "erase-entry-point"
            Path = Join-Path $Environment.RepoRoot "tools\scripts\B3.2_Erase.ps1"
        }
        [PSCustomObject]@{
            Role = "common-sdkconfig-defaults"
            Path = Join-Path $Environment.RepoRoot "sdkconfig.defaults"
        }
        [PSCustomObject]@{
            Role = "debug-sdkconfig-defaults"
            Path = Join-Path $Environment.RepoRoot "sdkconfig.defaults.debug"
        }
        [PSCustomObject]@{
            Role = "validation-sdkconfig-defaults"
            Path = Join-Path $Environment.RepoRoot "sdkconfig.defaults.validation"
        }
        [PSCustomObject]@{
            Role = "production-sdkconfig-defaults"
            Path = Join-Path $Environment.RepoRoot "sdkconfig.defaults.production"
        }
    )

    $FileRecords = @(
        foreach ($RequiredFile in $RequiredFiles) {
            Get-B32FileRecord `
                -Path $RequiredFile.Path `
                -Role $RequiredFile.Role `
                -RepoRoot $Environment.RepoRoot
        }
    )

    $ParserFailures = New-Object System.Collections.Generic.List[object]

    foreach ($ScriptRecord in @(
        $FileRecords |
        Where-Object { $_.RelativePath -like "*.ps1" }
    )) {
        $Tokens = $null
        $Errors = $null

        [System.Management.Automation.Language.Parser]::ParseFile(
            $ScriptRecord.Path,
            [ref]$Tokens,
            [ref]$Errors
        ) | Out-Null

        foreach ($ParserError in @($Errors)) {
            $ParserFailures.Add(
                [PSCustomObject]@{
                    Script = $ScriptRecord.RelativePath
                    Message = $ParserError.Message
                    Line = $ParserError.Extent.StartLineNumber
                    Column = $ParserError.Extent.StartColumnNumber
                }
            )
        }
    }

    if ($ParserFailures.Count -gt 0) {
        $FailureText = @(
            $ParserFailures |
            ForEach-Object {
                "$($_.Script):$($_.Line):$($_.Column): $($_.Message)"
            }
        ) -join [Environment]::NewLine

        throw "PowerShell syntax validation failed:`n$FailureText"
    }

    $ProfileChecks = @(
        foreach ($Profile in Get-B32ProfileNames) {
            $Defaults = Get-B32ProfileDefaults `
                -RepoRoot $Environment.RepoRoot `
                -Profile $Profile

            [PSCustomObject]@{
                Profile = $Profile
                CommonDefaults = $Defaults.Common
                OverlayDefaults = $Defaults.Overlay
                CMakeValue = $Defaults.CMakeValue
                Status = "PASS"
            }
        }
    )

    $Ports = @(Get-B32SerialPorts)

    if ($RequireDevice.IsPresent -and $Ports.Count -eq 0) {
        throw "No serial device was detected, but -RequireDevice was specified."
    }

    $FileRecords |
        Select-Object Role, RelativePath, SizeBytes, SHA256, LastWriteTimeUtc |
        Export-Csv `
            -LiteralPath $ManifestCsvPath `
            -NoTypeInformation `
            -Encoding UTF8

    Write-B32JsonFile `
        -InputObject $FileRecords `
        -Path $ManifestJsonPath `
        -Depth 8 |
        Out-Null

    $Result = [ordered]@{
        work_package = "B3.2"
        operation = "controlled-tooling-bootstrap"
        status = "PASS"
        timestamp_local = (Get-Date).ToString("o")
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
        hardware_compatibility = $HardwareCompatibility
        device_required = $RequireDevice.IsPresent
        detected_serial_ports = @($Ports)
        profile_checks = @($ProfileChecks)
        powershell_syntax = [ordered]@{
            status = "PASS"
            files_checked = @(
                $FileRecords |
                Where-Object { $_.RelativePath -like "*.ps1" }
            ).Count
        }
        required_files = [ordered]@{
            status = "PASS"
            count = $FileRecords.Count
            manifest_csv = $ManifestCsvPath
            manifest_json = $ManifestJsonPath
        }
    }

    Write-B32JsonFile `
        -InputObject $Result `
        -Path $ResultPath `
        -Depth 12 |
        Out-Null

    $PortSummary = if ($Ports.Count -eq 0) {
        "none"
    }
    else {
        @(
            $Ports |
            ForEach-Object { "$($_.Port) [$($_.Name)]" }
        ) -join "; "
    }

    $Summary = @(
        "============================================================"
        "B3.2 CONTROLLED TOOLING BOOTSTRAP"
        "============================================================"
        "Status:                    PASS"
        "Timestamp:                 $((Get-Date).ToString('o'))"
        "Repository:                $($Environment.RepoRoot)"
        "Branch:                    $($RepositoryState.Branch)"
        "Commit:                    $($RepositoryState.Commit)"
        "Tracked tree clean:         true"
        "ESP-IDF path:               $($Environment.IdfPath)"
        "ESP-IDF version:            $($Environment.IdfVersion)"
        "Python executable:          $($Environment.PythonExe)"
        "Target:                    esp32s3"
        "Hardware compatibility:    $HardwareCompatibility"
        "Profiles validated:         $((Get-B32ProfileNames) -join ', ')"
        "Required files checked:     $($FileRecords.Count)"
        "PowerShell syntax:          PASS"
        "Detected serial ports:      $PortSummary"
        "Device required:            $($RequireDevice.IsPresent)"
        "Manifest CSV:               $ManifestCsvPath"
        "Manifest JSON:              $ManifestJsonPath"
        "Result JSON:                $ResultPath"
        ""
        "B3.2 CONTROLLED TOOLING BOOTSTRAP PASSED"
    ) -join [Environment]::NewLine

    Write-B32TextFile `
        -Content ($Summary + [Environment]::NewLine) `
        -Path $SummaryPath |
        Out-Null

    Write-Host "Branch:        $Branch"
    Write-Host "Commit:        $($RepositoryState.Commit)"
    Write-Host "ESP-IDF:       $($Environment.IdfVersion)"
    Write-Host "Target:        esp32s3"
    Write-Host "Hardware:      $HardwareCompatibility"
    Write-Host "Profiles:      $((Get-B32ProfileNames) -join ', ')"
    Write-Host "Scripts:       PowerShell syntax PASS"
    Write-Host "Serial ports:  $PortSummary"
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED TOOLING BOOTSTRAP PASSED"
    Write-Host "============================================================"
    Write-Host "Summary:       $SummaryPath"
    Write-Host "Result JSON:   $ResultPath"
    Write-Host "Manifest CSV:  $ManifestCsvPath"
    Write-Host "Manifest JSON: $ManifestJsonPath"
}
catch {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED TOOLING BOOTSTRAP FAILED"
    Write-Host "============================================================"
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
