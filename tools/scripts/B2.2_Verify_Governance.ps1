[CmdletBinding()]
param(
    [string]$RepoRoot = "D:\OneDrive\SQD",
    [string]$GitExe = "D:\Programs\Git\cmd\git.exe",
    [string]$GitHubOwner = "CPParthasarathy",
    [string]$GitHubRepository = "SQD"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$EvidenceDirectory = Join-Path $RepoRoot "docs\evidence\logs\B2.2"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$TranscriptPath = Join-Path $EvidenceDirectory "B2.2_governance_verification_$Timestamp.txt"
$CsvPath = Join-Path $EvidenceDirectory "B2.2_governance_results_$Timestamp.csv"
$ApiEvidencePath = Join-Path $EvidenceDirectory "B2.2_GitHub_repository_settings_$Timestamp.json"
$MergeSettingsScreenshot = Join-Path $RepoRoot "docs\evidence\screenshots\B2.2\B2.2_merge_settings.png"
$ProtectionScreenshot = Join-Path $RepoRoot "docs\evidence\screenshots\B2.2\B2.2_main_protection_ruleset.png"
$ExpectedRemote = "https://github.com/$GitHubOwner/$GitHubRepository.git"
$RepositoryApi = "https://api.github.com/repos/$GitHubOwner/$GitHubRepository"
$BranchApi = "$RepositoryApi/branches/main"

$script:Results = New-Object System.Collections.Generic.List[object]
$TranscriptStarted = $false
$Headers = @{
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent" = "SQD-B2.2-Governance-Verifier"
}

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

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Capture
    )

    if ($Capture) {
        $Output = & $GitExe -C $RepoRoot @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git $($Arguments -join ' ') failed. $($Output -join ' ')"
        }
        return (($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    }

    & $GitExe -C $RepoRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $Property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $Property) {
        return $null
    }

    return $Property.Value
}

function Write-Utf8Lf {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $Parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($Parent)) {
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    }

    $Normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText(
        $Path,
        $Normalized,
        [System.Text.UTF8Encoding]::new($false)
    )
}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

$PreExistingTrackedChanges = & $GitExe -C $RepoRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect repository status."
}
if ($PreExistingTrackedChanges) {
    throw "Tracked files have uncommitted changes before verification: $($PreExistingTrackedChanges -join '; ')"
}

