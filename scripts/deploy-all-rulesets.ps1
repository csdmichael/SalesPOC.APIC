<#
.SYNOPSIS
    Deploys all rulesets found under the rulesets/ directory to Azure API Center.

.DESCRIPTION
    Discovers every subdirectory under RulesetsRoot that contains a ruleset.yaml (or .yml),
    then calls deploy-ruleset.ps1 for each one. The subdirectory name is used as the
    analyzerConfig name.

.PARAMETER SubscriptionId
    Azure subscription ID containing the API Center service.

.PARAMETER ResourceGroup
    Resource group name containing the API Center service.

.PARAMETER ServiceName
    Name of the Azure API Center service.

.PARAMETER RulesetsRoot
    Path to the root directory containing ruleset subdirectories.
    Defaults to "./rulesets".
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$ServiceName,

    [Parameter(Mandatory = $false)]
    [string]$RulesetsRoot = "./rulesets"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $RulesetsRoot)) {
    throw "Rulesets root directory not found: $RulesetsRoot"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$deploySingleScript = Join-Path $scriptDir "deploy-ruleset.ps1"

if (-not (Test-Path $deploySingleScript)) {
    throw "deploy-ruleset.ps1 not found at: $deploySingleScript"
}

# Discover all ruleset subdirectories
$rulesetDirs = Get-ChildItem -Path $RulesetsRoot -Directory | Where-Object {
    (Test-Path (Join-Path $_.FullName "ruleset.yaml")) -or
    (Test-Path (Join-Path $_.FullName "ruleset.yml"))
}

if ($rulesetDirs.Count -eq 0) {
    Write-Warning "No ruleset directories found under $RulesetsRoot"
    exit 0
}

Write-Host "Found $($rulesetDirs.Count) ruleset(s) to deploy:" -ForegroundColor Cyan
$rulesetDirs | ForEach-Object { Write-Host "  - $($_.Name)" }
Write-Host ""

$failed = @()
$succeeded = @()

foreach ($dir in $rulesetDirs) {
    $configName = $dir.Name
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Deploying: $configName" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    try {
        & $deploySingleScript `
            -SubscriptionId $SubscriptionId `
            -ResourceGroup $ResourceGroup `
            -ServiceName $ServiceName `
            -AnalyzerConfigName $configName `
            -RulesetPath $dir.FullName

        $succeeded += $configName
        Write-Host "[$configName] Deployed successfully.`n" -ForegroundColor Green
    }
    catch {
        $failed += $configName
        Write-Warning "[$configName] Deployment failed: $_"
        Write-Host ""
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deployment Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Succeeded: $($succeeded.Count) - $($succeeded -join ', ')" -ForegroundColor Green
if ($failed.Count -gt 0) {
    Write-Host "  Failed:    $($failed.Count) - $($failed -join ', ')" -ForegroundColor Red
    throw "$($failed.Count) ruleset deployment(s) failed."
}

Write-Host "`nAll rulesets deployed successfully." -ForegroundColor Green
