# Copyright (c) Mythetech. Licensed under the MIT License.
# Decides a smoke run's verdict from the files Start-SmokeRun.ps1 (or Hermes CI) left in OutputDir:
# app-stdout.log, optionally result.json, and run.json, a JSON object
# { "mode": "verdict"|"legacy", "exitCode": int|null, "timedOut": bool, "legacyAlive": bool }
# written by Start-SmokeRun.ps1.
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
$errPath = Join-Path $OutputDir 'app-stderr.log'
$resultPath = Join-Path $OutputDir 'result.json'
$runPath = Join-Path $OutputDir 'run.json'

$logLines = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath) } else { @() }
$resultJson = if (Test-Path -LiteralPath $resultPath) { [string](Get-Content -LiteralPath $resultPath -Raw) } else { '' }

$verdict = if (Test-Path -LiteralPath $runPath) {
    $run = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json
    Get-SmokeVerdict `
        -LogLines $logLines `
        -ResultJson $resultJson `
        -Mode $run.mode `
        -ExitCode $run.exitCode `
        -TimedOut ([bool]$run.timedOut) `
        -LegacyAlive ([bool]$run.legacyAlive) `
        -RequireVerdict ($RequireVerdict -eq 'true')
} else {
    # No run.json means the launcher itself never got that far (for example Find-SmokeTarget
    # threw before a process was even started); defaulting to verdict mode would blame the app
    # for something the launcher never gave it the chance to do.
    New-SmokeVerdict -Passed $false -Source 'none' `
        -Reason 'The launcher did not record a run (it failed before or while starting the app)'
}

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

if (-not $verdict.Passed) {
    foreach ($stream in @(@{ Name = 'stdout'; Path = $logPath }, @{ Name = 'stderr'; Path = $errPath })) {
        if (Test-Path -LiteralPath $stream.Path) {
            Write-Output "::group::App $($stream.Name) (last 50 lines)"
            Get-Content -LiteralPath $stream.Path -Tail 50 | ForEach-Object { Write-Output $_ }
            Write-Output '::endgroup::'
        }
    }
}

if (-not $verdict.Passed -and $FailOnFailed -eq 'true') {
    Write-Output "::error::Smoke test failed: $($verdict.Reason)"
    exit 1
}