try {
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
    $TranscriptStarted = $true

    Write-Host "B2.2 source-control and versioning governance verification"
    Write-Host "Repository: $RepoRoot"
    Write-Host "GitHub:     $GitHubOwner/$GitHubRepository"
    Write-Host ""

    Invoke-Check -Name "Required B2.2 files" -Action {
        $RequiredFiles = @(
            "docs\phase-b\B2.2_Source_Control_and_Versioning_Policy.md",
            "docs\phase-b\B2.2_GitHub_Configuration_Checklist.md",
            "CONTRIBUTING.md",
            ".github\pull_request_template.md",
            ".github\CODEOWNERS",
            ".github\release.yml",
            ".gitmessage",
            "VERSION",
            "CHANGELOG.md",
            "tools\scripts\B2.2_Initialize_Governance.ps1",
            "tools\scripts\B2.2_Verify_Governance.ps1"
        )

        $Missing = $RequiredFiles | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_) -PathType Leaf)
        }

        if ($Missing) {
            throw "Missing files: $($Missing -join ', ')"
        }

        return "$($RequiredFiles.Count) required governance files exist."
    }

    Invoke-Check -Name "Policy completeness" -Action {
        $Policy = Get-Content `
            -LiteralPath (Join-Path $RepoRoot "docs\phase-b\B2.2_Source_Control_and_Versioning_Policy.md") `
            -Raw

        $RequiredTerms = @(
            "Require a pull request",
            "Squash merge",
            "Conventional Commits",
            "Semantic Versioning",
            "release/vMAJOR.MINOR.PATCH",
            "hotfix/vMAJOR.MINOR.PATCH",
            "vMAJOR.MINOR.PATCH",
            "Emergency exception",
            "No generated",
            "credentials"
        )

        $MissingTerms = $RequiredTerms | Where-Object {
            $Policy -notmatch [regex]::Escape($_)
        }

        if ($MissingTerms) {
            throw "Policy is missing concepts: $($MissingTerms -join ', ')"
        }

        return "Branching, review, commit, merge, SemVer, release, hotfix and exception rules are explicit."
    }

    Invoke-Check -Name "Semantic version source" -Action {
        $Version = (Get-Content -LiteralPath (Join-Path $RepoRoot "VERSION") -Raw).Trim()
        $Pattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'

        if ($Version -notmatch $Pattern) {
            throw "Invalid Semantic Version: $Version"
        }

        return $Version
    }

    Invoke-Check -Name "Repository-local Git governance" -Action {
        $CommitTemplate = Invoke-Git -Arguments @("config", "--get", "commit.template") -Capture
        $PullRebase = Invoke-Git -Arguments @("config", "--get", "pull.rebase") -Capture
        $FetchPrune = Invoke-Git -Arguments @("config", "--get", "fetch.prune") -Capture
        $AutoCrlf = Invoke-Git -Arguments @("config", "--get", "core.autocrlf") -Capture

        if ($CommitTemplate -ne ".gitmessage") {
            throw "commit.template must be .gitmessage; detected '$CommitTemplate'."
        }
        if ($PullRebase -ne "true") {
            throw "pull.rebase must be true; detected '$PullRebase'."
        }
        if ($FetchPrune -ne "true") {
            throw "fetch.prune must be true; detected '$FetchPrune'."
        }
        if ($AutoCrlf -ne "false") {
            throw "core.autocrlf must be false; detected '$AutoCrlf'."
        }

        return "commit.template=.gitmessage; pull.rebase=true; fetch.prune=true; core.autocrlf=false"
    }

    Invoke-Check -Name "Main and origin synchronization" -Action {
        $CurrentBranch = Invoke-Git -Arguments @("branch", "--show-current") -Capture
        if ($CurrentBranch -ne "main") {
            throw "Verification must run from main; current branch is '$CurrentBranch'."
        }

        $Origin = Invoke-Git -Arguments @("remote", "get-url", "origin") -Capture
        if ($Origin.TrimEnd("/") -ne $ExpectedRemote.TrimEnd("/")) {
            throw "Expected origin '$ExpectedRemote'; detected '$Origin'."
        }

        Invoke-Git -Arguments @("fetch", "--prune", "origin")
        $LocalHead = Invoke-Git -Arguments @("rev-parse", "HEAD") -Capture
        $RemoteHead = Invoke-Git -Arguments @("rev-parse", "origin/main") -Capture

        if ($LocalHead -ne $RemoteHead) {
            throw "Local main ($LocalHead) does not match origin/main ($RemoteHead)."
        }

        return "main and origin/main: $LocalHead"
    }

    Invoke-Check -Name "Latest main commit convention" -Action {
        $Subject = Invoke-Git -Arguments @("log", "-1", "--format=%s") -Capture
        $Pattern = '^(feat|fix|docs|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: .+[^.]$'

        if ($Subject -notmatch $Pattern) {
            throw "Latest main commit is not Conventional Commits compliant: '$Subject'"
        }

        return $Subject
    }

    Invoke-Check -Name "Release-tag convention" -Action {
        $TagLines = & $GitExe -C $RepoRoot for-each-ref `
            "--format=%(refname:short)|%(objecttype)" `
            refs/tags

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to enumerate Git tags."
        }

        $TagPattern = '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:alpha|beta|rc)\.(0|[1-9]\d*))?$'

        foreach ($Line in $TagLines) {
            $Parts = $Line -split '\|', 2
            $TagName = $Parts[0]
            $ObjectType = $Parts[1]

            if ($TagName -notmatch $TagPattern) {
                throw "Invalid release tag name: $TagName"
            }
            if ($ObjectType -ne "tag") {
                throw "Release tag must be annotated: $TagName"
            }
        }

        if ($TagLines) {
            return "$($TagLines.Count) existing release tag(s) comply."
        }

        return "No release tags exist yet; naming and annotation policy is ready."
    }

    Invoke-Check -Name "Generated and sensitive paths untracked" -Action {
        $Tracked = & $GitExe -C $RepoRoot ls-files
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-files failed."
        }

        $ForbiddenPatterns = @(
            '(^|/)build/',
            '(^|/)sdkconfig$',
            '(^|/)sdkconfig\.old$',
            '(^|/)managed_components/',
            '(^|/)secrets/',
            '(^|/)credentials/',
            '(^|/)private_keys/',
            '(^|/)\.env(?:\.|$)',
            '\.(?:key|p12|pfx|jks|keystore)$'
        )

        $Forbidden = $Tracked | Where-Object {
            $TrackedPath = $_
            $ForbiddenPatterns | Where-Object { $TrackedPath -match $_ }
        }

        if ($Forbidden) {
            throw "Forbidden tracked paths: $($Forbidden -join ', ')"
        }

        return "Generated outputs and sensitive-material patterns are absent from tracked files."
    }

    Invoke-Check -Name "GitHub repository merge settings" -Action {
        $Repository = Invoke-RestMethod -Uri $RepositoryApi -Headers $Headers -Method Get

        $DefaultBranch = Get-OptionalProperty -InputObject $Repository -Name "default_branch"
        $AllowSquashMerge = Get-OptionalProperty -InputObject $Repository -Name "allow_squash_merge"
        $AllowMergeCommit = Get-OptionalProperty -InputObject $Repository -Name "allow_merge_commit"
        $AllowRebaseMerge = Get-OptionalProperty -InputObject $Repository -Name "allow_rebase_merge"
        $DeleteBranchOnMerge = Get-OptionalProperty -InputObject $Repository -Name "delete_branch_on_merge"

        $SettingsEvidence = [ordered]@{
            repository = Get-OptionalProperty -InputObject $Repository -Name "full_name"
            checked_at_utc = (Get-Date).ToUniversalTime().ToString("o")
            default_branch = $DefaultBranch
            allow_squash_merge = $AllowSquashMerge
            allow_merge_commit = $AllowMergeCommit
            allow_rebase_merge = $AllowRebaseMerge
            delete_branch_on_merge = $DeleteBranchOnMerge
            merge_settings_screenshot = $MergeSettingsScreenshot
        }

        Write-Utf8Lf -Path $ApiEvidencePath -Content ($SettingsEvidence | ConvertTo-Json -Depth 5)

        if ($DefaultBranch -ne "main") {
            throw "GitHub default branch must be main; detected '$DefaultBranch'."
        }

        $MergeFields = @(
            $AllowSquashMerge,
            $AllowMergeCommit,
            $AllowRebaseMerge,
            $DeleteBranchOnMerge
        )

        $MissingMergeField = @($MergeFields | Where-Object { $null -eq $_ }).Count -gt 0

        if ($MissingMergeField) {
            if (-not (Test-Path -LiteralPath $MergeSettingsScreenshot -PathType Leaf)) {
                throw "GitHub API omitted one or more merge-setting fields. Add manual evidence: $MergeSettingsScreenshot"
            }

            return "GitHub API omitted administrator merge fields; default branch is main and manual settings evidence exists: $MergeSettingsScreenshot"
        }

        if (-not [bool]$AllowSquashMerge) {
            throw "GitHub squash merging is disabled."
        }

        if ([bool]$AllowMergeCommit) {
            throw "GitHub merge commits remain enabled."
        }

        if ([bool]$AllowRebaseMerge) {
            throw "GitHub rebase merging remains enabled."
        }

        if (-not [bool]$DeleteBranchOnMerge) {
            throw "GitHub automatic branch deletion is disabled."
        }

        return "main default; squash only; head branches deleted automatically."
    }

    Invoke-Check -Name "GitHub main protection" -Action {
        $Branch = Invoke-RestMethod -Uri $BranchApi -Headers $Headers -Method Get
        $Protected = Get-OptionalProperty -InputObject $Branch -Name "protected"

        if ($null -eq $Protected) {
            throw "GitHub branch response omitted protection state."
        }

        if (-not [bool]$Protected) {
            throw "GitHub reports main as unprotected. Activate the B2.2 main-protection rule and save evidence to $ProtectionScreenshot"
        }

        if (-not (Test-Path -LiteralPath $ProtectionScreenshot -PathType Leaf)) {
            throw "GitHub reports main as protected, but required configuration evidence is missing: $ProtectionScreenshot"
        }

        return "GitHub reports main as protected; ruleset evidence exists: $ProtectionScreenshot"
    }

    Invoke-Check -Name "Pull-request bootstrap evidence" -Action {
        $PolicyCommit = & $GitExe -C $RepoRoot log `
            "--format=%H|%s" `
            --all `
            -- `
            "docs/phase-b/B2.2_Source_Control_and_Versioning_Policy.md"

        if ($LASTEXITCODE -ne 0 -or -not $PolicyCommit) {
            throw "No committed history was found for the B2.2 policy."
        }

        $LatestPolicyCommit = $PolicyCommit | Select-Object -First 1
        if ($LatestPolicyCommit -notmatch '\|docs\(governance\): define B2\.2 source-control policy$') {
            throw "Expected squash commit subject 'docs(governance): define B2.2 source-control policy'. Detected '$LatestPolicyCommit'."
        }

        return $LatestPolicyCommit
    }
}
finally {
    $script:Results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8

    $PassCount = @($script:Results | Where-Object Result -eq "PASS").Count
    $FailCount = @($script:Results | Where-Object Result -eq "FAIL").Count
    $SkipCount = @($script:Results | Where-Object Result -eq "SKIP").Count
    $WarnCount = @($script:Results | Where-Object Result -eq "WARN").Count

    Write-Host ""
    Write-Host "B2.2 governance verification summary"
    Write-Host "PASS: $PassCount"
    Write-Host "FAIL: $FailCount"
    Write-Host "SKIP: $SkipCount"
    Write-Host "WARN: $WarnCount"
    Write-Host "Transcript: $TranscriptPath"
    Write-Host "CSV:        $CsvPath"
    Write-Host "GitHub API: $ApiEvidencePath"

    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
    }
}

$FinalFailCount = @($script:Results | Where-Object Result -eq "FAIL").Count
if ($FinalFailCount -gt 0) {
    Write-Host "B2.2 governance verification FAILED." -ForegroundColor Red
    exit 1
}

Write-Host "B2.2 governance verification PASSED." -ForegroundColor Green
exit 0
