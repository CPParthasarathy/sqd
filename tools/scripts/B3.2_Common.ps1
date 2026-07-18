Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# B3.2 shared tooling library.
# Dot-source this file from B3.2 entry-point scripts. This file defines functions
# only and performs no build, flash, erase, monitor, or package operation by itself.

$script:B32_DefaultRepoRoot = "D:\OneDrive\SQD"
$script:B32_DefaultIdfPath = "D:\esp\v6.0.2\esp-idf"
$script:B32_RequiredIdfVersionPattern = '^ESP-IDF v6\.0\.2(?:\b|$)'
$script:B32_Profiles = @("debug", "validation", "production")
$script:B32_DefaultHardwareCompatibility = "heltec-wifi-lora-32-v3"

function Get-B32Timestamp {
    [CmdletBinding()]
    param()

    Get-Date -Format "yyyyMMdd_HHmmss"
}

function Write-B32Section {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Title
    )

    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Title
    Write-Host "============================================================"
}

function Assert-B32Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description directory does not exist: $Path"
    }

    (Resolve-Path -LiteralPath $Path).Path
}

function Assert-B32File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description file does not exist: $Path"
    }

    (Resolve-Path -LiteralPath $Path).Path
}

function New-B32Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    (Resolve-Path -LiteralPath $Path).Path
}

function Get-B32ProfileNames {
    [CmdletBinding()]
    param()

    @($script:B32_Profiles)
}

function Assert-B32Profile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Profile
    )

    $Normalized = $Profile.Trim().ToLowerInvariant()

    if ($script:B32_Profiles -notcontains $Normalized) {
        throw "Unsupported build profile '$Profile'. Allowed profiles: $($script:B32_Profiles -join ', ')."
    }

    $Normalized
}

function Get-B32GitExecutable {
    [CmdletBinding()]
    param()

    $Preferred = "D:\Programs\Git\cmd\git.exe"

    if (Test-Path -LiteralPath $Preferred -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Preferred).Path
    }

    (Get-Command git.exe -ErrorAction Stop).Source
}

function Invoke-B32GitCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $GitExe = Get-B32GitExecutable
    $Output = @(& $GitExe -C $RepoRoot @Arguments 2>&1)
    $ExitCode = $LASTEXITCODE
    $Text = ([string]($Output -join [Environment]::NewLine)).Trim()

    if ($ExitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $ExitCode.`n$Text"
    }

    $Text
}

function Get-B32RepositoryState {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = $script:B32_DefaultRepoRoot
    )

    $ResolvedRepoRoot = Assert-B32Directory -Path $RepoRoot -Description "Repository"

    [PSCustomObject]@{
        RepoRoot = $ResolvedRepoRoot
        Branch = Invoke-B32GitCapture -RepoRoot $ResolvedRepoRoot -Arguments @("branch", "--show-current")
        Commit = Invoke-B32GitCapture -RepoRoot $ResolvedRepoRoot -Arguments @("rev-parse", "HEAD")
        CommitShort = Invoke-B32GitCapture -RepoRoot $ResolvedRepoRoot -Arguments @("rev-parse", "--short=12", "HEAD")
        StatusPorcelain = Invoke-B32GitCapture -RepoRoot $ResolvedRepoRoot -Arguments @("status", "--porcelain")
        TrackedStatusPorcelain = Invoke-B32GitCapture -RepoRoot $ResolvedRepoRoot -Arguments @(
            "status",
            "--porcelain",
            "--untracked-files=no"
        )
    }
}

function Assert-B32FeatureBranch {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = $script:B32_DefaultRepoRoot,

        [string]$ExpectedBranch = "feat/b3.2-controlled-tooling"
    )

    $Branch = Invoke-B32GitCapture -RepoRoot $RepoRoot -Arguments @("branch", "--show-current")

    if ($Branch -ne $ExpectedBranch) {
        throw "Expected Git branch '$ExpectedBranch'; current branch is '$Branch'."
    }

    $Branch
}

function Assert-B32TrackedTreeClean {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = $script:B32_DefaultRepoRoot
    )

    $TrackedChanges = Invoke-B32GitCapture `
        -RepoRoot $RepoRoot `
        -Arguments @("status", "--porcelain", "--untracked-files=no")

    if (-not [string]::IsNullOrWhiteSpace($TrackedChanges)) {
        throw "Tracked repository files contain uncommitted changes:`n$TrackedChanges"
    }

    $true
}

