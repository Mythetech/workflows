# Copyright (c) Mythetech. Licensed under the MIT License.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Start-SmokeRun.ps1')
}

Describe 'Get-SmokeEnvironment' {
    It 'turns smoke mode on with the budget and result path' {
        $environment = Get-SmokeEnvironment -TimeoutSeconds 45 -ResultPath '/tmp/out/result.json'

        $environment['HERMES_SMOKE_TEST'] | Should -Be '1'
        $environment['HERMES_SMOKE_TEST_TIMEOUT'] | Should -Be '45'
        $environment['HERMES_SMOKE_TEST_RESULT'] | Should -Be '/tmp/out/result.json'
    }
}

Describe 'Get-SmokeLaunchPlan' {
    It 'launches macOS apps through open with explicit environment and output paths' {
        $environment = [ordered]@{ HERMES_SMOKE_TEST = '1'; HERMES_SMOKE_TEST_TIMEOUT = '60' }

        $plan = Get-SmokeLaunchPlan -Platform macOS -TargetPath '/work/app/My App.app' `
            -StdoutPath '/work/out/app-stdout.log' -StderrPath '/work/out/app-stderr.log' -Environment $environment

        $plan.FilePath | Should -Be 'open'
        $plan.RedirectOutput | Should -BeFalse
        $plan.ArgumentList | Should -Be @(
            '-W', '-n',
            '--env', 'HERMES_SMOKE_TEST=1',
            '--env', 'HERMES_SMOKE_TEST_TIMEOUT=60',
            '--stdout', '/work/out/app-stdout.log',
            '--stderr', '/work/out/app-stderr.log',
            '/work/app/My App.app'
        )
    }

    It 'keeps a path with spaces as a single argument' {
        $plan = Get-SmokeLaunchPlan -Platform macOS -TargetPath '/work/app/Http Platypus.app' `
            -StdoutPath '/o/out.log' -StderrPath '/o/err.log' -Environment ([ordered]@{})

        $plan.ArgumentList[-1] | Should -Be '/work/app/Http Platypus.app'
    }

    It 'runs Windows and Linux targets directly with redirected output' {
        foreach ($platform in 'Windows', 'Linux') {
            $plan = Get-SmokeLaunchPlan -Platform $platform -TargetPath '/work/app/App' `
                -StdoutPath '/o/out.log' -StderrPath '/o/err.log' -Environment ([ordered]@{})

            $plan.FilePath | Should -Be '/work/app/App'
            $plan.RedirectOutput | Should -BeTrue
            @($plan.ArgumentList).Count | Should -Be 0
        }
    }
}

Describe 'Test-SmokeStarted' {
    It 'is false when the log does not exist yet' {
        Test-SmokeStarted -LogPath (Join-Path $TestDrive ([guid]::NewGuid())) | Should -BeFalse
    }

    It 'is true once the start line is in the log, even with Windows line endings' {
        $logPath = Join-Path $TestDrive 'stdout-crlf.log'
        [System.IO.File]::WriteAllText($logPath, "starting up`r`nHERMES_SMOKE_START: App 1.0.0 Windows x64`r`n")

        Test-SmokeStarted -LogPath $logPath | Should -BeTrue
    }

    It 'ignores the marker when it is not at the start of a line' {
        $logPath = Join-Path $TestDrive 'stdout-embedded.log'
        Set-Content -LiteralPath $logPath -Value 'echo HERMES_SMOKE_START: nope'

        Test-SmokeStarted -LogPath $logPath | Should -BeFalse
    }
}

Describe 'Get-SmokeRunOutcome' {
    It 'classifies an app that exited before the start window as legacy, not alive' {
        $outcome = Get-SmokeRunOutcome -Platform Linux -Started $false -Mode 'verdict' -TimedOut $false `
            -LegacyAlive $false -ExitCode 1 -StartedAfterExit $false

        $outcome.mode | Should -Be 'legacy'
        $outcome.legacyAlive | Should -BeFalse
        $outcome.exitCode | Should -BeNullOrEmpty
    }

    It 'keeps a legacy app alive when the start window elapsed with the process still running' {
        $outcome = Get-SmokeRunOutcome -Platform Linux -Started $false -Mode 'legacy' -TimedOut $false `
            -LegacyAlive $true -ExitCode 0 -StartedAfterExit $false

        $outcome.mode | Should -Be 'legacy'
        $outcome.legacyAlive | Should -BeTrue
        $outcome.exitCode | Should -BeNullOrEmpty
    }

    It 'never gives a liveness pass when the start line only becomes readable after the legacy stop' {
        $outcome = Get-SmokeRunOutcome -Platform Linux -Started $false -Mode 'legacy' -TimedOut $false `
            -LegacyAlive $true -ExitCode 0 -StartedAfterExit $true

        $outcome.mode | Should -Be 'verdict'
        $outcome.timedOut | Should -BeTrue
        $outcome.legacyAlive | Should -BeFalse
        $outcome.exitCode | Should -BeNullOrEmpty
    }

    It 'nulls the exit code for a verdict-mode timeout' {
        $outcome = Get-SmokeRunOutcome -Platform Windows -Started $true -Mode 'verdict' -TimedOut $true `
            -LegacyAlive $false -ExitCode 0 -StartedAfterExit $false

        $outcome.mode | Should -Be 'verdict'
        $outcome.exitCode | Should -BeNullOrEmpty
    }

    It 'keeps the process exit code for a normal verdict exit on Windows and Linux' {
        foreach ($platform in 'Windows', 'Linux') {
            $outcome = Get-SmokeRunOutcome -Platform $platform -Started $true -Mode 'verdict' -TimedOut $false `
                -LegacyAlive $false -ExitCode 3 -StartedAfterExit $false

            $outcome.mode | Should -Be 'verdict'
            $outcome.exitCode | Should -Be 3
        }
    }

    It 'always nulls the exit code on macOS even on a normal verdict exit' {
        $outcome = Get-SmokeRunOutcome -Platform macOS -Started $true -Mode 'verdict' -TimedOut $false `
            -LegacyAlive $false -ExitCode 0 -StartedAfterExit $false

        $outcome.mode | Should -Be 'verdict'
        $outcome.exitCode | Should -BeNullOrEmpty
    }
}
