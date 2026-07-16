[CmdletBinding()]
param(
    [string]$RepoRoot = "D:\OneDrive\SQD",
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$IdfPath = "D:\esp\v6.0.2\esp-idf"
$IdfToolsPath = Join-Path $env:USERPROFILE ".espressif"
$PythonEnvPath = Join-Path $IdfToolsPath "python_env\idf6.0_py3.11_env"
$EspPython = Join-Path $PythonEnvPath "Scripts\python.exe"
$IdfScript = Join-Path $IdfPath "tools\idf.py"
$GitExe = "D:\Programs\Git\cmd\git.exe"
$RequiredIdfVersion = "6.0.2"

$EvidenceDir = Join-Path $RepoRoot "docs\evidence\logs\B2.1"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$TranscriptPath = Join-Path $EvidenceDir "B2.1_repository_initialization_$Timestamp.txt"
$CsvPath = Join-Path $EvidenceDir "B2.1_repository_initialization_$Timestamp.csv"
$TreePath = Join-Path $EvidenceDir "B2.1_repository_tree_$Timestamp.txt"

$script:Results = New-Object System.Collections.Generic.List[object]
$TranscriptStarted = $false

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][ValidateSet("PASS","FAIL","SKIP","WARN")][string]$Result,
        [Parameter(Mandatory)][string]$Details
    )

    $script:Results.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString("s")
        Check = $Check
        Result = $Result
        Details = $Details
    })

    $Color = switch ($Result) {
        "PASS" { "Green" }
        "FAIL" { "Red" }
        "SKIP" { "Yellow" }
        "WARN" { "Yellow" }
    }

    Write-Host "[$Result] $Check - $Details" -ForegroundColor $Color
}

function Invoke-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    try {
        $Details = & $Action
        if ($null -eq $Details) {
            $Details = "Completed successfully."
        }
        Add-Result -Check $Name -Result "PASS" -Details ([string]$Details)
    }
    catch {
        Add-Result -Check $Name -Result "FAIL" -Details $_.Exception.Message
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $Parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($Parent)) {
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    }

    [System.IO.File]::WriteAllText(
        $Path,
        ($Content.TrimEnd() + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Write-FileIfMissing {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return $false
    }

    Write-Utf8NoBom -Path $Path -Content $Content
    return $true
}

function Set-ControlledBlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BlockName,
        [Parameter(Mandatory)][string]$Content
    )

    $Begin = "# BEGIN $BlockName"
    $End = "# END $BlockName"
    $Block = "$Begin`n$($Content.Trim())`n$End"

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $Existing = Get-Content -LiteralPath $Path -Raw
    }
    else {
        $Existing = ""
    }

    $Pattern = "(?ms)^\Q$Begin\E.*?^\Q$End\E\s*"
    $EscapedBegin = [regex]::Escape($Begin)
    $EscapedEnd = [regex]::Escape($End)
    $Pattern = "(?ms)^$EscapedBegin.*?^$EscapedEnd\s*"

    if ($Existing -match $Pattern) {
        $Updated = [regex]::Replace($Existing, $Pattern, "$Block`n")
    }
    else {
        $Separator = if ([string]::IsNullOrWhiteSpace($Existing)) { "" } else { "`n" }
        $Updated = $Existing.TrimEnd() + $Separator + $Block + "`n"
    }

    Write-Utf8NoBom -Path $Path -Content $Updated
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Executable not found: $FilePath"
    }

    $OldLocation = Get-Location
    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Set-Location -LiteralPath $WorkingDirectory
        }

        & $FilePath @Arguments
        $ExitCode = $LASTEXITCODE

        if ($ExitCode -ne 0) {
            throw "$FilePath exited with code $ExitCode."
        }
    }
    finally {
        Set-Location $OldLocation
    }
}

