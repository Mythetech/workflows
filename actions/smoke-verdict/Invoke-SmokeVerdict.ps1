# Copyright (c) Mythetech. Licensed under the MIT License.
# Decides a smoke run's verdict from the files Start-SmokeRun.ps1 (or Hermes CI) left in OutputDir.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutputDir,
    # Strings, not bools: YAML inputs arrive as text and [bool]'false' is $true.
    [string] $RequireVerdict = 'false',
    [string] $FailOnFailed = 'true',
    [string] $Platform = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SmokeVerdict.ps1')

$logPath = Join-Path $OutputDir 'app-stdout.log'
$resultPath = Join-Path $OutputDir 'result.json'
$runPath = Join-Path $OutputDir 'run.json'

$logLines = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath) } else { @() }
$resultJson = if (Test-Path -LiteralPath $resultPath) { [string](Get-Content -LiteralPath $resultPath -Raw) } else { '' }
$run = if (Test-Path -LiteralPath $runPath) {
    Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json
} else {
    [pscustomobject]@{ mode = 'verdict'; exitCode = $null; timedOut = $false; legacyAlive = $false }
}

$verdict = Get-SmokeVerdict `
    -LogLines $logLines `
    -ResultJson $resultJson `
    -Mode $run.mode `
    -ExitCode $run.exitCode `
    -TimedOut ([bool]$run.timedOut) `
    -LegacyAlive ([bool]$run.legacyAlive) `
    -RequireVerdict ($RequireVerdict -eq 'true')

$summary = Format-SmokeSummary -Verdict $verdict -Platform $Platform
Write-Output $summary

if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary
}

if ($env:GITHUB_OUTPUT) {
    $result = if ($verdict.Passed) { 'passed' } else { 'failed' }
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "result=$result"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "reason=$($verdict.Reason -replace '[\r\n]+', ' ')"
}

foreach ($warning in $verdict.Warnings) {
    Write-Output "::warning::$warning"
}

if (-not $verdict.Passed -and $FailOnFailed -eq 'true') {
    Write-Output "::error::Smoke test failed: $($verdict.Reason)"
    exit 1
}
