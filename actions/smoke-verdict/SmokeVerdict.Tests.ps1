# Copyright (c) Mythetech. Licensed under the MIT License.

BeforeAll {
    . (Join-Path $PSScriptRoot 'SmokeVerdict.ps1')

    function New-ResultJson {
        param([string] $Result, [object[]] $Checks = @(), [object[]] $Errors = @(), [string] $TimedOutWaitingFor = $null)
        [ordered]@{
            schema             = 1
            result             = $Result
            timedOutWaitingFor = $TimedOutWaitingFor
            checks             = $Checks
            errors             = $Errors
        } | ConvertTo-Json -Depth 5
    }
}

Describe 'Get-SmokeVerdict in verdict mode' {
    It 'passes from a passing result file' {
        $json = New-ResultJson -Result 'passed' -Checks @(@{ name = 'framework/initialization'; status = 'passed' })

        $verdict = Get-SmokeVerdict -Mode verdict -ResultJson $json -ExitCode 0

        $verdict.Passed | Should -BeTrue
        $verdict.Source | Should -Be 'result-file'
        $verdict.Reason | Should -Be 'All 1 checks passed'
    }

    It 'explains a failing result file with its failed checks, errors and timeout' {
        $json = New-ResultJson -Result 'failed' -TimedOutWaitingFor 'app-ready' `
            -Checks @(@{ name = 'horizon/workspace-store'; status = 'failed' }, @{ name = 'framework/storage'; status = 'passed' }) `
            -Errors @(@{ source = 'blazor'; type = 'InvalidOperationException'; message = 'boom' })

        $verdict = Get-SmokeVerdict -Mode verdict -ResultJson $json

        $verdict.Passed | Should -BeFalse
        $verdict.Reason | Should -Be '1/2 checks failed (horizon/workspace-store), 1 error, timed out waiting for app-ready'
    }

    It 'falls back to the last result line when there is no result file' {
        $log = @('HERMES_SMOKE_START: App 1.0.0 Linux x64', 'HERMES_SMOKE_RESULT: PASSED (2 checks)')

        $verdict = Get-SmokeVerdict -Mode verdict -LogLines $log -ExitCode 0

        $verdict.Passed | Should -BeTrue
        $verdict.Source | Should -Be 'log'
        $verdict.Reason | Should -Be 'PASSED (2 checks)'
    }

    It 'fails from a failed result line' {
        $log = @('HERMES_SMOKE_RESULT: FAILED (1/3 checks failed, 0 errors)')

        $verdict = Get-SmokeVerdict -Mode verdict -LogLines $log

        $verdict.Passed | Should -BeFalse
        $verdict.Reason | Should -Be 'FAILED (1/3 checks failed, 0 errors)'
    }

    It 'matches lines that end with a Windows carriage return' {
        $log = @("HERMES_SMOKE_MILESTONE: window-shown 10ms`r", "HERMES_SMOKE_RESULT: PASSED (0 checks)`r")

        $verdict = Get-SmokeVerdict -Mode verdict -LogLines $log -ExitCode 0

        $verdict.Passed | Should -BeTrue
        $verdict.Milestones | Should -Be @('window-shown')
    }

    It 'falls back to the log when the result file is empty or truncated' {
        $log = @('HERMES_SMOKE_RESULT: PASSED (1 checks)')

        (Get-SmokeVerdict -Mode verdict -LogLines $log -ResultJson '' -ExitCode 0).Source | Should -Be 'log'
        (Get-SmokeVerdict -Mode verdict -LogLines $log -ResultJson '{"schema":1,"res' -ExitCode 0).Source | Should -Be 'log'
    }

    It 'fails with the last milestone when the app was killed without a verdict' {
        $log = @('HERMES_SMOKE_START: App 1.0.0 macOS arm64', 'HERMES_SMOKE_MILESTONE: window-shown 400ms', 'HERMES_SMOKE_MILESTONE: first-render 900ms')

        $verdict = Get-SmokeVerdict -Mode verdict -LogLines $log -TimedOut $true

        $verdict.Passed | Should -BeFalse
        $verdict.Source | Should -Be 'none'
        $verdict.Reason | Should -Be 'The app was killed after the CI timeout without printing a verdict (last milestone reached: first-render)'
    }

    It 'fails when the app exited without a verdict or any milestone' {
        $verdict = Get-SmokeVerdict -Mode verdict -LogLines @('HERMES_SMOKE_START: App 1.0.0 Windows x64') -ExitCode 1

        $verdict.Passed | Should -BeFalse
        $verdict.Reason | Should -Be 'The app exited without printing a verdict (no milestone was reached)'
    }

    It 'fails a passing verdict when the app crashed during shutdown' {
        $verdict = Get-SmokeVerdict -Mode verdict -LogLines @('HERMES_SMOKE_RESULT: PASSED (1 checks)') -ExitCode 139

        $verdict.Passed | Should -BeFalse
        $verdict.Reason | Should -Be 'The app reported PASSED but exited with code 139 (crashed during shutdown)'
    }

    It 'fails a passing verdict when the app hung during shutdown' {
        $verdict = Get-SmokeVerdict -Mode verdict -LogLines @('HERMES_SMOKE_RESULT: PASSED (1 checks)') -TimedOut $true

        $verdict.Passed | Should -BeFalse
        $verdict.Reason | Should -Be 'The app reported PASSED but did not exit before the CI timeout (hung during shutdown)'
    }

    It 'collects failed checks and errors from the log for the summary' {
        $log = @(
            'HERMES_SMOKE_CHECK_FAIL: horizon/workspace-store 10002ms - Timed out after 10s',
            'HERMES_SMOKE_ERROR: blazor: UnhandledException: Theme palette was null',
            'HERMES_SMOKE_RESULT: FAILED (1/1 checks failed, 1 error)'
        )

        $verdict = Get-SmokeVerdict -Mode verdict -LogLines $log

        $verdict.FailedChecks | Should -Be @('horizon/workspace-store 10002ms - Timed out after 10s')
        $verdict.Errors | Should -Be @('blazor: UnhandledException: Theme palette was null')
    }
}