function Initialize-B32IdfEnvironment {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = $script:B32_DefaultRepoRoot,

        [string]$IdfPath = $script:B32_DefaultIdfPath,

        [string]$HardwareCompatibility = $script:B32_DefaultHardwareCompatibility
    )

    $ResolvedRepoRoot = Assert-B32Directory -Path $RepoRoot -Description "Repository"
    $ResolvedIdfPath = Assert-B32Directory -Path $IdfPath -Description "ESP-IDF"

    $ExportScript = Assert-B32File `
        -Path (Join-Path $ResolvedIdfPath "export.ps1") `
        -Description "ESP-IDF export script"

    $IdfPy = Assert-B32File `
        -Path (Join-Path $ResolvedIdfPath "tools\idf.py") `
        -Description "ESP-IDF frontend"

    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

    if ([string]::IsNullOrWhiteSpace($env:IDF_TOOLS_PATH)) {
        $env:IDF_TOOLS_PATH = Join-Path $env:USERPROFILE ".espressif"
    }

    # Repeatedly dot-sourcing ESP-IDF export.ps1 in the same PowerShell
    # process can duplicate PATH entries until Windows rejects the
    # environment block. Normalize PATH before deciding whether export is
    # required.
    $ProcessPath = [Environment]::GetEnvironmentVariable(
        "Path",
        [EnvironmentVariableTarget]::Process
    )

    if (-not [string]::IsNullOrWhiteSpace($ProcessPath)) {
        $SeenPathEntries = New-Object `
            "System.Collections.Generic.HashSet[string]" `
            ([System.StringComparer]::OrdinalIgnoreCase)

        $NormalizedPathEntries = @(
            foreach ($PathEntry in ($ProcessPath -split ";")) {
                $Candidate = $PathEntry.Trim()

                if (
                    -not [string]::IsNullOrWhiteSpace($Candidate) -and
                    $SeenPathEntries.Add($Candidate)
                ) {
                    $Candidate
                }
            }
        )

        $env:Path = $NormalizedPathEntries -join ";"
    }

    $ActiveIdfPathMatches = $false

    if (-not [string]::IsNullOrWhiteSpace($env:IDF_PATH)) {
        try {
            $ResolvedActiveIdfPath = (
                Resolve-Path -LiteralPath $env:IDF_PATH -ErrorAction Stop
            ).Path

            $ActiveIdfPathMatches = [string]::Equals(
                $ResolvedActiveIdfPath,
                $ResolvedIdfPath,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
        catch {
            $ActiveIdfPathMatches = $false
        }
    }

    $CurrentPythonCommand = Get-Command `
        python.exe `
        -ErrorAction SilentlyContinue

    $PythonEnvironmentRoot = Join-Path `
        $env:IDF_TOOLS_PATH `
        "python_env"

    $PythonFromIdfEnvironment = (
        $null -ne $CurrentPythonCommand -and
        -not [string]::IsNullOrWhiteSpace($CurrentPythonCommand.Source) -and
        $CurrentPythonCommand.Source.StartsWith(
            $PythonEnvironmentRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )

    $EnvironmentAlreadyActive = (
        $ActiveIdfPathMatches -and
        $PythonFromIdfEnvironment -and
        $env:ESP_IDF_VERSION -eq "6.0.2"
    )

    $env:IDF_PATH = $ResolvedIdfPath
    $env:ESP_IDF_VERSION = "6.0.2"
    $env:SQD_HARDWARE_COMPATIBILITY = $HardwareCompatibility

    if ($EnvironmentAlreadyActive) {
        Write-Host "Reusing active ESP-IDF 6.0.2 environment."
    }
    else {
        . $ExportScript | Out-Null
    }

    $PythonExe = (Get-Command python.exe -ErrorAction Stop).Source

    $PreviousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $VersionOutput = @(& $PythonExe $IdfPy --version 2>&1)
        $VersionExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousPreference
    }

    $Version = ([string]($VersionOutput -join [Environment]::NewLine)).Trim()

    if ($VersionExitCode -ne 0) {
        throw "idf.py --version failed with exit code $VersionExitCode.`n$Version"
    }

    if ($Version -notmatch $script:B32_RequiredIdfVersionPattern) {
        throw "Expected ESP-IDF v6.0.2; detected '$Version'."
    }

    Set-Location $ResolvedRepoRoot

    [PSCustomObject]@{
        RepoRoot = $ResolvedRepoRoot
        IdfPath = $ResolvedIdfPath
        IdfPy = $IdfPy
        PythonExe = $PythonExe
        IdfVersion = $Version
        HardwareCompatibility = $HardwareCompatibility
    }
}

function Get-B32ProfileDefaults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$Profile
    )

    $NormalizedProfile = Assert-B32Profile -Profile $Profile

    $CommonDefaults = Assert-B32File `
        -Path (Join-Path $RepoRoot "sdkconfig.defaults") `
        -Description "Common sdkconfig defaults"

    $ProfileDefaults = Assert-B32File `
        -Path (Join-Path $RepoRoot "sdkconfig.defaults.$NormalizedProfile") `
        -Description "$NormalizedProfile sdkconfig overlay"

    [PSCustomObject]@{
        Profile = $NormalizedProfile
        Common = $CommonDefaults
        Overlay = $ProfileDefaults
        CMakeValue = "$($CommonDefaults.Replace('\', '/'));$($ProfileDefaults.Replace('\', '/'))"
    }
}

