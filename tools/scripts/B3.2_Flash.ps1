[CmdletBinding()]
param(
    [ValidateSet("debug", "validation", "production")]
    [string]$Profile = "debug",

    [Parameter(Mandatory)]
    [ValidatePattern('^COM\d+$')]
    [string]$Port,

    [ValidateRange(115200, 2000000)]
    [int]$Baud = 921600,

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

$SummaryPath = Join-Path $EvidenceDir "B3.2_${NormalizedProfile}_flash_summary_${Timestamp}.txt"
$ResultPath = Join-Path $EvidenceDir "B3.2_${NormalizedProfile}_flash_result_${Timestamp}.json"

try {
    Write-B32Section -Title "B3.2 CONTROLLED FLASH: $($NormalizedProfile.ToUpperInvariant())"

    $Environment = Initialize-B32IdfEnvironment `
        -RepoRoot $RepoRoot `
        -IdfPath $IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $Branch = Assert-B32FeatureBranch -RepoRoot $Environment.RepoRoot
    Assert-B32TrackedTreeClean -RepoRoot $Environment.RepoRoot | Out-Null

    $RepositoryState = Get-B32RepositoryState -RepoRoot $Environment.RepoRoot
    $Layout = Get-B32BuildLayout -RepoRoot $Environment.RepoRoot -Profile $NormalizedProfile
    $ResolvedPort = Resolve-B32SerialPort -Port $Port

    Assert-B32Directory -Path $Layout.BuildDir -Description "$NormalizedProfile build" | Out-Null
    Assert-B32GeneratedConfiguration -SdkconfigPath $Layout.Sdkconfig -Profile $NormalizedProfile | Out-Null
    Assert-B32File -Path $Layout.ProjectDescription -Description "ESP-IDF project description" | Out-Null
    Assert-B32File -Path $Layout.FlasherArgs -Description "ESP-IDF flash arguments" | Out-Null

    $Artifacts = @(Get-B32ProjectArtifacts -BuildDir $Layout.BuildDir)

    if ($Artifacts.Count -eq 0) {
        throw "No flashable artifacts were found in $($Layout.BuildDir). Run B3.2_Build.ps1 first."
    }

    $ArtifactRecords = @(
        foreach ($Artifact in $Artifacts) {
            Get-B32FileRecord -Path $Artifact.Path -Role $Artifact.Role -RepoRoot $Environment.RepoRoot
        }
    )

    $ApplicationBinary = @(
        $ArtifactRecords | Where-Object Role -eq "application-bin"
    ) | Select-Object -First 1

    if ($null -eq $ApplicationBinary) {
        throw "Application binary is missing from $($Layout.BuildDir)."
    }

    $env:SQD_BUILD_PROFILE = $NormalizedProfile
    $env:SQD_HARDWARE_COMPATIBILITY = $HardwareCompatibility

    $BuildDirCMake = $Layout.BuildDir.Replace("\", "/")

    $FlashArguments = @(
        "-p"
        $ResolvedPort.Port
        "-b"
        [string]$Baud
        "-B"
        $BuildDirCMake
        "flash"
    )

    Write-Host "Profile:       $NormalizedProfile"
    Write-Host "Branch:        $Branch"
    Write-Host "Commit:        $($RepositoryState.Commit)"
    Write-Host "ESP-IDF:       $($Environment.IdfVersion)"
    Write-Host "Build dir:     $($Layout.BuildDir)"
    Write-Host "Port:          $($ResolvedPort.Port)"
    Write-Host "Device:        $($ResolvedPort.Name)"
    Write-Host "Baud:          $Baud"
    Write-Host "App binary:    $($ApplicationBinary.Path)"
    Write-Host "App SHA256:    $($ApplicationBinary.SHA256)"
    Write-Host ""

    $FlashResult = Invoke-B32Idf `
        -Environment $Environment `
        -Arguments $FlashArguments `
        -Operation "${NormalizedProfile}_flash" `
        -EvidenceStem "B3.2" `
        -Timestamp $Timestamp

    $Result = [ordered]@{
        work_package = "B3.2"
        operation = "controlled-flash"
        status = "PASS"
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
        build = [ordered]@{
            directory = $Layout.BuildDir
            generated_sdkconfig = $Layout.Sdkconfig
            flasher_args = $Layout.FlasherArgs
        }
        application_binary = [ordered]@{
            path = $ApplicationBinary.Path
            relative_path = $ApplicationBinary.RelativePath
            size_bytes = $ApplicationBinary.SizeBytes
            sha256 = $ApplicationBinary.SHA256
        }
        flash = [ordered]@{
            duration_seconds = $FlashResult.DurationSeconds
            stdout = $FlashResult.StdoutPath
            stderr = $FlashResult.StderrPath
        }
    }

    Write-B32JsonFile -InputObject $Result -Path $ResultPath -Depth 12 | Out-Null

    $Summary = @(
        "============================================================"
        "B3.2 CONTROLLED FLASH"
        "============================================================"
        "Status:                    PASS"
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
        "Application binary:        $($ApplicationBinary.Path)"
        "Application bytes:         $($ApplicationBinary.SizeBytes)"
        "Application SHA256:        $($ApplicationBinary.SHA256)"
        "Flash duration seconds:    $($FlashResult.DurationSeconds)"
        "Flash stdout:              $($FlashResult.StdoutPath)"
        "Flash stderr:              $($FlashResult.StderrPath)"
        "Result JSON:               $ResultPath"
        ""
        "B3.2 CONTROLLED FLASH PASSED"
    ) -join [Environment]::NewLine

    Write-B32TextFile -Content ($Summary + [Environment]::NewLine) -Path $SummaryPath | Out-Null

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED FLASH PASSED"
    Write-Host "============================================================"
    Write-Host "Profile:     $NormalizedProfile"
    Write-Host "Port:        $($ResolvedPort.Port)"
    Write-Host "Baud:        $Baud"
    Write-Host "App binary:  $($ApplicationBinary.Path)"
    Write-Host "SHA256:      $($ApplicationBinary.SHA256)"
    Write-Host "Summary:     $SummaryPath"
    Write-Host "Result JSON: $ResultPath"
}
catch {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED FLASH FAILED"
    Write-Host "============================================================"
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
