[CmdletBinding()]
param(
    [string]$RepoRoot = "D:\OneDrive\SQD",
    [string]$GitExe = "D:\Programs\Git\cmd\git.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$EvidenceDir = Join-Path $RepoRoot "docs\evidence\logs\B2.3"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$TranscriptPath = Join-Path $EvidenceDir "B2.3_initialization_$Timestamp.txt"
$CsvPath = Join-Path $EvidenceDir "B2.3_initialization_results_$Timestamp.csv"
$Results = [System.Collections.Generic.List[object]]::new()
$TranscriptStarted = $false

function Add-Result {
    param([string]$Check,[ValidateSet("PASS","FAIL")][string]$Result,[string]$Details)
    $Results.Add([pscustomobject]@{Timestamp=(Get-Date).ToString("s");Check=$Check;Result=$Result;Details=$Details})
    $Color = if ($Result -eq "PASS") { "Green" } else { "Red" }
    Write-Host "[$Result] $Check - $Details" -ForegroundColor $Color
}

function Test-Step {
    param([string]$Name,[scriptblock]$Action)
    try { Add-Result $Name "PASS" ([string](& $Action)) }
    catch { Add-Result $Name "FAIL" $_.Exception.Message }
}

function Write-Utf8Lf {
    param([string]$Path,[AllowEmptyString()][string]$Content)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $Text = $Content.Replace("`r`n","`n").Replace("`r","`n").TrimEnd() + "`n"
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null

try {
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
    $TranscriptStarted = $true
    Write-Host "B2.3 firmware metadata and secret-control initialization"
    Write-Host "Repository: $RepoRoot"
    Write-Host ""

    Test-Step "Feature-branch prerequisite" {
        if (-not (Test-Path (Join-Path $RepoRoot ".git"))) { throw "Git repository not found." }
        $Branch = (& $GitExe -C $RepoRoot branch --show-current).Trim()
        if ($LASTEXITCODE -ne 0) { throw "Unable to read current branch." }
        if ($Branch -eq "main") { throw "Create and switch to feat/b2.3-firmware-provenance first." }
        $Changes = & $GitExe -C $RepoRoot status --porcelain --untracked-files=no
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect tracked files." }
        if ($Changes) { throw "Tracked files are modified: $($Changes -join '; ')" }
        "Branch=$Branch; tracked tree clean"
    }

    Test-Step "Semantic version source" {
        $VersionPath = Join-Path $RepoRoot "VERSION"
        if (-not (Test-Path $VersionPath -PathType Leaf)) { throw "VERSION is missing." }
        $Version = (Get-Content $VersionPath -Raw).Trim()
        $Pattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
        if ($Version -notmatch $Pattern) { throw "Invalid SemVer: $Version" }
        $Version
    }

    Test-Step "Firmware metadata component" {
        $Root = Join-Path $RepoRoot "components\build_metadata"

        Write-Utf8Lf (Join-Path $Root "include\sqd_build_metadata.h") @'
#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    const char *product_version;
    const char *git_commit;
    const char *git_commit_short;
    bool git_dirty;
    const char *source_timestamp_utc;
    const char *build_timestamp_utc;
    const char *build_profile;
    const char *target;
    const char *idf_version;
    const char *compiler_version;
    const char *hardware_compatibility;
    uint32_t secure_version;
    const char *elf_sha256;
} sqd_build_metadata_t;
const sqd_build_metadata_t *sqd_build_metadata_get(void);
void sqd_build_metadata_log(void);
#ifdef __cplusplus
}
#endif
'@

        Write-Utf8Lf (Join-Path $Root "include\sqd_build_metadata_generated.h.in") @'
#pragma once
#define SQD_META_PRODUCT_VERSION "@SQD_PRODUCT_VERSION@"
#define SQD_META_GIT_COMMIT "@SQD_GIT_COMMIT@"
#define SQD_META_GIT_COMMIT_SHORT "@SQD_GIT_COMMIT_SHORT@"
#define SQD_META_GIT_DIRTY @SQD_GIT_DIRTY@
#define SQD_META_GIT_DIRTY_STRING "@SQD_GIT_DIRTY_STRING@"
#define SQD_META_SOURCE_TIMESTAMP_UTC "@SQD_SOURCE_TIMESTAMP_UTC@"
#define SQD_META_BUILD_TIMESTAMP_UTC "@SQD_BUILD_TIMESTAMP_UTC@"
#define SQD_META_BUILD_PROFILE "@SQD_BUILD_PROFILE@"
#define SQD_META_TARGET "@SQD_TARGET@"
#define SQD_META_HARDWARE_COMPATIBILITY "@SQD_HARDWARE_COMPATIBILITY@"
'@

        Write-Utf8Lf (Join-Path $Root "sqd_build_metadata.c") @'
#include "sqd_build_metadata.h"
#include <inttypes.h>
#include <stddef.h>
#include <stdio.h>
#include "esp_app_desc.h"
#include "esp_log.h"
#include "sqd_build_metadata_generated.h"

static const char *TAG = "sqd_metadata";

__attribute__((used, section(".rodata_custom_desc")))
const char sqd_build_metadata_blob[] =
    "SQD_META_V1"
    "|version=" SQD_META_PRODUCT_VERSION
    "|git=" SQD_META_GIT_COMMIT
    "|dirty=" SQD_META_GIT_DIRTY_STRING
    "|source_time=" SQD_META_SOURCE_TIMESTAMP_UTC
    "|build_time=" SQD_META_BUILD_TIMESTAMP_UTC
    "|profile=" SQD_META_BUILD_PROFILE
    "|target=" SQD_META_TARGET
    "|hardware=" SQD_META_HARDWARE_COMPATIBILITY
    "|compiler=" __VERSION__;

const sqd_build_metadata_t *sqd_build_metadata_get(void)
{
    static sqd_build_metadata_t metadata;
    static char elf_sha256[65];
    const esp_app_desc_t *app = esp_app_get_description();

    for (size_t i = 0; i < sizeof(app->app_elf_sha256); ++i) {
        (void)snprintf(&elf_sha256[i * 2], sizeof(elf_sha256) - (i * 2), "%02x", app->app_elf_sha256[i]);
    }

    metadata.product_version = SQD_META_PRODUCT_VERSION;
    metadata.git_commit = SQD_META_GIT_COMMIT;
    metadata.git_commit_short = SQD_META_GIT_COMMIT_SHORT;
    metadata.git_dirty = (SQD_META_GIT_DIRTY != 0);
    metadata.source_timestamp_utc = SQD_META_SOURCE_TIMESTAMP_UTC;
    metadata.build_timestamp_utc = SQD_META_BUILD_TIMESTAMP_UTC;
    metadata.build_profile = SQD_META_BUILD_PROFILE;
    metadata.target = SQD_META_TARGET;
    metadata.idf_version = app->idf_ver;
    metadata.compiler_version = __VERSION__;
    metadata.hardware_compatibility = SQD_META_HARDWARE_COMPATIBILITY;
    metadata.secure_version = app->secure_version;
    metadata.elf_sha256 = elf_sha256;
    return &metadata;
}

void sqd_build_metadata_log(void)
{
    const sqd_build_metadata_t *m = sqd_build_metadata_get();
    ESP_LOGI(TAG, "SQD_META schema=1");
    ESP_LOGI(TAG, "SQD_META product_version=%s", m->product_version);
    ESP_LOGI(TAG, "SQD_META git_commit=%s", m->git_commit);
    ESP_LOGI(TAG, "SQD_META git_commit_short=%s", m->git_commit_short);
    ESP_LOGI(TAG, "SQD_META git_dirty=%s", m->git_dirty ? "true" : "false");
    ESP_LOGI(TAG, "SQD_META source_timestamp_utc=%s", m->source_timestamp_utc);
    ESP_LOGI(TAG, "SQD_META build_timestamp_utc=%s", m->build_timestamp_utc);
    ESP_LOGI(TAG, "SQD_META build_profile=%s", m->build_profile);
    ESP_LOGI(TAG, "SQD_META target=%s", m->target);
    ESP_LOGI(TAG, "SQD_META idf_version=%s", m->idf_version);
    ESP_LOGI(TAG, "SQD_META compiler_version=%s", m->compiler_version);
    ESP_LOGI(TAG, "SQD_META hardware_compatibility=%s", m->hardware_compatibility);
    ESP_LOGI(TAG, "SQD_META secure_version=%" PRIu32, m->secure_version);
    ESP_LOGI(TAG, "SQD_META elf_sha256=%s", m->elf_sha256);
}
'@

        Write-Utf8Lf (Join-Path $Root "CMakeLists.txt") @'
idf_component_register(
    SRCS "sqd_build_metadata.c"
    INCLUDE_DIRS "include"
    PRIV_REQUIRES esp_app_format log
)

get_filename_component(SQD_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
find_package(Git REQUIRED)
file(READ "${SQD_REPO_ROOT}/VERSION" SQD_PRODUCT_VERSION)
string(STRIP "${SQD_PRODUCT_VERSION}" SQD_PRODUCT_VERSION)

execute_process(COMMAND "${GIT_EXECUTABLE}" rev-parse HEAD WORKING_DIRECTORY "${SQD_REPO_ROOT}" OUTPUT_VARIABLE SQD_GIT_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${GIT_EXECUTABLE}" rev-parse --short=12 HEAD WORKING_DIRECTORY "${SQD_REPO_ROOT}" OUTPUT_VARIABLE SQD_GIT_COMMIT_SHORT OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${GIT_EXECUTABLE}" status --porcelain --untracked-files=no WORKING_DIRECTORY "${SQD_REPO_ROOT}" OUTPUT_VARIABLE SQD_GIT_STATUS OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${GIT_EXECUTABLE}" show -s --format=%cI HEAD WORKING_DIRECTORY "${SQD_REPO_ROOT}" OUTPUT_VARIABLE SQD_SOURCE_TIMESTAMP_UTC OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)

if(SQD_GIT_STATUS STREQUAL "")
    set(SQD_GIT_DIRTY 0)
    set(SQD_GIT_DIRTY_STRING "false")
else()
    set(SQD_GIT_DIRTY 1)
    set(SQD_GIT_DIRTY_STRING "true")
endif()

string(TIMESTAMP SQD_BUILD_TIMESTAMP_UTC "%Y-%m-%dT%H:%M:%SZ" UTC)
set(SQD_BUILD_PROFILE "$ENV{SQD_BUILD_PROFILE}")
if(SQD_BUILD_PROFILE STREQUAL "")
    set(SQD_BUILD_PROFILE "baseline")
endif()
set(SQD_TARGET "${IDF_TARGET}")
if(SQD_TARGET STREQUAL "")
    set(SQD_TARGET "esp32s3")
endif()
set(SQD_HARDWARE_COMPATIBILITY "$ENV{SQD_HARDWARE_COMPATIBILITY}")
if(SQD_HARDWARE_COMPATIBILITY STREQUAL "")
    set(SQD_HARDWARE_COMPATIBILITY "heltec-wifi-lora-32-v3")
endif()

configure_file("${CMAKE_CURRENT_LIST_DIR}/include/sqd_build_metadata_generated.h.in" "${CMAKE_CURRENT_BINARY_DIR}/include/sqd_build_metadata_generated.h" @ONLY)
target_include_directories(${COMPONENT_LIB} PUBLIC "${CMAKE_CURRENT_BINARY_DIR}/include")
target_link_libraries(${COMPONENT_TARGET} "-u sqd_build_metadata_blob")
'@
        $Root
    }

    Test-Step "Metadata verification application" {
        $Root = Join-Path $RepoRoot "verification\b2_3_metadata"
        Write-Utf8Lf (Join-Path $Root "CMakeLists.txt") @'
cmake_minimum_required(VERSION 3.16)
get_filename_component(SQD_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
file(READ "${SQD_REPO_ROOT}/VERSION" SQD_PROJECT_VERSION)
string(STRIP "${SQD_PROJECT_VERSION}" SQD_PROJECT_VERSION)
set(PROJECT_VER "${SQD_PROJECT_VERSION}")
set(EXTRA_COMPONENT_DIRS "${SQD_REPO_ROOT}/components/build_metadata")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(sqd_b2_3_metadata)
'@
        Write-Utf8Lf (Join-Path $Root "main\CMakeLists.txt") @'
idf_component_register(SRCS "b2_3_metadata_main.c" INCLUDE_DIRS "." REQUIRES build_metadata)
'@
        Write-Utf8Lf (Join-Path $Root "main\b2_3_metadata_main.c") @'
#include <stdbool.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "sqd_build_metadata.h"
static const char *TAG = "b2_3_verify";
void app_main(void)
{
    sqd_build_metadata_log();
    ESP_LOGI(TAG, "B2.3_METADATA_RUNTIME_PASS");
    while (true) { vTaskDelay(pdMS_TO_TICKS(1000)); }
}
'@
        Write-Utf8Lf (Join-Path $Root "sdkconfig.defaults") @'
CONFIG_ESPTOOLPY_FLASHSIZE_8MB=y
CONFIG_LOG_DEFAULT_LEVEL_INFO=y
CONFIG_COMPILER_OPTIMIZATION_DEBUG=y
'@
        $Root
    }

    Test-Step "Gitleaks policy" {
        Write-Utf8Lf (Join-Path $RepoRoot ".gitleaks.toml") @'
title = "SQD firmware secret-detection policy"
[extend]
useDefault = true

[[rules]]
id = "sqd-private-key-material"
description = "Private-key PEM material"
regex = '''-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'''
keywords = ["PRIVATE KEY"]

[[rules]]
id = "sqd-password-assignment"
description = "Hard-coded password assignment"
regex = '''(?i)(?:password|passwd|pwd)\s*[:=]\s*["'][^"'\r\n]{8,}["']'''
keywords = ["password", "passwd", "pwd"]

'@
        Write-Utf8Lf (Join-Path $RepoRoot ".gitleaksignore") @'
# Add fingerprints only after documented false-positive review.
'@
        ".gitleaks.toml and .gitleaksignore"
    }

    Test-Step "B2.3 policy document" {
        $Path = Join-Path $RepoRoot "docs\phase-b\B2.3_Firmware_Metadata_and_Secret_Controls.md"
        Write-Utf8Lf $Path @'
---
document_id: ESP32S3-PB-B2.3
title: "Firmware Metadata and Secret Controls"
work_package: "B2.3"
status: "Draft"
version: "0.1"
owner: "Me"
created: "2026-07-17"
---

# B2.3 Firmware Metadata and Secret Controls

## Scope

B2.3 embeds firmware provenance and verifies that credentials are absent from tracked source and complete Git history. B3.3 separately owns reproducible-build enforcement, toolchain guards, configuration-drift checks and image-size budgets.

## Embedded fields

- semantic version from `VERSION`;
- full and short Git commit;
- tracked-tree dirty state;
- source and build timestamps;
- build profile and ESP-IDF target;
- ESP-IDF and compiler versions;
- hardware compatibility;
- secure version and ELF SHA-256.

## Secret controls

- Gitleaks scans complete Git history with `--log-opts=--all`;
- reports use full redaction;
- private keys, credentials, tokens, `.env` files and provisioning secrets are prohibited;
- `.gitleaksignore` entries require documented false-positive review;
- confirmed exposed credentials require revocation and history-remediation assessment.

## Acceptance

- [ ] Clean ESP32-S3 metadata build succeeds.
- [ ] Binary contains expected provenance marker and values.
- [ ] Metadata manifest records binary SHA-256.
- [ ] No forbidden sensitive path is tracked.
- [ ] Complete-history secret scan reports zero unresolved findings.
- [ ] Verifier reports zero failures.
- [ ] Passing evidence is merged through a pull request.
'@
        $Path
    }

    Test-Step "Toolkit presence" {
        $Required = @(
            "tools\scripts\B2.3_Initialize_Metadata_Secrets.ps1",
            "tools\scripts\B2.3_Install_Gitleaks.ps1",
            "tools\scripts\B2.3_Verify_Metadata_Secrets.ps1",
            "tools\scripts\B2.3_Inspect_Binary.py"
        )
        $Missing = $Required | Where-Object { -not (Test-Path (Join-Path $RepoRoot $_) -PathType Leaf) }
        if ($Missing) { throw "Extract the complete toolkit. Missing: $($Missing -join ', ')" }
        "$($Required.Count) scripts present"
    }

    Test-Step "Initialization change set" {
        $Status = & $GitExe -C $RepoRoot status --short
        if ($LASTEXITCODE -ne 0) { throw "git status failed." }
        Write-Host ""; $Status | ForEach-Object { Write-Host $_ }
        "Review and commit the B2.3 files shown above"
    }
}
finally {
    $Results | Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8
    $Pass = @($Results | Where-Object Result -eq "PASS").Count
    $Fail = @($Results | Where-Object Result -eq "FAIL").Count
    Write-Host ""
    Write-Host "B2.3 initialization summary"
    Write-Host "PASS: $Pass"
    Write-Host "FAIL: $Fail"
    Write-Host "Transcript: $TranscriptPath"
    Write-Host "CSV:        $CsvPath"
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
}
if (@($Results | Where-Object Result -eq "FAIL").Count -gt 0) { exit 1 }
Write-Host "B2.3 initialization PASSED." -ForegroundColor Green
exit 0
