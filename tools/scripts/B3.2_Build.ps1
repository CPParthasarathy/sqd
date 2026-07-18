[CmdletBinding()]
param(
    [ValidateSet("debug", "validation", "production")]
    [string]$Profile = "debug",

    [string]$RepoRoot = "D:\OneDrive\SQD",

    [string]$IdfPath = "D:\esp\v6.0.2\esp-idf",

    [string]$HardwareCompatibility = "heltec-wifi-lora-32-v3",

    [switch]$Incremental
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

$SummaryPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_build_summary_${Timestamp}.txt"

$ResultPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_build_result_${Timestamp}.json"

$ManifestCsvPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_artifact_manifest_${Timestamp}.csv"

$ManifestJsonPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_artifact_manifest_${Timestamp}.json"

$SizeTextPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_size_${Timestamp}.txt"

$SizeJsonPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_size_${Timestamp}.json"

try {
    Write-B32Section -Title "B3.2 CONTROLLED BUILD: $($NormalizedProfile.ToUpperInvariant())"

    $Environment = Initialize-B32IdfEnvironment `
        -RepoRoot $RepoRoot `
        -IdfPath $IdfPath `
        -HardwareCompatibility $HardwareCompatibility

    $Branch = Assert-B32FeatureBranch -RepoRoot $Environment.RepoRoot
    Assert-B32TrackedTreeClean -RepoRoot $Environment.RepoRoot | Out-Null

    $RepositoryState = Get-B32RepositoryState -RepoRoot $Environment.RepoRoot
    $Defaults = Get-B32ProfileDefaults `
        -RepoRoot $Environment.RepoRoot `
        -Profile $NormalizedProfile

    $Layout = Get-B32BuildLayout `
        -RepoRoot $Environment.RepoRoot `
        -Profile $NormalizedProfile

    $env:SQD_BUILD_PROFILE = $NormalizedProfile
    $env:SQD_HARDWARE_COMPATIBILITY = $HardwareCompatibility

    if (-not $Incremental) {
        if (Test-Path -LiteralPath $Layout.BuildDir) {
            Remove-Item -LiteralPath $Layout.BuildDir -Recurse -Force
        }

        Write-Host "Build mode: clean"
    }
    else {
        Write-Host "Build mode: incremental"
    }

    New-B32Directory -Path $Layout.BuildDir | Out-Null

    $BuildDirCMake = $Layout.BuildDir.Replace("\", "/")
    $SdkconfigCMake = $Layout.Sdkconfig.Replace("\", "/")

    $BuildArguments = @(
        "-DIDF_TARGET=esp32s3"
        "-DSDKCONFIG=$SdkconfigCMake"
        "-DSDKCONFIG_DEFAULTS=$($Defaults.CMakeValue)"
        "-B"
        $BuildDirCMake
        "build"
    )

    Write-Host "Profile:       $NormalizedProfile"
    Write-Host "Branch:        $Branch"
    Write-Host "Commit:        $($RepositoryState.Commit)"
    Write-Host "ESP-IDF:       $($Environment.IdfVersion)"
    Write-Host "Build dir:     $($Layout.BuildDir)"
    Write-Host "Defaults:      $($Defaults.CMakeValue)"
    Write-Host "Hardware:      $HardwareCompatibility"
    Write-Host ""

    $BuildResult = Invoke-B32Idf `
        -Environment $Environment `
        -Arguments $BuildArguments `
        -Operation "${NormalizedProfile}_build" `
        -EvidenceStem "B3.2" `
        -Timestamp $Timestamp

    Assert-B32GeneratedConfiguration `
        -SdkconfigPath $Layout.Sdkconfig `
        -Profile $NormalizedProfile |
        Out-Null

    $SizeTextArguments = @(
        "-B"
        $BuildDirCMake
        "size"
        "--format"
        "text"
        "--output-file"
        $SizeTextPath
    )

    $SizeTextResult = Invoke-B32Idf `
        -Environment $Environment `
        -Arguments $SizeTextArguments `
        -Operation "${NormalizedProfile}_size_text" `
        -EvidenceStem "B3.2" `
        -Timestamp $Timestamp

    $SizeJsonArguments = @(
        "-B"
        $BuildDirCMake
        "size"
        "--format"
        "json2"
        "--output-file"
        $SizeJsonPath
    )

    $SizeJsonResult = Invoke-B32Idf `
        -Environment $Environment `
        -Arguments $SizeJsonArguments `
        -Operation "${NormalizedProfile}_size_json" `
        -EvidenceStem "B3.2" `
        -Timestamp $Timestamp

    Assert-B32File -Path $SizeTextPath -Description "Text size report" | Out-Null
    Assert-B32File -Path $SizeJsonPath -Description "JSON size report" | Out-Null

    $ProjectDescription = Get-B32ProjectDescription -BuildDir $Layout.BuildDir
    $Artifacts = @(Get-B32ProjectArtifacts -BuildDir $Layout.BuildDir)

    if ($Artifacts.Count -eq 0) {
        throw "No build artifacts were discovered in $($Layout.BuildDir)."
    }

    $ArtifactRecords = @(
        foreach ($Artifact in $Artifacts) {
            Get-B32FileRecord `
                -Path $Artifact.Path `
                -Role $Artifact.Role `
                -RepoRoot $Environment.RepoRoot
        }
    )

    $SdkconfigRecord = Get-B32FileRecord `
        -Path $Layout.Sdkconfig `
        -Role "generated-sdkconfig" `
        -RepoRoot $Environment.RepoRoot

    $ArtifactRecords += $SdkconfigRecord

    $ArtifactRecords |
        Sort-Object Role, RelativePath |
        Export-Csv `
            -Path $ManifestCsvPath `
            -NoTypeInformation `
            -Encoding UTF8

    Write-B32JsonFile `
        -InputObject @(
            $ArtifactRecords |
            Sort-Object Role, RelativePath
        ) `
        -Path $ManifestJsonPath `
        -Depth 8 |
        Out-Null

    $ApplicationBinary = @(
        $ArtifactRecords |
        Where-Object Role -eq "application-bin"
    ) |
        Select-Object -First 1

    if ($null -eq $ApplicationBinary) {
        throw "The application binary was not discovered."
    }

    $Result = [ordered]@{
        work_package = "B3.2"
        operation = "controlled-build"
        status = "PASS"
        timestamp_local = (Get-Date).ToString("o")
        profile = $NormalizedProfile
        clean_build = (-not $Incremental)
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
        product = [ordered]@{
            project_name = [string]$ProjectDescription.project_name
            hardware_compatibility = $HardwareCompatibility
            build_profile = $NormalizedProfile
        }
        configuration = [ordered]@{
            common_defaults = $Defaults.Common
            profile_defaults = $Defaults.Overlay
            generated_sdkconfig = $Layout.Sdkconfig
            generated_sdkconfig_sha256 = $SdkconfigRecord.SHA256
        }
        build = [ordered]@{
            directory = $Layout.BuildDir
            duration_seconds = $BuildResult.DurationSeconds
            stdout = $BuildResult.StdoutPath
            stderr = $BuildResult.StderrPath
        }
        size_reports = [ordered]@{
            text = $SizeTextPath
            json = $SizeJsonPath
            text_command_duration_seconds = $SizeTextResult.DurationSeconds
            json_command_duration_seconds = $SizeJsonResult.DurationSeconds
        }
        application_binary = [ordered]@{
            path = $ApplicationBinary.Path
            relative_path = $ApplicationBinary.RelativePath
            size_bytes = $ApplicationBinary.SizeBytes
            sha256 = $ApplicationBinary.SHA256
        }
        manifests = [ordered]@{
            csv = $ManifestCsvPath
            json = $ManifestJsonPath
        }
    }

    Write-B32JsonFile `
        -InputObject $Result `
        -Path $ResultPath `
        -Depth 12 |
        Out-Null

    $Summary = @(
        "============================================================"
        "B3.2 CONTROLLED BUILD"
        "============================================================"
        "Status:                    PASS"
        "Timestamp:                 $((Get-Date).ToString('o'))"
        "Profile:                   $NormalizedProfile"
        "Build mode:                $(if ($Incremental) { 'incremental' } else { 'clean' })"
        "Repository:                $($Environment.RepoRoot)"
        "Branch:                    $($RepositoryState.Branch)"
        "Commit:                    $($RepositoryState.Commit)"
        "ESP-IDF:                   $($Environment.IdfVersion)"
        "Target:                    esp32s3"
        "Hardware compatibility:    $HardwareCompatibility"
        "Project:                   $([string]$ProjectDescription.project_name)"
        "Build directory:           $($Layout.BuildDir)"
        "Build duration seconds:    $($BuildResult.DurationSeconds)"
        "Application binary:        $($ApplicationBinary.Path)"
        "Application bytes:         $($ApplicationBinary.SizeBytes)"
        "Application SHA256:        $($ApplicationBinary.SHA256)"
        "Generated sdkconfig:       $($Layout.Sdkconfig)"
        "Generated config SHA256:   $($SdkconfigRecord.SHA256)"
        "Text size report:          $SizeTextPath"
        "JSON size report:          $SizeJsonPath"
        "Artifact manifest CSV:     $ManifestCsvPath"
        "Artifact manifest JSON:    $ManifestJsonPath"
        "Build result JSON:         $ResultPath"
        ""
        "B3.2 CONTROLLED BUILD PASSED"
    ) -join [Environment]::NewLine

    Write-B32TextFile `
        -Content ($Summary + [Environment]::NewLine) `
        -Path $SummaryPath |
        Out-Null

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED BUILD PASSED"
    Write-Host "============================================================"
    Write-Host "Profile:       $NormalizedProfile"
    Write-Host "Project:       $([string]$ProjectDescription.project_name)"
    Write-Host "App binary:    $($ApplicationBinary.Path)"
    Write-Host "Size:          $($ApplicationBinary.SizeBytes) bytes"
    Write-Host "SHA256:        $($ApplicationBinary.SHA256)"
    Write-Host "Summary:       $SummaryPath"
    Write-Host "Result JSON:   $ResultPath"
    Write-Host "Manifest CSV:  $ManifestCsvPath"
    Write-Host "Manifest JSON: $ManifestJsonPath"
}
catch {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED BUILD FAILED"
    Write-Host "============================================================"
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