function Resolve-IdfManagedTool {
    param(
        [Parameter(Mandatory)][string]$ToolDirectory,
        [Parameter(Mandatory)][string]$ExecutableName
    )

    $ToolRoot = Join-Path $IdfToolsPath "tools\$ToolDirectory"

    if (-not (Test-Path -LiteralPath $ToolRoot -PathType Container)) {
        throw "ESP-IDF managed-tool directory not found: $ToolRoot"
    }

    $Executable = Get-ChildItem `
        -LiteralPath $ToolRoot `
        -Filter "$ExecutableName.exe" `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $Executable) {
        throw "$ExecutableName.exe was not found under $ToolRoot"
    }

    return $Executable.FullName
}

function Initialize-IdfProcessEnvironment {
    $env:IDF_PATH = $IdfPath
    $env:IDF_TOOLS_PATH = $IdfToolsPath
    $env:IDF_PYTHON_ENV_PATH = $PythonEnvPath
    $env:ESP_IDF_VERSION = $RequiredIdfVersion

    $CMakeExe = Resolve-IdfManagedTool `
        -ToolDirectory "cmake" `
        -ExecutableName "cmake"

    $NinjaExe = Resolve-IdfManagedTool `
        -ToolDirectory "ninja" `
        -ExecutableName "ninja"

    $XtensaGccExe = Resolve-IdfManagedTool `
        -ToolDirectory "xtensa-esp-elf" `
        -ExecutableName "xtensa-esp32s3-elf-gcc"

    $XtensaGdbExe = Resolve-IdfManagedTool `
        -ToolDirectory "xtensa-esp-elf-gdb" `
        -ExecutableName "xtensa-esp32s3-elf-gdb"

    $RiscvGdbExe = Resolve-IdfManagedTool `
        -ToolDirectory "riscv32-esp-elf-gdb" `
        -ExecutableName "riscv32-esp-elf-gdb"

    $OpenOcdExe = Resolve-IdfManagedTool `
        -ToolDirectory "openocd-esp32" `
        -ExecutableName "openocd"

    $RequiredToolPaths = @(
        (Split-Path -Parent $EspPython),
        (Join-Path $IdfPath "tools"),
        (Split-Path -Parent $GitExe),
        (Split-Path -Parent $CMakeExe),
        (Split-Path -Parent $NinjaExe),
        (Split-Path -Parent $XtensaGccExe),
        (Split-Path -Parent $XtensaGdbExe),
        (Split-Path -Parent $RiscvGdbExe),
        (Split-Path -Parent $OpenOcdExe)
    )

    foreach ($OptionalTool in @(
        @{ Directory = "ccache"; Executable = "ccache" },
        @{ Directory = "esp32ulp-elf"; Executable = "esp32ulp-elf-as" },
        @{ Directory = "riscv32-esp-elf"; Executable = "riscv32-esp-elf-gcc" },
        @{ Directory = "dfu-util"; Executable = "dfu-util" }
    )) {
        try {
            $OptionalExe = Resolve-IdfManagedTool `
                -ToolDirectory $OptionalTool.Directory `
                -ExecutableName $OptionalTool.Executable

            $RequiredToolPaths += Split-Path -Parent $OptionalExe
        }
        catch {
            # Optional for the current ESP32-S3 baseline.
        }
    }

    $ExistingPaths = $env:Path -split ";"

    $env:Path = (($RequiredToolPaths + $ExistingPaths) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique) -join ";"

    $EspRomElfRoot = Join-Path $IdfToolsPath "tools\esp-rom-elfs"

    $EspRomElfDirectory = Get-ChildItem `
        -LiteralPath $EspRomElfRoot `
        -Directory `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -ne $EspRomElfDirectory) {
        $env:ESP_ROM_ELF_DIR = $EspRomElfDirectory.FullName
    }

    foreach ($RequiredCommand in @(
        "cmake.exe",
        "ninja.exe",
        "xtensa-esp32s3-elf-gcc.exe"
    )) {
        if ($null -eq (Get-Command $RequiredCommand -ErrorAction SilentlyContinue)) {
            throw "Required ESP-IDF command is not available after environment initialization: $RequiredCommand"
        }
    }

    return "ESP-IDF process environment initialized with CMake, Ninja and ESP32-S3 toolchain."
}



New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null