Describe 'Get-SmokeVerdict in legacy mode' {
    It 'passes with a warning when the process stayed alive' {
        $verdict = Get-SmokeVerdict -Mode legacy -LegacyAlive $true

        $verdict.Passed | Should -BeTrue
        $verdict.Source | Should -Be 'legacy'
        $verdict.Warnings | Should -Be @('This build does not support smoke mode (no HERMES_SMOKE_START); only liveness was verified')
    }

    It 'fails when the process exited before the liveness check' {
        $verdict = Get-SmokeVerdict -Mode legacy -LegacyAlive $false

        $verdict.Passed | Should -BeFalse
        $verdict.Reason | Should -Be 'The app exited before the liveness check, without printing HERMES_SMOKE_START'
    }

    It 'fails when a verdict is required' {
        $verdict = Get-SmokeVerdict -Mode legacy -LegacyAlive $true -RequireVerdict $true

        $verdict.Passed | Should -BeFalse
        $verdict.Reason | Should -Be 'The app never printed HERMES_SMOKE_START, so this build does not support smoke mode, and require_verdict is set'
    }
}

Describe 'Format-SmokeSummary' {
    It 'lists the reason, milestones, failed checks, errors and warnings' {
        $log = @(
            'HERMES_SMOKE_MILESTONE: window-shown 400ms',
            'HERMES_SMOKE_CHECK_FAIL: app/check 5ms - boom',
            'HERMES_SMOKE_ERROR: log: Error: bad',
            'HERMES_SMOKE_RESULT: FAILED (1/1 checks failed, 1 error)'
        )
        $verdict = Get-SmokeVerdict -Mode verdict -LogLines $log

        $summary = Format-SmokeSummary -Verdict $verdict -Platform 'Linux'

        $summary | Should -Match '### Smoke test \(Linux\): FAILED'
        $summary | Should -Match 'FAILED \(1/1 checks failed, 1 error\)'
        $summary | Should -Match 'Milestones: window-shown'
        $summary | Should -Match '- Failed check: app/check 5ms - boom'
        $summary | Should -Match '- Error: log: Error: bad'
    }
}
