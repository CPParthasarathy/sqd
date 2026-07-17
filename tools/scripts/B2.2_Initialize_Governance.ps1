[CmdletBinding()]
param(
    [string]$RepoRoot = "D:\OneDrive\SQD",
    [string]$GitExe = "D:\Programs\Git\cmd\git.exe",
    [string]$GitHubOwner = "CPParthasarathy",
    [string]$GitHubRepository = "SQD",
    [string]$WorkBranch = "docs/b2.2-governance"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$EvidenceDirectory = Join-Path $RepoRoot "docs\evidence\logs\B2.2"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$TranscriptPath = Join-Path $EvidenceDirectory "B2.2_governance_initialization_$Timestamp.txt"
$CsvPath = Join-Path $EvidenceDirectory "B2.2_governance_initialization_$Timestamp.csv"
$ExpectedRemote = "https://github.com/$GitHubOwner/$GitHubRepository.git"

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

function Write-FileIfMissing {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return $false
    }

    Write-Utf8Lf -Path $Path -Content $Content
    return $true
}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

try {
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
    $TranscriptStarted = $true

    Write-Host "B2.2 source-control and versioning governance initialization"
    Write-Host "Repository:  $RepoRoot"
    Write-Host "Remote:      $ExpectedRemote"
    Write-Host "Work branch: $WorkBranch"
    Write-Host ""

    Invoke-Check -Name "B2.1 repository prerequisite" -Action {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ".git") -PathType Container)) {
            throw "Git repository not found: $RepoRoot"
        }

        $Inside = Invoke-Git -Arguments @("rev-parse", "--is-inside-work-tree") -Capture
        if ($Inside -ne "true") {
            throw "Repository work tree was not confirmed."
        }

        return "Repository HEAD: $(Invoke-Git -Arguments @('rev-parse','HEAD') -Capture)"
    }

    Invoke-Check -Name "Tracked working tree clean" -Action {
        $TrackedChanges = & $GitExe -C $RepoRoot status --porcelain --untracked-files=no
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect tracked working-tree changes."
        }

        if ($TrackedChanges) {
            throw "Tracked files have uncommitted changes: $($TrackedChanges -join '; ')"
        }

        return "No tracked modifications are present before B2.2."
    }

    Invoke-Check -Name "GitHub origin" -Action {
        $Origin = Invoke-Git -Arguments @("remote", "get-url", "origin") -Capture
        if ($Origin.TrimEnd("/") -ne $ExpectedRemote.TrimEnd("/")) {
            Invoke-Git -Arguments @("remote", "set-url", "origin", $ExpectedRemote)
            $Origin = Invoke-Git -Arguments @("remote", "get-url", "origin") -Capture
        }

        if ($Origin.TrimEnd("/") -ne $ExpectedRemote.TrimEnd("/")) {
            throw "Expected origin '$ExpectedRemote'; detected '$Origin'."
        }

        return $Origin
    }

    Invoke-Check -Name "B2.2 work branch" -Action {
        $CurrentBranch = Invoke-Git -Arguments @("branch", "--show-current") -Capture

        if ($CurrentBranch -ne $WorkBranch) {
            $ExistingBranch = & $GitExe -C $RepoRoot branch --list $WorkBranch
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to inspect local branches."
            }

            if ($ExistingBranch) {
                Invoke-Git -Arguments @("switch", $WorkBranch)
            }
            else {
                Invoke-Git -Arguments @("switch", "-c", $WorkBranch)
            }
        }

        $Selected = Invoke-Git -Arguments @("branch", "--show-current") -Capture
        if ($Selected -ne $WorkBranch) {
            throw "Expected branch '$WorkBranch'; detected '$Selected'."
        }

        return $Selected
    }

    Invoke-Check -Name "Source-control policy" -Action {
        $PolicyPath = Join-Path $RepoRoot "docs\phase-b\B2.2_Source_Control_and_Versioning_Policy.md"

        $Policy = @'
---
document_id: ESP32S3-PB-B2.2
title: "Source-Control and Versioning Policy"
phase: "B"
cluster: "B2"
work_package: "B2.2"
status: "Draft"
version: "0.1"
owner: "Me"
approver: "Me"
classification: "Internal Engineering"
created: "2026-07-17"
repository: "https://github.com/CPParthasarathy/SQD"
---

# B2.2 Source-Control and Versioning Policy

## 1. Purpose

This policy defines the controlled Git and GitHub workflow for the SQD ESP32-S3 production firmware repository. It covers branch ownership, pull-request review, commit messages, merge behavior, releases, hotfixes, semantic versions, tags and emergency exceptions.

## 2. Authoritative repository

- Repository: `https://github.com/CPParthasarathy/SQD`
- Default branch: `main`
- `main` is the only long-lived integration branch.
- `main` must remain buildable and suitable for engineering release preparation.
- Direct pushes, force pushes and deletion of `main` are prohibited after B2.2 activation.

## 3. Branching model

Use short-lived branches created from current `main`.

| Change class | Branch pattern | Example |
|---|---|---|
| Feature | `feat/<wbs-or-issue>-<slug>` | `feat/c2.1-board-pin-map` |
| Defect | `fix/<wbs-or-issue>-<slug>` | `fix/142-reset-loop` |
| Documentation | `docs/<wbs-or-issue>-<slug>` | `docs/b2.2-governance` |
| Refactoring | `refactor/<wbs-or-issue>-<slug>` | `refactor/c1.2-error-contracts` |
| Build/tooling | `build/<wbs-or-issue>-<slug>` | `build/b3.2-bootstrap` |
| CI | `ci/<wbs-or-issue>-<slug>` | `ci/b4.1-profile-builds` |
| Release preparation | `release/vMAJOR.MINOR.PATCH` | `release/v0.2.0` |
| Emergency correction | `hotfix/vMAJOR.MINOR.PATCH` | `hotfix/v0.1.1` |

Rules:

1. A normal branch starts from updated `main`.
2. A branch contains one coherent change set.
3. A branch is deleted after merge.
4. Long-running integration branches are prohibited.
5. `release/*` branches are temporary stabilization branches; new features are prohibited.
6. `hotfix/*` branches start from the affected release tag or controlled deployed baseline.

## 4. Pull-request and review policy

All changes to `main` use pull requests after B2.2 activation.

For the current single-owner repository:

- GitHub must require a pull request before merge.
- Required approving reviews are set to zero because an author cannot provide an independent approval for their own pull request.
- The owner performs and records a self-review using the pull-request checklist.
- All review conversations must be resolved.
- The pull-request description identifies the WBS item or issue, risk, verification performed and evidence location.
- A draft pull request cannot merge.
- Once another qualified maintainer is available, at least one independent approval becomes mandatory.

Required evidence before merge:

- Relevant clean build or test result.
- No generated files or credentials in the diff.
- Documentation updated where behavior, interfaces or operating procedures change.
- Traceability to a WBS item, issue or defect record.

## 5. Merge policy

- Squash merge is the only enabled GitHub merge method.
- Merge commits and rebase merges are disabled.
- The pull-request title becomes the final `main` commit subject and follows Conventional Commits.
- The resulting `main` history is linear.
- Head branches are automatically deleted after merge.
- Required status checks will be activated under B4.1 after stable CI check names exist.

## 6. Commit-message convention

Use Conventional Commits 1.0.0:

```text
<type>[optional scope][!]: <imperative description>

[optional body]

[optional footer(s)]
```

Allowed types:

- `feat`: backward-compatible product capability.
- `fix`: defect correction.
- `docs`: documentation-only change.
- `refactor`: internal restructuring without behavior change.
- `perf`: performance improvement.
- `test`: tests or test infrastructure.
- `build`: build system, dependencies or packaging.
- `ci`: continuous-integration configuration.
- `chore`: controlled maintenance not covered above.
- `revert`: reversion of an earlier commit.

Examples:

```text
feat(board): add Heltec V3 peripheral power control
fix(storage): recover interrupted settings transaction
docs(governance): define B2.2 source-control policy
build(toolchain): enforce ESP-IDF 6.0.2
feat(api)!: replace legacy provisioning command schema
```

Breaking changes use `!` and a `BREAKING CHANGE:` footer. Subjects use lowercase type names, imperative mood, no trailing period and a target maximum of 72 characters.

## 7. Semantic-version policy

The firmware uses Semantic Versioning 2.0.0:

```text
MAJOR.MINOR.PATCH
```

- Increment `MAJOR` for incompatible changes to a released firmware interface, protocol, persistent-data contract, update contract or supported-hardware contract.
- Increment `MINOR` for backward-compatible functionality.
- Increment `PATCH` for backward-compatible corrections.
- Version `0.y.z` denotes initial development.
- Version `1.0.0` declares the first stable public compatibility baseline.
- Pre-release versions use `-alpha.N`, `-beta.N` or `-rc.N`.
- Build metadata may use `+<metadata>` in diagnostic output but is not part of the release tag.
- The repository `VERSION` file is the human-controlled version source. B2.3 will embed version and source metadata into the firmware image.

Initial development version:

```text
0.1.0-dev.0
```

## 8. Release-tag policy

Release tags use:

```text
vMAJOR.MINOR.PATCH
vMAJOR.MINOR.PATCH-rc.N
```

Rules:

1. Stable tags point to a commit on `main`.
2. Tags are annotated; lightweight release tags are prohibited.
3. Every tag has an associated GitHub Release and release notes.
4. Released tag contents are immutable.
5. Deleting, moving or reusing a published release tag is prohibited.
6. Release evidence includes the commit, version, artifacts, tests, hardware compatibility and known limitations.
7. Signing release tags becomes mandatory when the project signing identity is provisioned.

## 9. Hotfix policy

1. Confirm the affected deployed version.
2. Create `hotfix/vX.Y.Z` from the affected tag or controlled deployed baseline.
3. Apply only the minimum corrective change.
4. Execute regression and release verification.
5. Merge through a pull request.
6. Increment `PATCH`, publish a new immutable tag and GitHub Release.
7. Backport explicitly when another maintained release line requires the correction.

A published release is never modified in place.

## 10. Emergency exception

A direct administrative change to `main` is permitted only when GitHub protection itself prevents restoration and no pull-request path is operational. The exception requires an incident identifier, exact commit, reason, post-change verification, retrospective review and restoration of protection. Convenience or schedule pressure is not an emergency.

## 11. Secret and generated-file controls

- No generated `build/`, generated `sdkconfig` or `managed_components/` content is committed.
- `dependencies.lock` remains tracked when generated.
- No private keys, credentials, tokens, `.env` files or provisioning secrets are committed.
- Suspected credential exposure requires immediate revocation and history-remediation assessment.

B2.3 owns automated metadata and secret-scan evidence.

## 12. B2.2 acceptance criteria

- [ ] Policy files and templates are committed.
- [ ] Git commit template is configured.
- [ ] GitHub default branch is `main`.
- [ ] Only squash merging is enabled.
- [ ] Head branches are deleted automatically.
- [ ] `main` is protected and requires pull requests.
- [ ] The B2.2 policy is merged through a pull request.
- [ ] The verifier reports zero failures.
- [ ] Passing evidence is committed through a follow-up pull request.

## 13. Normative references

- Semantic Versioning 2.0.0.
- Conventional Commits 1.0.0.
- GitHub protected branches and repository rulesets.
- GitHub pull-request and release documentation.
'@

        Write-Utf8Lf -Path $PolicyPath -Content $Policy
        return $PolicyPath
    }

    Invoke-Check -Name "Contributor workflow" -Action {
        $Contributing = @'
# Contributing to SQD Firmware

1. Update local `main`.
2. Create a short-lived branch using the B2.2 naming policy.
3. Make one coherent change.
4. Build and test the affected scope.
5. Use Conventional Commit messages.
6. Push the branch and open a pull request.
7. Complete the self-review checklist.
8. Squash merge only after all acceptance conditions pass.
9. Delete the merged branch.

```powershell
git switch main
git pull --ff-only origin main
git switch -c feat/<wbs-or-issue>-<short-description>
```

Commit format:

```text
<type>[optional scope][!]: <imperative description>
```

Before opening a pull request, verify the intended build, relevant tests, absence of generated files and secrets, documentation, traceability and version impact.

The authoritative rules are in `docs/phase-b/B2.2_Source_Control_and_Versioning_Policy.md`.
'@
        Write-Utf8Lf -Path (Join-Path $RepoRoot "CONTRIBUTING.md") -Content $Contributing
        return "CONTRIBUTING.md"
    }

    Invoke-Check -Name "Pull-request template" -Action {
        $Template = @'
## Change summary

Describe the change and why it is required.

## Traceability

- WBS / issue / defect:
- Related requirement identifiers:
- Target hardware and revision:

## Change classification

- [ ] Feature
- [ ] Defect correction
- [ ] Refactoring
- [ ] Build or CI
- [ ] Documentation
- [ ] Release or hotfix
- [ ] Breaking change

## Verification

- [ ] Relevant ESP-IDF build completed
- [ ] Relevant tests completed
- [ ] Hardware verification completed or not applicable
- [ ] Generated files are absent from the diff
- [ ] Credentials, keys and tokens are absent from the diff
- [ ] Documentation and traceability are updated
- [ ] Pull-request title follows Conventional Commits
- [ ] Version impact was assessed
- [ ] All review conversations are resolved

Commands, results and evidence paths:

```text
Add verification commands and evidence locations.
```

## Risk and rollback

Risk introduced:

Rollback or recovery method:

## Release impact

- Current version:
- Required bump: none / patch / minor / major
- Hardware compatibility impact:
- Persistent-data compatibility impact:
- OTA or rollback impact:

## Self-review record

- Reviewer: repository owner
- Review date:
- Files and interfaces reviewed:
- Residual concerns:
'@
        $Path = Join-Path $RepoRoot ".github\pull_request_template.md"
        Write-Utf8Lf -Path $Path -Content $Template
        return $Path
    }

    Invoke-Check -Name "Ownership and commit template" -Action {
        $CodeOwners = @'
* @CPParthasarathy
/.github/ @CPParthasarathy
/tools/ @CPParthasarathy
/partitions/ @CPParthasarathy
/recovery/ @CPParthasarathy
/components/security/ @CPParthasarathy
/components/update/ @CPParthasarathy
/factory/ @CPParthasarathy
'@

        $CommitTemplate = @'
# <type>[optional scope][!]: <imperative description>
#
# Allowed types:
# feat, fix, docs, refactor, perf, test, build, ci, chore, revert
#
# WBS: Bx.y
# Refs: #issue
# Verification: command or evidence path
#
# BREAKING CHANGE: describe incompatible behavior or contract changes
'@

        Write-Utf8Lf -Path (Join-Path $RepoRoot ".github\CODEOWNERS") -Content $CodeOwners
        Write-Utf8Lf -Path (Join-Path $RepoRoot ".gitmessage") -Content $CommitTemplate

        Invoke-Git -Arguments @("config", "commit.template", ".gitmessage")
        Invoke-Git -Arguments @("config", "pull.rebase", "true")
        Invoke-Git -Arguments @("config", "fetch.prune", "true")
        Invoke-Git -Arguments @("config", "branch.autosetuprebase", "always")
        Invoke-Git -Arguments @("config", "core.autocrlf", "false")

        return "CODEOWNERS and repository-local Git governance settings installed."
    }

    Invoke-Check -Name "Version and changelog baseline" -Action {
        [void](Write-FileIfMissing -Path (Join-Path $RepoRoot "VERSION") -Content "0.1.0-dev.0")

        $Changelog = @'
# Changelog

All notable changes to SQD firmware will be documented in this file.

The project follows Semantic Versioning.

## [Unreleased]

### Added

- Production repository and engineering-governance baseline.

### Changed

### Fixed

### Security
'@
        [void](Write-FileIfMissing -Path (Join-Path $RepoRoot "CHANGELOG.md") -Content $Changelog)

        $Version = (Get-Content -LiteralPath (Join-Path $RepoRoot "VERSION") -Raw).Trim()
        $Pattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
        if ($Version -notmatch $Pattern) {
            throw "VERSION is not valid SemVer: $Version"
        }

        return "VERSION=$Version"
    }

    Invoke-Check -Name "GitHub configuration checklist" -Action {
        $Checklist = @'
# B2.2 GitHub Configuration Checklist

Repository: `CPParthasarathy/SQD`

## Repository merge settings

Open **Settings → General → Pull Requests**.

- [ ] Allow squash merging: enabled.
- [ ] Allow merge commits: disabled.
- [ ] Allow rebase merging: disabled.
- [ ] Automatically delete head branches: enabled.

## Main protection

Open **Settings → Rules → Rulesets** and create a branch ruleset.

- Name: `main-protection`
- Enforcement: `Active`
- Target: default branch or branch `main`

Enable:

- [ ] Restrict deletions.
- [ ] Block force pushes.
- [ ] Require a pull request before merging.
- [ ] Required approvals: `0` while only one qualified maintainer exists.
- [ ] Require conversation resolution.
- [ ] Require linear history.

Do not require status checks yet. B4.1 will add stable check names.

## Evidence and workflow

- [ ] Capture the active ruleset page.
- [ ] Capture repository merge settings.
- [ ] Save screenshots under `docs/evidence/screenshots/B2.2/`.
- [ ] Push `docs/b2.2-governance`.
- [ ] Open a pull request titled `docs(governance): define B2.2 source-control policy`.
- [ ] Complete self-review.
- [ ] Squash merge.
- [ ] Run `B2.2_Verify_Governance.ps1` from updated `main`.
'@

        Write-Utf8Lf -Path (Join-Path $RepoRoot "docs\phase-b\B2.2_GitHub_Configuration_Checklist.md") -Content $Checklist

        $ScreenshotReadme = @'
# B2.2 screenshot evidence

Expected files:

- `B2.2_main_protection_ruleset.png`
- `B2.2_merge_settings.png`

Do not capture authentication tokens, recovery codes or private account information.
'@
        Write-Utf8Lf -Path (Join-Path $RepoRoot "docs\evidence\screenshots\B2.2\README.md") -Content $ScreenshotReadme
        return "GitHub configuration and evidence checklist created."
    }

    Invoke-Check -Name "Release-notes configuration" -Action {
        $ReleaseConfig = @'
changelog:
  exclude:
    labels:
      - skip-changelog
  categories:
    - title: Breaking changes
      labels:
        - breaking
    - title: Features
      labels:
        - feature
        - enhancement
    - title: Fixes
      labels:
        - bug
        - fix
    - title: Security
      labels:
        - security
    - title: Documentation
      labels:
        - documentation
    - title: Maintenance
      labels:
        - build
        - ci
        - maintenance
    - title: Other changes
      labels:
        - "*"
'@
        Write-Utf8Lf -Path (Join-Path $RepoRoot ".github\release.yml") -Content $ReleaseConfig
        return ".github/release.yml"
    }

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
            throw "Missing B2.2 files: $($Missing -join ', ')"
        }

        $ConfiguredTemplate = Invoke-Git -Arguments @("config", "--get", "commit.template") -Capture
        if ($ConfiguredTemplate -ne ".gitmessage") {
            throw "Expected commit.template=.gitmessage; detected '$ConfiguredTemplate'."
        }

        return "$($RequiredFiles.Count) required B2.2 files verified."
    }

    Invoke-Check -Name "Git status capture" -Action {
        $Status = & $GitExe -C $RepoRoot status --short
        if ($LASTEXITCODE -ne 0) {
            throw "git status failed."
        }

        Write-Host ""
        Write-Host "B2.2 changes:"
        if ($Status) {
            $Status | ForEach-Object { Write-Host $_ }
        }
        else {
            Write-Host "No working-tree changes."
        }

        return "Review, stage and commit the displayed B2.2 change set."
    }
}
finally {
    $script:Results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8

    $PassCount = @($script:Results | Where-Object Result -eq "PASS").Count
    $FailCount = @($script:Results | Where-Object Result -eq "FAIL").Count
    $SkipCount = @($script:Results | Where-Object Result -eq "SKIP").Count
    $WarnCount = @($script:Results | Where-Object Result -eq "WARN").Count

    Write-Host ""
    Write-Host "B2.2 initialization summary"
    Write-Host "PASS: $PassCount"
    Write-Host "FAIL: $FailCount"
    Write-Host "SKIP: $SkipCount"
    Write-Host "WARN: $WarnCount"
    Write-Host "Transcript: $TranscriptPath"
    Write-Host "CSV:        $CsvPath"

    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
    }
}

$FinalFailCount = @($script:Results | Where-Object Result -eq "FAIL").Count
if ($FinalFailCount -gt 0) {
    Write-Host "B2.2 governance initialization FAILED." -ForegroundColor Red
    exit 1
}

Write-Host "B2.2 governance initialization PASSED." -ForegroundColor Green
Write-Host "Next: commit and push $WorkBranch, configure GitHub, and merge by pull request."
exit 0
