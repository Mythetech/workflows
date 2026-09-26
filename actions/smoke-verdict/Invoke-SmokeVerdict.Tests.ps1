# Copyright (c) Mythetech. Licensed under the MIT License.

BeforeAll {
    $script:Command = Join-Path $PSScriptRoot 'Invoke-SmokeVerdict.ps1'

    function New-RunDirectory {
        param([string[]] $Log, [hashtable] $Run)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        if ($null -ne $Log) { Set-Content -LiteralPath (Join-Path $dir 'app-stdout.log') -Value $Log }
        if ($null -ne $Run) { $Run | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'run.json') }
        return $dir
    }

    function Read-GitHubOutput {
        param([string] $Path)
        $values = @{}
        foreach ($line in Get-Content -LiteralPath $Path) {
            $name, $value = $line -split '=', 2
            $values[$name] = $value
        }
        return $values
    }
}

Describe 'Invoke-SmokeVerdict.ps1' {
    BeforeEach {
        $script:OutputFile = New-TemporaryFile
        $env:GITHUB_OUTPUT = $script:OutputFile.FullName
        $env:GITHUB_STEP_SUMMARY = (New-TemporaryFile).FullName
    }

    AfterEach {
        Remove-Item Env:GITHUB_OUTPUT, Env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
    }

    It 'treats the string false as false for require_verdict' {
        $dir = New-RunDirectory -Log @('app output') -Run @{ mode = 'legacy'; exitCode = $null; timedOut = $false; legacyAlive = $true }

        & $script:Command -OutputDir $dir -RequireVerdict 'false' -FailOnFailed 'false'

        (Read-GitHubOutput $script:OutputFile.FullName)['result'] | Should -Be 'passed'
    }

    It 'treats the string true as true for require_verdict' {
        $dir = New-RunDirectory -Log @('app output') -Run @{ mode = 'legacy'; exitCode = $null; timedOut = $false; legacyAlive = $true }

        & $script:Command -OutputDir $dir -RequireVerdict 'true' -FailOnFailed 'false'

        (Read-GitHubOutput $script:OutputFile.FullName)['result'] | Should -Be 'failed'
    }

    It 'reports no verdict when the log file is missing' {
        $dir = New-RunDirectory -Log $null -Run @{ mode = 'verdict'; exitCode = $null; timedOut = $true; legacyAlive = $false }

        & $script:Command -OutputDir $dir -RequireVerdict 'false' -FailOnFailed 'false'

        $outputs = Read-GitHubOutput $script:OutputFile.FullName
        $outputs['result'] | Should -Be 'failed'
        $outputs['reason'] | Should -Be 'The app was killed after the CI timeout without printing a verdict (no milestone was reached)'
    }

    It 'writes the summary to the step summary file' {
        $dir = New-RunDirectory -Log @('HERMES_SMOKE_RESULT: PASSED (0 checks)') -Run @{ mode = 'verdict'; exitCode = 0; timedOut = $false; legacyAlive = $false }

        & $script:Command -OutputDir $dir -Platform 'Windows' -FailOnFailed 'false'

        Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw | Should -Match '### Smoke test \(Windows\): PASSED'
    }

    It 'exits 1 on a failed verdict when failing is enabled' {
        $dir = New-RunDirectory -Log @('HERMES_SMOKE_RESULT: FAILED (1/1 checks failed, 0 errors)') -Run @{ mode = 'verdict'; exitCode = 1; timedOut = $false; legacyAlive = $false }

        & $script:Command -OutputDir $dir -FailOnFailed 'true' | Out-Null

        $LASTEXITCODE | Should -Be 1
    }
}
