<#
.SYNOPSIS
    Deploys a ruleset to Azure API Center analyzerConfig via the importRuleset action.

.DESCRIPTION
    This script packages the ruleset directory (ruleset.yaml + any functions/) into a zip,
    base64-encodes it, and imports it into the specified API Center analyzer configuration
    using the Azure REST API.

    If the ruleset directory contains a config.yaml with an apiType field
    (rest, graphql, or mcp), the script reads the analyzerType from that config.
    Otherwise it defaults to "spectral".

.PARAMETER SubscriptionId
    Azure subscription ID containing the API Center service.

.PARAMETER ResourceGroup
    Resource group name containing the API Center service.

.PARAMETER ServiceName
    Name of the Azure API Center service.

.PARAMETER AnalyzerConfigName
    Name of the analyzer configuration (e.g., "custom-ruleset").

.PARAMETER RulesetPath
    Path to the directory containing ruleset.yaml (and optionally a functions/ folder).

.PARAMETER ApiType
    Optional API type filter. When supplied the script validates that the
    ruleset's config.yaml declares a matching apiType. Accepted values:
    rest, graphql, mcp.

.PARAMETER ApiVersion
    ARM API version. Defaults to 2024-06-01-preview.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$ServiceName,

    [Parameter(Mandatory = $true)]
    [string]$AnalyzerConfigName,

    [Parameter(Mandatory = $true)]
    [string]$RulesetPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet("rest", "graphql", "mcp")]
    [string]$ApiType,

    [Parameter(Mandatory = $false)]
    [string]$ApiVersion = "2024-06-01-preview"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Validate inputs ──────────────────────────────────────────────────────────

if (-not (Test-Path $RulesetPath)) {
    throw "Ruleset path not found: $RulesetPath"
}

$rulesetDir = Resolve-Path $RulesetPath
$rulesetFile = Join-Path $rulesetDir "ruleset.yaml"
if (-not (Test-Path $rulesetFile)) {
    # Also check for .yml extension
    $rulesetFile = Join-Path $rulesetDir "ruleset.yml"
    if (-not (Test-Path $rulesetFile)) {
        throw "No ruleset.yaml or ruleset.yml found in $rulesetDir"
    }
}

# ── Read config.yaml for API type & analyzer type ────────────────────────────

$configFile = Join-Path $rulesetDir "config.yaml"
$configApiType = $null
$analyzerType = "spectral"   # default

if (Test-Path $configFile) {
    Write-Host "Reading ruleset config from: $configFile"
    $configLines = Get-Content $configFile -Raw

    # Parse apiType (simple YAML key: value)
    if ($configLines -match '(?m)^apiType:\s*(\S+)') {
        $configApiType = $Matches[1].Trim()
        Write-Host "  Detected API type : $configApiType"
    }

    # Parse analyzerType
    if ($configLines -match '(?m)^analyzerType:\s*(\S+)') {
        $analyzerType = $Matches[1].Trim()
        Write-Host "  Analyzer type     : $analyzerType"
    }

    # Parse analyzerConfigName (overrides the -AnalyzerConfigName parameter)
    if ($configLines -match '(?m)^analyzerConfigName:\s*(\S+)') {
        $overrideName = $Matches[1].Trim()
        if ($overrideName -ne $AnalyzerConfigName) {
            Write-Host "  Config name override: $AnalyzerConfigName -> $overrideName"
            $AnalyzerConfigName = $overrideName
        }
    }
} else {
    Write-Host "No config.yaml found in $rulesetDir – defaulting to analyzerType='spectral'."
}

# Validate API type filter if provided
if ($ApiType) {
    if (-not $configApiType) {
        throw "ApiType filter '$ApiType' was specified but the ruleset at $rulesetDir has no config.yaml with an apiType field."
    }
    if ($configApiType -ne $ApiType) {
        Write-Host "Skipping '$AnalyzerConfigName' – apiType '$configApiType' does not match filter '$ApiType'." -ForegroundColor Yellow
        return
    }
}

Write-Host "Deploying ruleset for API type: $( if ($configApiType) { $configApiType } else { '(unspecified – REST assumed)' } )"
Write-Host "  Analyzer type: $analyzerType"

# ── Build zip package ────────────────────────────────────────────────────────

$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "$AnalyzerConfigName-ruleset.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# Collect items to zip: ruleset file + functions folder if it exists
$itemsToZip = @($rulesetFile)
$functionsDir = Join-Path $rulesetDir "functions"
if (Test-Path $functionsDir) {
    $itemsToZip += $functionsDir
}

Write-Host "Packaging ruleset from: $rulesetDir"
Write-Host "  Items: $($itemsToZip | ForEach-Object { Split-Path $_ -Leaf })"
Compress-Archive -Path $itemsToZip -DestinationPath $zipPath -Force

$zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
$base64 = [System.Convert]::ToBase64String($zipBytes)
Write-Host "  Zip size: $($zipBytes.Length) bytes | Base64 length: $($base64.Length)"

# ── Build and send import request ────────────────────────────────────────────

$baseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ServiceName"

# ── Ensure analyzerConfig exists (create if not found) ───────────────────────