try {
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
    $TranscriptStarted = $true

    Write-Host "B2.1 production repository initialization"
    Write-Host "Repository root: $RepoRoot"
    Write-Host "ESP-IDF:         $IdfPath"
    Write-Host ""

    Invoke-Check -Name "Prerequisite paths" -Action {
        foreach ($RequiredPath in @($RepoRoot, $IdfPath, $EspPython, $IdfScript, $GitExe)) {
            if (-not (Test-Path -LiteralPath $RequiredPath)) {
                throw "Required path not found: $RequiredPath"
            }
        }
        return "B1 workstation and repository root are available."
    }

    Invoke-Check -Name "Repository directories" -Action {
        $Directories = @(
            ".github\workflows",
            "main",
            "components\app",
            "components\board",
            "components\platform",
            "components\services",
            "components\connectivity",
            "components\storage",
            "components\security",
            "components\update",
            "components\diagnostics",
            "partitions",
            "recovery",
            "test_apps",
            "factory",
            "tools\scripts",
            "docs\phase-b",
            "docs\evidence\logs\B2.1",
            "docs\evidence\screenshots\B2.1",
            "docs\evidence\measurements\B2.1"
        )

        foreach ($RelativePath in $Directories) {
            New-Item `
                -ItemType Directory `
                -Path (Join-Path $RepoRoot $RelativePath) `
                -Force | Out-Null
        }

        return "$($Directories.Count) controlled directories exist."
    }

    Invoke-Check -Name "Top-level ESP-IDF project files" -Action {
        $RootCMake = @'
cmake_minimum_required(VERSION 3.22)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(sqd_firmware)
'@

        $MainCMake = @'
idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
)
'@

        $DefaultMain = @'
#include "esp_log.h"
#include "esp_system.h"

static const char *TAG = "sqd_firmware";

void app_main(void)
{
    ESP_LOGI(TAG, "Production repository baseline booted.");
    ESP_LOGI(TAG, "ESP-IDF: %s", esp_get_idf_version());
}
'@

        [void](Write-FileIfMissing `
            -Path (Join-Path $RepoRoot "CMakeLists.txt") `
            -Content $RootCMake)

        [void](Write-FileIfMissing `
            -Path (Join-Path $RepoRoot "main\CMakeLists.txt") `
            -Content $MainCMake)

        $MainSource = Join-Path $RepoRoot "main\main.c"
        $MinimalSource = Join-Path $RepoRoot "verification\b1_2_minimal\main\main.c"

        if (-not (Test-Path -LiteralPath $MainSource -PathType Leaf)) {
            if (Test-Path -LiteralPath $MinimalSource -PathType Leaf) {
                Copy-Item -LiteralPath $MinimalSource -Destination $MainSource
            }
            else {
                Write-Utf8NoBom -Path $MainSource -Content $DefaultMain
            }
        }

        foreach ($Profile in @(
            "sdkconfig.defaults",
            "sdkconfig.defaults.debug",
            "sdkconfig.defaults.validation",
            "sdkconfig.defaults.production"
        )) {
            $ProfilePath = Join-Path $RepoRoot $Profile
            [void](Write-FileIfMissing `
                -Path $ProfilePath `
                -Content "# Configuration baseline intentionally reserved for B3.1.")
        }

        return "CMake, main component and configuration-profile placeholders exist."
    }

    Invoke-Check -Name "Component responsibility baseline" -Action {
        $Components = [ordered]@{
            "app" = "Application orchestration and top-level state coordination."
            "board" = "Heltec WiFi LoRa 32 V3 board mapping and board-specific controls."
            "platform" = "ESP32-S3 platform abstraction, lifecycle and common hardware services."
            "services" = "Reusable product-level services and background workers."
            "connectivity" = "Wi-Fi, BLE, LoRaWAN and network session management."
            "storage" = "NVS, filesystem, persistent state and recovery-safe storage."
            "security" = "Credentials, cryptographic policy, identity and secure-state services."
            "update" = "OTA, rollback, image validation and recovery coordination."
            "diagnostics" = "Logging, metrics, health monitoring, fault capture and service diagnostics."
        }

        foreach ($Name in $Components.Keys) {
            $ReadmePath = Join-Path $RepoRoot "components\$Name\README.md"
            $Content = @"
# $Name component

Purpose: $($Components[$Name])

This directory is reserved by B2.1. Add `CMakeLists.txt`, source files and public headers when implementation begins.
"@
            [void](Write-FileIfMissing -Path $ReadmePath -Content $Content)
        }

        return "$($Components.Count) component boundaries documented."
    }

    Invoke-Check -Name "Supporting-area baseline" -Action {
        $Areas = [ordered]@{
            "partitions\README.md" = "Partition-table sources and partition-layout documentation."
            "recovery\README.md" = "Recovery application and recovery workflow sources."
            "test_apps\README.md" = "Target-side test applications and isolated hardware verification projects."
            "factory\README.md" = "Manufacturing, provisioning and factory-test assets."
            ".github\workflows\README.md" = "Continuous-integration workflows. Pipeline implementation is owned by B4."
        }

        foreach ($RelativePath in $Areas.Keys) {
            $Title = [System.IO.Path]::GetFileName(
                [System.IO.Path]::GetDirectoryName($RelativePath)
            )

            if ([string]::IsNullOrWhiteSpace($Title)) {
                $Title = $RelativePath
            }

            $Content = "# $Title`n`n$($Areas[$RelativePath])"
            [void](Write-FileIfMissing `
                -Path (Join-Path $RepoRoot $RelativePath) `
                -Content $Content)
        }

        return "$($Areas.Count) supporting areas documented."
    }

    Invoke-Check -Name "Repository ignore baseline" -Action {
        $GitIgnoreBlock = @'
# ESP-IDF generated build and configuration
/build/
/build-*/
/**/build/
/**/build-*/
sdkconfig
sdkconfig.old
**/sdkconfig
**/sdkconfig.old

# IDF Component Manager download area
managed_components/
**/managed_components/

# Python and test caches
.pytest_cache/
**/.pytest_cache/
__pycache__/
**/__pycache__/
*.py[cod]
pytest_embedded_log/

# IDE-generated state; controlled VS Code JSON files remain trackable
.vscode/.browse.c_cpp.db*
.vscode/ipch/
.idea/
.vs/

# Generated release/package output
/dist/
/release/
/artifacts/

# Local credentials and private material
.env
.env.*
/secrets/
/credentials/
/private_keys/
*.key
*.p12
*.pfx
*.jks
*.keystore

# OS and temporary files
Thumbs.db
.DS_Store
~$*
*.tmp
'@

        Set-ControlledBlock `
            -Path (Join-Path $RepoRoot ".gitignore") `
            -BlockName "B2.1 ESP-IDF REPOSITORY BASELINE" `
            -Content $GitIgnoreBlock

        $AttributesBlock = @'
* text=auto
*.c text eol=lf
*.h text eol=lf
*.cpp text eol=lf
*.hpp text eol=lf
*.cmake text eol=lf
CMakeLists.txt text eol=lf
*.md text eol=lf
*.py text eol=lf
*.yml text eol=lf
*.yaml text eol=lf
*.json text eol=lf
*.ps1 text eol=crlf
*.cmd text eol=crlf
*.bat text eol=crlf
*.bin binary
*.elf binary
*.png binary
*.jpg binary
*.jpeg binary
*.pdf binary
*.xlsx binary
'@

        Set-ControlledBlock `
            -Path (Join-Path $RepoRoot ".gitattributes") `
            -BlockName "B2.1 LINE ENDINGS AND BINARY TYPES" `
            -Content $AttributesBlock

        return ".gitignore and .gitattributes baselines installed."
    }

    Invoke-Check -Name "Repository documentation baseline" -Action {
        $ReadmePath = Join-Path $RepoRoot "README.md"
        $Readme = @'
# ESP32-S3 Production Firmware

Production firmware repository for the Heltec WiFi LoRa 32 V3 / ESP32-S3 platform.

## Toolchain baseline

- ESP-IDF 6.0.2
- Windows PowerShell
- Visual Studio Code with Espressif ESP-IDF extension
- Target: esp32s3

## Build

Run from an ESP-IDF-enabled environment:

```powershell
idf.py set-target esp32s3
idf.py build
```

Generated `build/`, `sdkconfig` and managed component downloads are excluded from Git. Configuration baselines are owned by the `sdkconfig.defaults*` files and will be completed under B3.1.

## Repository areas

- `main/`: application entry point.
- `components/`: reusable production firmware components.
- `partitions/`: partition-table definitions.
- `recovery/`: recovery firmware.
- `test_apps/`: target-side verification applications.
- `factory/`: manufacturing and provisioning assets.
- `tools/`: controlled development and release tooling.
- `docs/`: controlled engineering records and evidence.
- `.github/workflows/`: CI workflow definitions.
'@

        [void](Write-FileIfMissing -Path $ReadmePath -Content $Readme)

        $BaselinePath = Join-Path $RepoRoot "docs\phase-b\B2.1_Repository_Baseline.md"
        $Baseline = @'
---
document_id: ESP32S3-PB-B2.1
title: "Production Repository and Directory Baseline"
phase: "B"
cluster: "B2"
work_package: "B2.1"
status: "Draft"
version: "0.1"
owner: "Me"
approver: "Me"
classification: "Internal Engineering"
created: "2026-07-16"
baseline_gate: "B2.1 acceptance"
platform: "Heltec WiFi LoRa 32 V3 / ESP32-S3"
toolchain: "ESP-IDF 6.0.2"
---

# B2.1 Production Repository and Directory Baseline

## Objective

Create the production ESP-IDF repository structure, source-control exclusions and modular component boundaries.

## Controlled root

`D:\OneDrive\SQD`

## Required acceptance evidence

- Repository initialized with default branch `main`.
- Required directories and baseline files exist.
- `build/`, generated `sdkconfig` and `managed_components/` are ignored.
- `dependencies.lock` remains eligible for source control.
- The production root builds for `esp32s3`.
- After the baseline commit, a clean local clone builds successfully.
- A build leaves the clean-clone working tree free of untracked generated files.

## Acceptance status

- [ ] Repository structure initialized.
- [ ] Ignore rules verified.
- [ ] Initial B2.1 baseline commit created.
- [ ] Clean-clone build passes.
- [ ] Verification returns zero failures.
'@

        [void](Write-FileIfMissing -Path $BaselinePath -Content $Baseline)

        return "README and B2.1 controlled baseline document exist."
    }

    Invoke-Check -Name "Git repository initialization" -Action {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ".git") -PathType Container)) {
            Invoke-Native `
                -FilePath $GitExe `
                -Arguments @("init", "-b", "main", $RepoRoot)
        }

        $Inside = & $GitExe -C $RepoRoot rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0 -or $Inside.Trim() -ne "true") {
            throw "Git repository initialization was not confirmed."
        }

        $Branch = & $GitExe -C $RepoRoot symbolic-ref --short HEAD 2>$null
        if ($LASTEXITCODE -ne 0) {
            $Branch = "main"
        }

        return "Git repository initialized; branch baseline: $Branch"
    }

    Invoke-Check -Name "Ignore-rule verification" -Action {
        $IgnoredProbes = @(
            "build\B2.1_probe.tmp",
            "sdkconfig",
            "managed_components\B2.1_probe.txt",
            "secrets\B2.1_probe.key"
        )

        foreach ($Probe in $IgnoredProbes) {
            & $GitExe -C $RepoRoot check-ignore --quiet --no-index $Probe
            if ($LASTEXITCODE -ne 0) {
                throw "Expected ignored path is not ignored: $Probe"
            }
        }

        & $GitExe -C $RepoRoot check-ignore --quiet --no-index "dependencies.lock"
        if ($LASTEXITCODE -eq 0) {
            throw "dependencies.lock must remain trackable for reproducible firmware builds."
        }

        return "Generated outputs and private-material paths are ignored; dependencies.lock is trackable."
    }

    # Set deterministic process-local ESP-IDF environment.
    $EnvironmentDetails = Initialize-IdfProcessEnvironment
    Write-Host $EnvironmentDetails

    if ($SkipBuild) {
        Add-Result `
            -Check "Production-root ESP32-S3 build" `
            -Result "SKIP" `
            -Details "Build explicitly skipped. B2.1 acceptance remains open."
    }
    else {
        Invoke-Check -Name "Production-root ESP32-S3 build" -Action {
            $SdkconfigPath = Join-Path $RepoRoot "sdkconfig"
            $TargetConfigured = $false

            if (Test-Path -LiteralPath $SdkconfigPath -PathType Leaf) {
                $TargetConfigured = (Get-Content -LiteralPath $SdkconfigPath -Raw) -match 'CONFIG_IDF_TARGET="esp32s3"'
            }

            if (-not $TargetConfigured) {
                Invoke-Native `
                    -FilePath $EspPython `
                    -Arguments @($IdfScript, "set-target", "esp32s3") `
                    -WorkingDirectory $RepoRoot
            }

            Invoke-Native `
                -FilePath $EspPython `
                -Arguments @($IdfScript, "build") `
                -WorkingDirectory $RepoRoot

            $BuildRoot = Join-Path $RepoRoot "build"
            $ApplicationBinary = Get-ChildItem `
                -LiteralPath $BuildRoot `
                -Filter "*.bin" `
                -File `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($null -eq $ApplicationBinary) {
                throw "No top-level application binary was generated."
            }

            foreach ($RequiredOutput in @(
                (Join-Path $BuildRoot "bootloader\bootloader.bin"),
                (Join-Path $BuildRoot "partition_table\partition-table.bin"),
                (Join-Path $BuildRoot "compile_commands.json")
            )) {
                if (-not (Test-Path -LiteralPath $RequiredOutput -PathType Leaf)) {
                    throw "Required build output missing: $RequiredOutput"
                }
            }

            return "$($ApplicationBinary.Name)=$($ApplicationBinary.Length) bytes"
        }
    }

    Invoke-Check -Name "Repository tree evidence" -Action {
        $ExcludedNames = @(".git", "build", "managed_components", "__pycache__")

        $Lines = Get-ChildItem `
            -LiteralPath $RepoRoot `
            -Force `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $Relative = $_.FullName.Substring($RepoRoot.Length).TrimStart("\")
                -not ($ExcludedNames | Where-Object {
                    $Relative -eq $_ -or $Relative.StartsWith($_ + "\")
                })
            } |
            ForEach-Object {
                $Relative = $_.FullName.Substring($RepoRoot.Length).TrimStart("\")
                if ($_.PSIsContainer) {
                    "[DIR]  $Relative"
                }
                else {
                    "[FILE] $Relative"
                }
            } |
            Sort-Object

        Write-Utf8NoBom -Path $TreePath -Content ($Lines -join "`n")
        return "Repository tree captured: $TreePath"
    }

    Invoke-Check -Name "Git status capture" -Action {
        $Status = & $GitExe -C $RepoRoot status --short
        if ($LASTEXITCODE -ne 0) {
            throw "git status failed."
        }

        $StatusText = if ($Status) {
            $Status -join [Environment]::NewLine
        }
        else {
            "Working tree clean."
        }

        Write-Host ""
        Write-Host "Git status:"
        Write-Host $StatusText

        return "Git status captured. Review and create the B2.1 baseline commit."
    }
}
finally {
    $script:Results |
        Export-Csv `
            -LiteralPath $CsvPath `
            -NoTypeInformation `
            -Encoding UTF8

    $PassCount = @($script:Results | Where-Object Result -eq "PASS").Count
    $FailCount = @($script:Results | Where-Object Result -eq "FAIL").Count
    $SkipCount = @($script:Results | Where-Object Result -eq "SKIP").Count
    $WarnCount = @($script:Results | Where-Object Result -eq "WARN").Count

    Write-Host ""
    Write-Host "B2.1 initialization summary"
    Write-Host "PASS: $PassCount"
    Write-Host "FAIL: $FailCount"
    Write-Host "SKIP: $SkipCount"
    Write-Host "WARN: $WarnCount"
    Write-Host "Transcript: $TranscriptPath"
    Write-Host "CSV:        $CsvPath"
    Write-Host "Tree:       $TreePath"

    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
    }
}

$FinalFailCount = @($script:Results | Where-Object Result -eq "FAIL").Count
if ($FinalFailCount -gt 0) {
    Write-Host "B2.1 repository initialization FAILED." -ForegroundColor Red
    exit 1
}

Write-Host "B2.1 repository initialization PASSED." -ForegroundColor Green
Write-Host "Next: review git status, commit the baseline, then run B2.1_Verify_Clean_Clone.ps1."
exit 0
