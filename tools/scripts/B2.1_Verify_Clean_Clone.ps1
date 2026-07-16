[CmdletBinding()]
param(
    [string]$RepoRoot = "D:\OneDrive\SQD",
    [switch]$KeepClone
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
$TranscriptPath = Join-Path $EvidenceDir "B2.1_clean_clone_verification_$Timestamp.txt"
$CsvPath = Join-Path $EvidenceDir "B2.1_clean_clone_results_$Timestamp.csv"
$CloneRoot = Join-Path $env:TEMP "SQD_B2.1_clean_clone_$Timestamp"

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

# Check the committed source before creating evidence files in the source tree.
$HeadCommit = & $GitExe -C $RepoRoot rev-parse HEAD 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($HeadCommit)) {
    throw "No Git commit exists. Create the B2.1 baseline commit before running clean-clone verification."
}

$TrackedChanges = & $GitExe -C $RepoRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect repository status."
}
if ($TrackedChanges) {
    throw "Tracked files have uncommitted changes. Commit or revert them before clean-clone verification."
}

try {
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
    $TranscriptStarted = $true

    Write-Host "B2.1 clean-clone verification"
    Write-Host "Source: $RepoRoot"
    Write-Host "Commit: $HeadCommit"
    Write-Host "Clone:  $CloneRoot"
    Write-Host ""

    Invoke-Check -Name "Committed repository baseline" -Action {
        $Branch = & $GitExe -C $RepoRoot branch --show-current
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to determine branch."
        }

        if ($Branch -ne "main") {
            throw "Expected baseline branch 'main'; detected '$Branch'."
        }

        return "HEAD $HeadCommit on main."
    }

    Invoke-Check -Name "Clean local clone" -Action {
        if (Test-Path -LiteralPath $CloneRoot) {
            Remove-Item -LiteralPath $CloneRoot -Recurse -Force
        }

        Invoke-Native `
            -FilePath $GitExe `
            -Arguments @("clone", "--no-hardlinks", $RepoRoot, $CloneRoot)

        $CloneHead = & $GitExe -C $CloneRoot rev-parse HEAD
        if ($LASTEXITCODE -ne 0 -or $CloneHead.Trim() -ne $HeadCommit.Trim()) {
            throw "Clone HEAD does not match source HEAD."
        }

        return "Clone created at commit $($CloneHead.Trim())."
    }

    Invoke-Check -Name "Required clean-clone structure" -Action {
        $Required = @(
            "CMakeLists.txt",
            "README.md",
            ".gitignore",
            ".gitattributes",
            "sdkconfig.defaults",
            "sdkconfig.defaults.debug",
            "sdkconfig.defaults.validation",
            "sdkconfig.defaults.production",
            "main\CMakeLists.txt",
            "main\main.c",
            "components\app\README.md",
            "components\board\README.md",
            "components\platform\README.md",
            "components\services\README.md",
            "components\connectivity\README.md",
            "components\storage\README.md",
            "components\security\README.md",
            "components\update\README.md",
            "components\diagnostics\README.md",
            "partitions\README.md",
            "recovery\README.md",
            "test_apps\README.md",
            "factory\README.md",
            "tools\scripts\B2.1_Initialize_Repository.ps1",
            "tools\scripts\B2.1_Verify_Clean_Clone.ps1",
            "docs\phase-b\B2.1_Repository_Baseline.md"
        )

        $Missing = $Required | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $CloneRoot $_))
        }

        if ($Missing) {
            throw "Missing committed baseline paths: $($Missing -join ', ')"
        }

        return "$($Required.Count) required paths are present."
    }

    Invoke-Check -Name "Clean-clone ignore rules" -Action {
        foreach ($Probe in @(
            "build\probe.tmp",
            "sdkconfig",
            "managed_components\probe.txt",
            "secrets\probe.key"
        )) {
            & $GitExe -C $CloneRoot check-ignore --quiet --no-index $Probe
            if ($LASTEXITCODE -ne 0) {
                throw "Expected ignored path is not ignored: $Probe"
            }
        }

        & $GitExe -C $CloneRoot check-ignore --quiet --no-index "dependencies.lock"
        if ($LASTEXITCODE -eq 0) {
            throw "dependencies.lock is incorrectly ignored."
        }

        return "Ignore contract verified."
    }

    # Deterministic ESP-IDF environment.
    $EnvironmentDetails = Initialize-IdfProcessEnvironment
    Write-Host $EnvironmentDetails

    Invoke-Check -Name "Clean-clone ESP-IDF version" -Action {
        $Output = & $EspPython $IdfScript --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "idf.py --version failed."
        }

        $Text = ($Output | ForEach-Object { $_.ToString() }) -join " "
        if ($Text -notmatch "v6\.0\.2") {
            throw "Expected ESP-IDF v6.0.2; detected '$Text'."
        }

        return $Text
    }

    Invoke-Check -Name "Clean-clone ESP32-S3 build" -Action {
        Invoke-Native `
            -FilePath $EspPython `
            -Arguments @($IdfScript, "set-target", "esp32s3") `
            -WorkingDirectory $CloneRoot

        Invoke-Native `
            -FilePath $EspPython `
            -Arguments @($IdfScript, "build") `
            -WorkingDirectory $CloneRoot

        $BuildRoot = Join-Path $CloneRoot "build"
        $ApplicationBinary = Get-ChildItem `
            -LiteralPath $BuildRoot `
            -Filter "*.bin" `
            -File `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($null -eq $ApplicationBinary) {
            throw "No application binary was generated."
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

        $Hash = (Get-FileHash -LiteralPath $ApplicationBinary.FullName -Algorithm SHA256).Hash
        return "$($ApplicationBinary.Name)=$($ApplicationBinary.Length) bytes; SHA256=$Hash"
    }

    Invoke-Check -Name "Generated files excluded after build" -Action {
        $Status = & $GitExe -C $CloneRoot status --porcelain
        if ($LASTEXITCODE -ne 0) {
            throw "git status failed in clean clone."
        }

        if ($Status) {
            throw "Build left unignored changes: $($Status -join '; ')"
        }

        return "Working tree remains clean after set-target and build."
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
    Write-Host "B2.1 clean-clone summary"
    Write-Host "PASS: $PassCount"
    Write-Host "FAIL: $FailCount"
    Write-Host "SKIP: $SkipCount"
    Write-Host "WARN: $WarnCount"
    Write-Host "Transcript: $TranscriptPath"
    Write-Host "CSV:        $CsvPath"

    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
    }

    if ((Test-Path -LiteralPath $CloneRoot) -and (-not $KeepClone)) {
        Remove-Item -LiteralPath $CloneRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$FinalFailCount = @($script:Results | Where-Object Result -eq "FAIL").Count
if ($FinalFailCount -gt 0) {
    Write-Host "B2.1 clean-clone verification FAILED." -ForegroundColor Red
    exit 1
}

Write-Host "B2.1 clean-clone verification PASSED." -ForegroundColor Green
exit 0