$configUrl = "$baseUrl/workspaces/default/analyzerConfigs/$AnalyzerConfigName`?api-version=$ApiVersion"

Write-Host "Ensuring analyzer config '$AnalyzerConfigName' exists..."
$checkResult = az rest --method GET --url $configUrl -o json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Analyzer config not found. Creating '$AnalyzerConfigName'..."
    # Azure API Center only accepts 'Spectral' as analyzerType (PascalCase enum)
    $configBody = @{ properties = @{ analyzerType = "Spectral" } } | ConvertTo-Json -Compress
    $createResult = az rest --method PUT --url $configUrl --body $configBody --headers "Content-Type=application/json" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create analyzer config: $createResult"
        throw "Could not create analyzerConfig '$AnalyzerConfigName'"
    }
    Write-Host "Analyzer config '$AnalyzerConfigName' created."
    # Wait for the new config to propagate before importing
    Write-Host "Waiting 10s for config propagation..."
    Start-Sleep -Seconds 10
} else {
    Write-Host "Analyzer config '$AnalyzerConfigName' already exists."
}

# ── Import ruleset ───────────────────────────────────────────────────────────

$importUrl = "$baseUrl/workspaces/default/analyzerConfigs/$AnalyzerConfigName/importRuleset?api-version=$ApiVersion"

$bodyObj = @{ format = "inline-zip"; value = $base64 }
$json = $bodyObj | ConvertTo-Json -Compress

$bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) "$AnalyzerConfigName-import-body.json"
[System.IO.File]::WriteAllText($bodyFile, $json, [System.Text.Encoding]::UTF8)

# Import with retry – the first attempt after config creation may fail due to propagation delay
$maxRetries = 3
$retryDelay = 10
$importSuccess = $false

for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    Write-Host "Importing ruleset into analyzer config '$AnalyzerConfigName' (attempt $attempt/$maxRetries)..."
    $importResult = az rest --method POST --url $importUrl --body "@$bodyFile" --headers "Content-Type=application/json" 2>&1

    if ($LASTEXITCODE -eq 0) {
        $importSuccess = $true
        Write-Host "Import completed successfully."
        break
    }

    if ($attempt -lt $maxRetries) {
        Write-Warning "Import attempt $attempt failed: $importResult"
        Write-Host "Retrying in ${retryDelay}s..."
        Start-Sleep -Seconds $retryDelay
    } else {
        Write-Error "Import failed after $maxRetries attempts: $importResult"
        throw "Azure CLI command failed with exit code $LASTEXITCODE"
    }
}

# ── Verify deployment ────────────────────────────────────────────────────────

Write-Host "Verifying deployment (waiting 5s for propagation)..."
Start-Sleep -Seconds 5

$exportUrl = "$baseUrl/workspaces/default/analyzerConfigs/$AnalyzerConfigName/exportRuleset?api-version=$ApiVersion"
$exportResult = az rest --method POST --url $exportUrl --headers "Content-Type=application/json" -o json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Verification export failed (this may be normal for newly created configs): $exportResult"
    # Reset LASTEXITCODE so it doesn't propagate as a failure
    $global:LASTEXITCODE = 0
} else {
    $export = $exportResult | ConvertFrom-Json
    Write-Host "Verification: Exported format = $($export.format), value length = $($export.value.Length)"

    # Decode and show the first lines of the exported ruleset
    try {
        $exportedZipBytes = [System.Convert]::FromBase64String($export.value)
        $exportedZipPath = Join-Path ([System.IO.Path]::GetTempPath()) "$AnalyzerConfigName-export-verify.zip"
        [System.IO.File]::WriteAllBytes($exportedZipPath, $exportedZipBytes)
        $expandDir = Join-Path ([System.IO.Path]::GetTempPath()) "$AnalyzerConfigName-export-verify"
        if (Test-Path $expandDir) { Remove-Item $expandDir -Recurse -Force }
        Expand-Archive -Path $exportedZipPath -DestinationPath $expandDir -Force

        $exportedRuleset = Get-ChildItem -Path $expandDir -Filter "ruleset.*" -Recurse | Select-Object -First 1
        if ($exportedRuleset) {
            $exportedContent = Get-Content $exportedRuleset.FullName -Raw
            Write-Host "`n--- Exported ruleset preview (first 10 lines) ---"
            ($exportedContent -split "`n" | Select-Object -First 10) | ForEach-Object { Write-Host "  $_" }
            Write-Host "--- end preview ---`n"

            # Compare with source
            $sourceContent = Get-Content $rulesetFile -Raw
            if ($exportedContent.Trim() -eq $sourceContent.Trim()) {
                Write-Host "Deployment verified: exported content matches source." -ForegroundColor Green
            } else {
                Write-Warning "Exported content does NOT match source ruleset! Import may not have applied correctly."
                Write-Host "  Source lines: $(($sourceContent -split "`n").Count) | Exported lines: $(($exportedContent -split "`n").Count)"
            }
        } else {
            Write-Warning "No ruleset file found in exported zip."
        }

        # Cleanup temp files
        Remove-Item $exportedZipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $expandDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Could not decode exported ruleset for verification: $_"
    }

    Write-Host "Deployment verified successfully."
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue

Write-Host "Done."