function Get-B32BuildLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$Profile
    )

    $NormalizedProfile = Assert-B32Profile -Profile $Profile
    $BuildRoot = Join-Path $RepoRoot "build\b3.2"
    $BuildDir = Join-Path $BuildRoot $NormalizedProfile

    [PSCustomObject]@{
        Profile = $NormalizedProfile
        BuildRoot = $BuildRoot
        BuildDir = $BuildDir
        Sdkconfig = Join-Path $BuildDir "sdkconfig"
        ProjectDescription = Join-Path $BuildDir "project_description.json"
        FlasherArgs = Join-Path $BuildDir "flasher_args.json"
    }
}

function Get-B32EvidenceDirectory {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = $script:B32_DefaultRepoRoot
    )

    New-B32Directory -Path (Join-Path $RepoRoot "docs\evidence\logs\B3.2")
}

function New-B32EvidencePath {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = $script:B32_DefaultRepoRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Stem,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Extension,

        [string]$Timestamp = (Get-B32Timestamp)
    )

    $EvidenceDir = Get-B32EvidenceDirectory -RepoRoot $RepoRoot
    $CleanExtension = $Extension.TrimStart(".")
    Join-Path $EvidenceDir "${Stem}_${Timestamp}.${CleanExtension}"
}

function ConvertTo-B32CommandLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $Rendered = foreach ($Argument in $Arguments) {
        if ($null -eq $Argument) {
            "<null>"
            continue
        }

        $ArgumentText = [string]$Argument

        if ($ArgumentText -match '[\s";]') {
            '"' + ($ArgumentText.Replace('"', '\"')) + '"'
        }
        else {
            $ArgumentText
        }
    }

    $Rendered -join " "
}

function Invoke-B32CapturedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter()]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$StdoutPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$StderrPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Operation
    )

    Assert-B32File -Path $FilePath -Description "$Operation executable" | Out-Null
    Assert-B32Directory -Path $WorkingDirectory -Description "$Operation working" | Out-Null

    New-B32Directory -Path (Split-Path -Parent $StdoutPath) | Out-Null
    New-B32Directory -Path (Split-Path -Parent $StderrPath) | Out-Null

    Remove-Item -LiteralPath $StdoutPath, $StderrPath -Force -ErrorAction SilentlyContinue

    $ProcessStartUtc = [DateTime]::UtcNow

    $Process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -WorkingDirectory $WorkingDirectory `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath `
        -NoNewWindow `
        -Wait `
        -PassThru

    $ProcessEndUtc = [DateTime]::UtcNow

    if ($null -eq $Process) {
        throw "$Operation did not return a process object."
    }

    $StdoutRaw = if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) {
        Get-Content -LiteralPath $StdoutPath -Raw
    }
    else {
        $null
    }

    $StderrRaw = if (Test-Path -LiteralPath $StderrPath -PathType Leaf) {
        Get-Content -LiteralPath $StderrPath -Raw
    }
    else {
        $null
    }

    $StdoutText = if ([string]::IsNullOrEmpty($StdoutRaw)) {
        [string]::Empty
    }
    else {
        $StdoutRaw.Trim()
    }

    $StderrText = if ([string]::IsNullOrEmpty($StderrRaw)) {
        [string]::Empty
    }
    else {
        $StderrRaw.Trim()
    }

    $ArgumentText = @(
        foreach ($Argument in @($ArgumentList)) {
            if ($null -ne $Argument) {
                [string]$Argument
            }
        }
    )

    $CommandLineText = if ($ArgumentText.Count -eq 0) {
        $FilePath
    }
    else {
        $FilePath + " " + ($ArgumentText -join " ")
    }

    $DurationSeconds = [math]::Round(
        ($ProcessEndUtc - $ProcessStartUtc).TotalSeconds,
        3
    )

    $Result = [PSCustomObject]@{
        Operation = $Operation
        FilePath = $FilePath
        Arguments = $ArgumentText
        CommandLine = $CommandLineText
        WorkingDirectory = $WorkingDirectory
        ExitCode = [int]$Process.ExitCode
        DurationSeconds = $DurationSeconds
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
        Stdout = $StdoutText
        Stderr = $StderrText
    }

    if ($Result.ExitCode -ne 0) {
        throw @"
$Operation failed.

Exit code: $($Result.ExitCode)
Command:   $($Result.CommandLine)
Stdout:    $StdoutPath
Stderr:    $StderrPath
"@
    }

    $Result
}

