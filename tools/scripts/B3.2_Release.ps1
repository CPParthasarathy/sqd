[CmdletBinding()]
param(
    [ValidateSet("production")]
    [string]$Profile = "production",

    [string]$RepoRoot = "D:\OneDrive\SQD",

    [string]$IdfPath = "D:\esp\v6.0.2\esp-idf",

    [string]$HardwareCompatibility = "heltec-wifi-lora-32-v3",

    [string]$ReleaseLabel
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
    "B3.2_${NormalizedProfile}_release_summary_${Timestamp}.txt"

$ResultPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_release_result_${Timestamp}.json"

$EvidenceManifestCsvPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_release_manifest_${Timestamp}.csv"

$EvidenceManifestJsonPath = Join-Path `
    $EvidenceDir `
    "B3.2_${NormalizedProfile}_release_manifest_${Timestamp}.json"

try {
    Write-B32Section -Title "B3.2 CONTROLLED RELEASE: $($NormalizedProfile.ToUpperInvariant())"

    if ($NormalizedProfile -ne "production") {
        throw "Controlled release packaging is restricted to the production profile."
    }

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

    Assert-B32Directory `
        -Path $Layout.BuildDir `
        -Description "$NormalizedProfile build" |
        Out-Null

    Assert-B32GeneratedConfiguration `
        -SdkconfigPath $Layout.Sdkconfig `
        -Profile $NormalizedProfile |
        Out-Null

    $ProjectDescriptionPath = Assert-B32File `
        -Path $Layout.ProjectDescription `
        -Description "ESP-IDF project description"

    $FlasherArgsPath = Assert-B32File `
        -Path $Layout.FlasherArgs `
        -Description "ESP-IDF flash arguments"

    $ProjectDescription = Get-Content `
        -LiteralPath $ProjectDescriptionPath `
        -Raw |
        ConvertFrom-Json

    $ProjectName = [string]$ProjectDescription.project_name

    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        throw "project_description.json does not contain project_name."
    }

    $Artifacts = @(Get-B32ProjectArtifacts -BuildDir $Layout.BuildDir)

    if ($Artifacts.Count -eq 0) {
        throw "No production artifacts were found in $($Layout.BuildDir). Run B3.2_Build.ps1 -Profile production first."
    }

    $ApplicationBinary = @(
        $Artifacts |
        Where-Object Role -eq "application-bin"
    ) |
        Select-Object -First 1

    if ($null -eq $ApplicationBinary) {
        throw "Production application binary is missing from $($Layout.BuildDir)."
    }

    $SafeLabel = if ([string]::IsNullOrWhiteSpace($ReleaseLabel)) {
        $RepositoryState.CommitShort
    }
    else {
        $ReleaseLabel.Trim() -replace '[^A-Za-z0-9_.-]', '_'
    }

    if ([string]::IsNullOrWhiteSpace($SafeLabel)) {
        throw "Release label is empty after normalization."
    }

    $ReleaseRoot = New-B32Directory `
        -Path (Join-Path $Environment.RepoRoot "release\b3.2")

    $PackageName = "${ProjectName}_${NormalizedProfile}_${SafeLabel}_${Timestamp}"
    $PackageDir = Join-Path $ReleaseRoot $PackageName
    $PackageZipPath = Join-Path $ReleaseRoot "${PackageName}.zip"

    if (Test-Path -LiteralPath $PackageDir) {
        Remove-Item -LiteralPath $PackageDir -Recurse -Force
    }

    if (Test-Path -LiteralPath $PackageZipPath -PathType Leaf) {
        Remove-Item -LiteralPath $PackageZipPath -Force
    }

    New-B32Directory -Path $PackageDir | Out-Null

    $PackageFiles = New-Object System.Collections.Generic.List[object]

    function Add-B32ReleaseFile {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$SourcePath,

            [Parameter(Mandatory)]
            [string]$DestinationRelativePath,

            [Parameter(Mandatory)]
            [string]$Role
        )

        $ResolvedSource = Assert-B32File `
            -Path $SourcePath `
            -Description $Role

        $DestinationPath = Join-Path $PackageDir $DestinationRelativePath
        $DestinationParent = Split-Path -Parent $DestinationPath

        if (-not [string]::IsNullOrWhiteSpace($DestinationParent)) {
            New-B32Directory -Path $DestinationParent | Out-Null
        }

        Copy-Item `
            -LiteralPath $ResolvedSource `
            -Destination $DestinationPath `
            -Force

        $PackageFiles.Add(
            [PSCustomObject]@{
                Role = $Role
                SourcePath = $ResolvedSource
                PackagePath = $DestinationRelativePath.Replace("\", "/")
                DestinationPath = $DestinationPath
            }
        )
    }

    foreach ($Artifact in $Artifacts) {
        $FileName = Split-Path -Leaf $Artifact.Path

        $DestinationRelativePath = switch -Wildcard ($Artifact.Role) {
            "application-bin" { "firmware\$FileName"; break }
            "application-elf" { "symbols\$FileName"; break }
            "linker-map" { "symbols\$FileName"; break }
            "flash-*" { "firmware\$FileName"; break }
            default { "firmware\$FileName"; break }
        }

        Add-B32ReleaseFile `
            -SourcePath $Artifact.Path `
            -DestinationRelativePath $DestinationRelativePath `
            -Role $Artifact.Role
    }

    Add-B32ReleaseFile `
        -SourcePath $Layout.Sdkconfig `
        -DestinationRelativePath "metadata\sdkconfig.production" `
        -Role "generated-sdkconfig"

    Add-B32ReleaseFile `
        -SourcePath $ProjectDescriptionPath `
        -DestinationRelativePath "metadata\project_description.json" `
        -Role "project-description"

    Add-B32ReleaseFile `
        -SourcePath $FlasherArgsPath `
        -DestinationRelativePath "metadata\flasher_args.json" `
        -Role "flasher-arguments"

    $Defaults = Get-B32ProfileDefaults `
        -RepoRoot $Environment.RepoRoot `
        -Profile $NormalizedProfile

    Add-B32ReleaseFile `
        -SourcePath $Defaults.Common `
        -DestinationRelativePath "metadata\sdkconfig.defaults" `
        -Role "common-sdkconfig-defaults"

    Add-B32ReleaseFile `
        -SourcePath $Defaults.Overlay `
        -DestinationRelativePath "metadata\sdkconfig.defaults.production" `
        -Role "production-sdkconfig-defaults"

    $PackageRecords = @(
        foreach ($PackageFile in $PackageFiles) {
            $Record = Get-B32FileRecord `
                -Path $PackageFile.DestinationPath `
                -Role $PackageFile.Role `
                -RepoRoot $PackageDir

            [PSCustomObject]@{
                Role = $Record.Role
                PackagePath = $PackageFile.PackagePath
                SizeBytes = $Record.SizeBytes
                SHA256 = $Record.SHA256
                LastWriteTimeUtc = $Record.LastWriteTimeUtc
            }
        }
    )

    $PackageManifestCsvPath = Join-Path $PackageDir "manifest.csv"
    $PackageManifestJsonPath = Join-Path $PackageDir "manifest.json"
    $ReleaseMetadataPath = Join-Path $PackageDir "release_metadata.json"
    $ReadmePath = Join-Path $PackageDir "README.txt"

    $PackageRecords |
        Sort-Object PackagePath |
        Export-Csv `
            -LiteralPath $PackageManifestCsvPath `
            -NoTypeInformation `
            -Encoding UTF8

    Write-B32JsonFile `
        -InputObject @($PackageRecords | Sort-Object PackagePath) `
        -Path $PackageManifestJsonPath `
        -Depth 8 |
        Out-Null

    $ReleaseMetadata = [ordered]@{
        work_package = "B3.2"
        release_type = "controlled-production-package"
        package_name = $PackageName
        created_local = (Get-Date).ToString("o")
        profile = $NormalizedProfile
        project = $ProjectName
        hardware_compatibility = $HardwareCompatibility
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
        build = [ordered]@{
            directory = $Layout.BuildDir
            generated_sdkconfig = $Layout.Sdkconfig
        }
        package = [ordered]@{
            directory = $PackageDir
            archive = $PackageZipPath
            file_count = $PackageRecords.Count
        }
    }

    Write-B32JsonFile `
        -InputObject $ReleaseMetadata `
        -Path $ReleaseMetadataPath `
        -Depth 12 |
        Out-Null

    $Readme = @(
        "SQD Firmware Controlled Production Release"
        "=========================================="
        ""
        "Project:                $ProjectName"
        "Profile:                $NormalizedProfile"
        "Hardware compatibility:$HardwareCompatibility"
        "Target:                 esp32s3"
        "ESP-IDF:                $($Environment.IdfVersion)"
        "Git branch:             $($RepositoryState.Branch)"
        "Git commit:             $($RepositoryState.Commit)"
        "Package:                $PackageName"
        "Created:                $((Get-Date).ToString('o'))"
        ""
        "Contents"
        "--------"
        "firmware/   Flashable binaries."
        "symbols/    ELF and linker-map debugging artifacts."
        "metadata/   Build configuration and ESP-IDF flash metadata."
        "manifest.* SHA-256 file manifests."
        ""
        "Use only with hardware compatibility identifier:"
        "$HardwareCompatibility"
        ""
        "Verify every packaged file against manifest.csv or manifest.json"
        "before deployment."
    ) -join [Environment]::NewLine

    Write-B32TextFile `
        -Content ($Readme + [Environment]::NewLine) `
        -Path $ReadmePath |
        Out-Null

    Compress-Archive `
        -Path (Join-Path $PackageDir "*") `
        -DestinationPath $PackageZipPath `
        -CompressionLevel Optimal `
        -Force

    $ArchiveRecord = Get-B32FileRecord `
        -Path $PackageZipPath `
        -Role "release-archive" `
        -RepoRoot $Environment.RepoRoot

    $EvidenceRecords = @(
        $PackageRecords |
        Sort-Object PackagePath
    )

    $EvidenceRecords |
        Export-Csv `
            -LiteralPath $EvidenceManifestCsvPath `
            -NoTypeInformation `
            -Encoding UTF8

    Write-B32JsonFile `
        -InputObject $EvidenceRecords `
        -Path $EvidenceManifestJsonPath `
        -Depth 8 |
        Out-Null

    $Result = [ordered]@{
        work_package = "B3.2"
        operation = "controlled-production-release"
        status = "PASS"
        timestamp_local = (Get-Date).ToString("o")
        profile = $NormalizedProfile
        project = $ProjectName
        hardware_compatibility = $HardwareCompatibility
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
        release = [ordered]@{
            package_name = $PackageName
            directory = $PackageDir
            archive = $ArchiveRecord.Path
            archive_size_bytes = $ArchiveRecord.SizeBytes
            archive_sha256 = $ArchiveRecord.SHA256
            packaged_file_count = $PackageRecords.Count
            package_manifest_csv = $PackageManifestCsvPath
            package_manifest_json = $PackageManifestJsonPath
            release_metadata = $ReleaseMetadataPath
            readme = $ReadmePath
        }
        evidence = [ordered]@{
            summary = $SummaryPath
            result_json = $ResultPath
            manifest_csv = $EvidenceManifestCsvPath
            manifest_json = $EvidenceManifestJsonPath
        }
    }

    Write-B32JsonFile `
        -InputObject $Result `
        -Path $ResultPath `
        -Depth 14 |
        Out-Null

    $Summary = @(
        "============================================================"
        "B3.2 CONTROLLED PRODUCTION RELEASE"
        "============================================================"
        "Status:                    PASS"
        "Timestamp:                 $((Get-Date).ToString('o'))"
        "Project:                   $ProjectName"
        "Profile:                   $NormalizedProfile"
        "Hardware compatibility:    $HardwareCompatibility"
        "Repository:                $($Environment.RepoRoot)"
        "Branch:                    $($RepositoryState.Branch)"
        "Commit:                    $($RepositoryState.Commit)"
        "Tracked tree clean:         true"
        "ESP-IDF:                   $($Environment.IdfVersion)"
        "Target:                    esp32s3"
        "Build directory:           $($Layout.BuildDir)"
        "Package name:              $PackageName"
        "Package directory:         $PackageDir"
        "Packaged file count:       $($PackageRecords.Count)"
        "Release archive:           $($ArchiveRecord.Path)"
        "Archive bytes:             $($ArchiveRecord.SizeBytes)"
        "Archive SHA256:            $($ArchiveRecord.SHA256)"
        "Evidence manifest CSV:     $EvidenceManifestCsvPath"
        "Evidence manifest JSON:    $EvidenceManifestJsonPath"
        "Result JSON:               $ResultPath"
        ""
        "B3.2 CONTROLLED PRODUCTION RELEASE PASSED"
    ) -join [Environment]::NewLine

    Write-B32TextFile `
        -Content ($Summary + [Environment]::NewLine) `
        -Path $SummaryPath |
        Out-Null

    Write-Host "Project:       $ProjectName"
    Write-Host "Profile:       $NormalizedProfile"
    Write-Host "Branch:        $Branch"
    Write-Host "Commit:        $($RepositoryState.Commit)"
    Write-Host "ESP-IDF:       $($Environment.IdfVersion)"
    Write-Host "Hardware:      $HardwareCompatibility"
    Write-Host "Files:         $($PackageRecords.Count)"
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED PRODUCTION RELEASE PASSED"
    Write-Host "============================================================"
    Write-Host "Package dir:   $PackageDir"
    Write-Host "Archive:       $($ArchiveRecord.Path)"
    Write-Host "Archive size:  $($ArchiveRecord.SizeBytes) bytes"
    Write-Host "Archive SHA256:$($ArchiveRecord.SHA256)"
    Write-Host "Summary:       $SummaryPath"
    Write-Host "Result JSON:   $ResultPath"
    Write-Host "Manifest CSV:  $EvidenceManifestCsvPath"
    Write-Host "Manifest JSON: $EvidenceManifestJsonPath"
}
catch {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "B3.2 CONTROLLED PRODUCTION RELEASE FAILED"
    Write-Host "============================================================"
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
