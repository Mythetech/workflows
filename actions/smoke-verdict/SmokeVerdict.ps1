# Copyright (c) Mythetech. Licensed under the MIT License.
# Verdict rules for Hermes smoke runs, shared by the smoke-test action and Hermes CI.
# Dot-source this file; Invoke-SmokeVerdict.ps1 is the command-line wrapper.

Set-StrictMode -Version Latest

function Get-SmokeLineValues {
    param([string[]] $LogLines, [Parameter(Mandatory)] [string] $Prefix)

    foreach ($line in $LogLines) {
        # Logs captured on Windows keep a trailing carriage return on every line.
        $trimmed = $line.TrimEnd("`r")
        if ($trimmed.StartsWith($Prefix, [StringComparison]::Ordinal)) {
            $trimmed.Substring($Prefix.Length).Trim()
        }
    }
}

function New-SmokeVerdict {
    param(
        [bool] $Passed,
        [string] $Source,
        [string] $Reason,
        [string[]] $Milestones = @(),
        [string[]] $FailedChecks = @(),
        [string[]] $Errors = @(),
        [string[]] $Warnings = @()
    )

    [pscustomobject]@{
        Passed        = $Passed
        Source        = $Source
        Reason        = $Reason
        Milestones    = @($Milestones)
        FailedChecks  = @($FailedChecks)
        Errors        = @($Errors)
        LastMilestone = $(if (@($Milestones).Count -gt 0) { @($Milestones)[-1] } else { $null })
        Warnings      = @($Warnings)
    }
}

function Get-SmokeResultFileReason {
    param([Parameter(Mandatory)] $Result)

    $checks = @($Result.checks)
    if ($Result.result -eq 'passed') {
        return "All $($checks.Count) checks passed"
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $failed = @($checks | Where-Object { $_.status -eq 'failed' } | ForEach-Object { $_.name })
    if ($failed.Count -gt 0) {
        $parts.Add("$($failed.Count)/$($checks.Count) checks failed ($($failed -join ', '))")
    }

    $errorCount = @($Result.errors).Count
    if ($errorCount -gt 0) {
        $parts.Add($(if ($errorCount -eq 1) { '1 error' } else { "$errorCount errors" }))
    }

    if ($Result.timedOutWaitingFor) {
        $parts.Add("timed out waiting for $($Result.timedOutWaitingFor)")
    }

    if ($parts.Count -eq 0) {
        $parts.Add('The app reported a failed run')
    }

    return ($parts -join ', ')
}

function Get-SmokeVerdict {
    [CmdletBinding()]
    param(
        [string[]] $LogLines = @(),
        [string] $ResultJson = '',
        [Parameter(Mandatory)] [ValidateSet('verdict', 'legacy')] [string] $Mode,
        [Nullable[int]] $ExitCode = $null,
        [bool] $TimedOut = $false,
        [bool] $LegacyAlive = $false,
        [bool] $RequireVerdict = $false
    )

    $milestones = @(Get-SmokeLineValues -LogLines $LogLines -Prefix 'HERMES_SMOKE_MILESTONE:' | ForEach-Object { ($_ -split '\s+')[0] })
    $failedChecks = @(Get-SmokeLineValues -LogLines $LogLines -Prefix 'HERMES_SMOKE_CHECK_FAIL:')
    $errors = @(Get-SmokeLineValues -LogLines $LogLines -Prefix 'HERMES_SMOKE_ERROR:')
    $resultLines = @(Get-SmokeLineValues -LogLines $LogLines -Prefix 'HERMES_SMOKE_RESULT:')
    $details = @{ Milestones = $milestones; FailedChecks = $failedChecks; Errors = $errors }

    if ($Mode -eq 'legacy') {
        if ($RequireVerdict) {
            return New-SmokeVerdict -Passed $false -Source 'legacy' @details `
                -Reason 'The app never printed HERMES_SMOKE_START, so this build does not support smoke mode, and require_verdict is set'
        }
        if ($LegacyAlive) {
            return New-SmokeVerdict -Passed $true -Source 'legacy' @details `
                -Reason 'The app stayed alive through the liveness check' `
                -Warnings @('This build does not support smoke mode (no HERMES_SMOKE_START); only liveness was verified')
        }
        return New-SmokeVerdict -Passed $false -Source 'legacy' @details `
            -Reason 'The app exited before the liveness check, without printing HERMES_SMOKE_START'
    }

    $passed = $null
    $source = $null
    $reason = $null

    if (-not [string]::IsNullOrWhiteSpace($ResultJson)) {
        try {
            $result = $ResultJson | ConvertFrom-Json -ErrorAction Stop
            $reason = Get-SmokeResultFileReason -Result $result
            $passed = $result.result -eq 'passed'
            $source = 'result-file'
        }
        catch {
            # A truncated or malformed file means the app died while writing it; the log still has the verdict line.
            $passed = $null
        }
    }

    if ($null -eq $passed -and $resultLines.Count -gt 0) {
        $line = $resultLines[-1]
        $passed = $line.StartsWith('PASSED', [StringComparison]::Ordinal)
        $source = 'log'
        $reason = $line
    }

    if ($null -eq $passed) {
        $how = if ($TimedOut) { 'was killed after the CI timeout' } else { 'exited' }
        $where = if ($milestones.Count -gt 0) { "last milestone reached: $($milestones[-1])" } else { 'no milestone was reached' }
        return New-SmokeVerdict -Passed $false -Source 'none' @details -Reason "The app $how without printing a verdict ($where)"
    }

    if ($passed -and $TimedOut) {
        return New-SmokeVerdict -Passed $false -Source $source @details `
            -Reason 'The app reported PASSED but did not exit before the CI timeout (hung during shutdown)'
    }

    if ($passed -and $null -ne $ExitCode -and $ExitCode -ne 0) {
        return New-SmokeVerdict -Passed $false -Source $source @details `
            -Reason "The app reported PASSED but exited with code $ExitCode (crashed during shutdown)"
    }

    return New-SmokeVerdict -Passed $passed -Source $source -Reason $reason @details
}

function Format-SmokeSummary {
    param([Parameter(Mandatory)] $Verdict, [string] $Platform = '')

    $status = if ($Verdict.Passed) { 'PASSED' } else { 'FAILED' }
    $title = if ($Platform) { "### Smoke test ($Platform): $status" } else { "### Smoke test: $status" }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($title)
    $lines.Add('')
    $lines.Add($Verdict.Reason)

    if (@($Verdict.Milestones).Count -gt 0) {
        $lines.Add('')
        $lines.Add("Milestones: $(@($Verdict.Milestones) -join ', ')")
    }

    if (@($Verdict.FailedChecks).Count + @($Verdict.Errors).Count + @($Verdict.Warnings).Count -gt 0) {
        $lines.Add('')
    }
    foreach ($check in $Verdict.FailedChecks) { $lines.Add("- Failed check: $check") }
    foreach ($errorLine in $Verdict.Errors) { $lines.Add("- Error: $errorLine") }
    foreach ($warning in $Verdict.Warnings) { $lines.Add("- Warning: $warning") }

    return ($lines -join [Environment]::NewLine)
}