function Invoke-B32Idf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Environment,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Operation,

        [string]$EvidenceStem = "B3.2_idf",

        [string]$Timestamp = (Get-B32Timestamp)
    )

    $EvidenceDir = Get-B32EvidenceDirectory -RepoRoot $Environment.RepoRoot
    $SafeOperation = $Operation -replace '[^A-Za-z0-9_.-]', '_'

    $StdoutPath = Join-Path `
        $EvidenceDir `
        "${EvidenceStem}_${SafeOperation}_stdout_${Timestamp}.txt"

    $StderrPath = Join-Path `
        $EvidenceDir `
        "${EvidenceStem}_${SafeOperation}_stderr_${Timestamp}.txt"

    $ProcessArguments = @($Environment.IdfPy) + @($Arguments)

    Invoke-B32CapturedProcess `
        -FilePath $Environment.PythonExe `
        -ArgumentList $ProcessArguments `
        -WorkingDirectory $Environment.RepoRoot `
        -StdoutPath $StdoutPath `
        -StderrPath $StderrPath `
        -Operation $Operation
}

function Get-B32SerialPorts {
    [CmdletBinding()]
    param()

    @(
        Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue |
        Sort-Object DeviceID |
        ForEach-Object {
            [PSCustomObject]@{
                Port = [string]$_.DeviceID
                Name = [string]$_.Name
                Description = [string]$_.Description
                PnpDeviceId = [string]$_.PNPDeviceID
            }
        }
    )
}

function Resolve-B32SerialPort {
    [CmdletBinding()]
    param(
        [string]$Port
    )

    $Ports = @(Get-B32SerialPorts)

    if (-not [string]::IsNullOrWhiteSpace($Port)) {
        $NormalizedPort = $Port.Trim().ToUpperInvariant()
        $Match = @($Ports | Where-Object { $_.Port.ToUpperInvariant() -eq $NormalizedPort })

        if ($Match.Count -eq 0) {
            $Available = if ($Ports.Count -eq 0) {
                "none"
            }
            else {
                $Ports.Port -join ", "
            }

            throw "Requested serial port '$NormalizedPort' was not detected. Available ports: $Available."
        }

        return $Match[0]
    }

    if ($Ports.Count -eq 0) {
        throw "No serial ports were detected. Connect the device or specify a valid -Port."
    }

    if ($Ports.Count -gt 1) {
        throw "Multiple serial ports were detected ($($Ports.Port -join ', ')). Specify -Port explicitly."
    }

    $Ports[0]
}

