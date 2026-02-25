<#
.SYNOPSIS
    Deploys a Spectral ruleset to Azure API Center analyzerConfig via the importRuleset action.

.DESCRIPTION
    This script packages the ruleset directory (ruleset.yaml + any functions/) into a zip,
    base64-encodes it, and imports it into the specified API Center analyzer configuration
    using the Azure REST API.

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
$importUrl = "$baseUrl/workspaces/default/analyzerConfigs/$AnalyzerConfigName/importRuleset?api-version=$ApiVersion"

$bodyObj = @{ format = "inline-zip"; value = $base64 }
$json = $bodyObj | ConvertTo-Json -Compress

$bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) "$AnalyzerConfigName-import-body.json"
[System.IO.File]::WriteAllText($bodyFile, $json, [System.Text.Encoding]::UTF8)

Write-Host "Importing ruleset into analyzer config '$AnalyzerConfigName'..."
$importResult = az rest --method POST --url $importUrl --body "@$bodyFile" --headers "Content-Type=application/json" 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Import failed: $importResult"
    throw "Azure CLI command failed with exit code $LASTEXITCODE"
}

Write-Host "Import completed successfully."

# ── Verify deployment ────────────────────────────────────────────────────────

Write-Host "Verifying deployment..."
$exportUrl = "$baseUrl/workspaces/default/analyzerConfigs/$AnalyzerConfigName/exportRuleset?api-version=$ApiVersion"
$exportResult = az rest --method POST --url $exportUrl --headers "Content-Type=application/json" -o json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Verification export failed: $exportResult"
} else {
    $export = $exportResult | ConvertFrom-Json
    Write-Host "Verification: Exported format = $($export.format), value length = $($export.value.Length)"
    Write-Host "Deployment verified successfully."
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue

Write-Host "Done."