function Get-B32ProjectDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BuildDir
    )

    $Path = Assert-B32File `
        -Path (Join-Path $BuildDir "project_description.json") `
        -Description "ESP-IDF project description"

    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-B32ProjectArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BuildDir
    )

    $Description = Get-B32ProjectDescription -BuildDir $BuildDir
    $ProjectName = [string]$Description.project_name

    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        throw "project_description.json does not contain project_name."
    }

    $Artifacts = @(
        [PSCustomObject]@{
            Role = "application-bin"
            Path = Join-Path $BuildDir "$ProjectName.bin"
        }
        [PSCustomObject]@{
            Role = "application-elf"
            Path = Join-Path $BuildDir "$ProjectName.elf"
        }
        [PSCustomObject]@{
            Role = "linker-map"
            Path = Join-Path $BuildDir "$ProjectName.map"
        }
    )

    $FlasherArgsPath = Join-Path $BuildDir "flasher_args.json"

    if (Test-Path -LiteralPath $FlasherArgsPath -PathType Leaf) {
        $FlasherArgs = Get-Content -LiteralPath $FlasherArgsPath -Raw | ConvertFrom-Json

        if ($null -ne $FlasherArgs.flash_files) {
            foreach ($Property in $FlasherArgs.flash_files.PSObject.Properties) {
                $ArtifactPath = [string]$Property.Value

                if (-not [System.IO.Path]::IsPathRooted($ArtifactPath)) {
                    $ArtifactPath = Join-Path $BuildDir $ArtifactPath
                }

                $Artifacts += [PSCustomObject]@{
                    Role = "flash-$($Property.Name)"
                    Path = $ArtifactPath
                }
            }
        }
    }

    @(
        $Artifacts |
        Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf } |
        Group-Object { (Resolve-Path -LiteralPath $_.Path).Path } |
        ForEach-Object { $_.Group | Select-Object -First 1 }
    )
}

function Get-B32FileRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Role = "artifact",

        [string]$RepoRoot = $script:B32_DefaultRepoRoot
    )

    $ResolvedPath = Assert-B32File -Path $Path -Description $Role
    $Item = Get-Item -LiteralPath $ResolvedPath
    $Hash = Get-FileHash -LiteralPath $ResolvedPath -Algorithm SHA256

    $RelativePath = $ResolvedPath

    if ($ResolvedPath.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $RelativePath = $ResolvedPath.Substring($RepoRoot.Length).TrimStart("\")
    }

    [PSCustomObject]@{
        Role = $Role
        Path = $ResolvedPath
        RelativePath = $RelativePath
        SizeBytes = [int64]$Item.Length
        SHA256 = $Hash.Hash
        LastWriteTimeUtc = $Item.LastWriteTimeUtc.ToString("o")
    }
}

function Write-B32JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateRange(2, 100)]
        [int]$Depth = 10
    )

    New-B32Directory -Path (Split-Path -Parent $Path) | Out-Null
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $Json = $InputObject | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $Json + "`n", $Utf8NoBom)
    $Path
}

function Write-B32TextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Path
    )

    New-B32Directory -Path (Split-Path -Parent $Path) | Out-Null
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
    $Path
}

function Assert-B32GeneratedConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SdkconfigPath,

        [Parameter(Mandatory)]
        [string]$Profile
    )

    $NormalizedProfile = Assert-B32Profile -Profile $Profile
    $ResolvedSdkconfig = Assert-B32File -Path $SdkconfigPath -Description "Generated sdkconfig"
    $Lines = @(Get-Content -LiteralPath $ResolvedSdkconfig)

    $CommonRequired = @(
        'CONFIG_IDF_TARGET="esp32s3"'
        "CONFIG_ESPTOOLPY_FLASHSIZE_8MB=y"
        'CONFIG_ESPTOOLPY_FLASHSIZE="8MB"'
    )

    $ProfileRequired = @{
        debug = @(
            "CONFIG_COMPILER_OPTIMIZATION_DEBUG=y"
            "CONFIG_LOG_DEFAULT_LEVEL_DEBUG=y"
            "CONFIG_ESP_COREDUMP_ENABLE_TO_UART=y"
        )
        validation = @(
            "CONFIG_COMPILER_OPTIMIZATION_SIZE=y"
            "CONFIG_LOG_DEFAULT_LEVEL_INFO=y"
            "CONFIG_ESP_COREDUMP_ENABLE_TO_UART=y"
        )
        production = @(
            "CONFIG_COMPILER_OPTIMIZATION_SIZE=y"
            "CONFIG_LOG_DEFAULT_LEVEL_WARN=y"
            "CONFIG_ESP_COREDUMP_ENABLE_TO_NONE=y"
        )
    }

    $Missing = @(
        @($CommonRequired + $ProfileRequired[$NormalizedProfile]) |
        Where-Object { $Lines -notcontains $_ }
    )

    if ($Missing.Count -gt 0) {
        throw "Generated $NormalizedProfile sdkconfig is missing:`n$($Missing -join [Environment]::NewLine)"
    }

    $true
}
