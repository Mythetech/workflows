# Copyright (c) Mythetech. Licensed under the MIT License.
# Launches a packaged desktop app in Hermes smoke mode and records how the run ended in run.json.
# Dot-source to load the functions only (the tests do); run as a script to perform a run.
[CmdletBinding()]
param(
    [string] $AppName,
    [string] $Platform,
    [string] $ReleasesDir = 'releases',
    [string] $OutputDir = 'smoke-output',
    [int] $TimeoutSeconds = 60
)

Set-StrictMode -Version Latest

# A cold single-file launch on a macOS runner can take longer than 15 seconds before the Hermes
# builder prints HERMES_SMOKE_START, so the window is wider than the spec's 15. Only apps that
# predate smoke mode pay for it.
$script:SmokeStartWindowSeconds = 30
$script:CiGraceSeconds = 30

function Get-SmokeEnvironment {
    param([Parameter(Mandatory)] [int] $TimeoutSeconds, [Parameter(Mandatory)] [string] $ResultPath)

    [ordered]@{
        HERMES_SMOKE_TEST         = '1'
        HERMES_SMOKE_TEST_TIMEOUT = "$TimeoutSeconds"
        HERMES_SMOKE_TEST_RESULT  = $ResultPath
    }
}

function Get-SmokeLaunchPlan {
    param(
        [Parameter(Mandatory)] [ValidateSet('Windows', 'macOS', 'Linux')] [string] $Platform,
        [Parameter(Mandatory)] [string] $TargetPath,
        [Parameter(Mandatory)] [string] $StdoutPath,
        [Parameter(Mandatory)] [string] $StderrPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Environment
    )

    if ($Platform -eq 'macOS') {
        # open hands the app to LaunchServices, which ignores the caller's environment and stdout,
        # so both go through open's own flags. -W waits for the app to quit; -n forces a new
        # instance so the flags apply.
        $arguments = [System.Collections.Generic.List[string]]::new()
        $arguments.Add('-W')
        $arguments.Add('-n')
        foreach ($key in $Environment.Keys) {
            $arguments.Add('--env')
            $arguments.Add("$key=$($Environment[$key])")
        }
        $arguments.Add('--stdout')
        $arguments.Add($StdoutPath)
        $arguments.Add('--stderr')
        $arguments.Add($StderrPath)
        $arguments.Add($TargetPath)

        return [pscustomobject]@{ FilePath = 'open'; ArgumentList = $arguments.ToArray(); RedirectOutput = $false }
    }

    return [pscustomobject]@{ FilePath = $TargetPath; ArgumentList = @(); RedirectOutput = $true }
}

function Test-SmokeStarted {
    param([Parameter(Mandatory)] [string] $LogPath)

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return $false
    }

    try {
        # The app is still writing the log; open it shared so this read never blocks the writer.
        $stream = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $text = [System.IO.StreamReader]::new($stream).ReadToEnd()
        }
        finally {
            $stream.Dispose()
        }
    }
    catch [System.IO.IOException] {
        return $false
    }

    return $text -match '(?m)^HERMES_SMOKE_START:'
}

function Find-SmokeTarget {
    param([string] $Platform, [string] $AppName, [string] $ReleasesDir, [string] $WorkDir)

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

    switch ($Platform) {
        'Windows' {
            $zip = Get-ChildItem -Path $ReleasesDir -Filter '*Portable*.zip' -Recurse | Select-Object -First 1
            if (-not $zip) { $zip = Get-ChildItem -Path $ReleasesDir -Filter '*.zip' -Recurse | Select-Object -First 1 }
            if (-not $zip) { throw "No zip archive found in $ReleasesDir" }
            Expand-Archive -Path $zip.FullName -DestinationPath $WorkDir -Force

            if (-not (Get-ChildItem -Path $WorkDir -Filter 'Microsoft.Web.WebView2*.dll' -Recurse)) {
                Write-Warning 'WebView2 assemblies were not found in the package'
            }

            # Velopack puts a launcher stub at the root; the real app lives in current/.
            $exe = Get-ChildItem -Path (Join-Path $WorkDir 'current') -Filter "$AppName.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $exe) { $exe = Get-ChildItem -Path $WorkDir -Filter "$AppName.exe" -Recurse | Select-Object -First 1 }
            if (-not $exe) { throw "$AppName.exe not found in the package" }
            return $exe.FullName
        }
        'macOS' {
            $zip = Get-ChildItem -Path $ReleasesDir -Filter '*Portable*.zip' -Recurse | Select-Object -First 1
            if (-not $zip) { $zip = Get-ChildItem -Path $ReleasesDir -Filter '*.zip' -Recurse | Select-Object -First 1 }
            if (-not $zip) { throw "No zip archive found in $ReleasesDir" }
            # unzip keeps the symlinks and executable bits an app bundle needs; Expand-Archive does not.
            & unzip -q $zip.FullName -d $WorkDir
            if ($LASTEXITCODE -ne 0) { throw "unzip failed for $($zip.FullName)" }

            $bundle = Get-ChildItem -Path $WorkDir -Filter '*.app' -Directory -Recurse | Select-Object -First 1
            if (-not $bundle) { throw "No .app bundle found in $($zip.FullName)" }
            & xattr -cr $bundle.FullName
            return $bundle.FullName
        }
        'Linux' {
            $appImage = Get-ChildItem -Path $ReleasesDir -Filter '*.AppImage' -Recurse | Select-Object -First 1
            if (-not $appImage) { throw "No AppImage found in $ReleasesDir" }
            & chmod +x $appImage.FullName
            return $appImage.FullName
        }
        default { throw "Unknown platform '$Platform'" }
    }
}

function Start-SmokeProcess {
    param($Plan, [string] $StdoutPath, [string] $StderrPath, [System.Collections.IDictionary] $Environment)

    foreach ($key in $Environment.Keys) {
        Set-Item -Path "env:$key" -Value $Environment[$key]
    }

    if ($Plan.RedirectOutput) {
        $process = Start-Process -FilePath $Plan.FilePath -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath -PassThru
    }
    else {
        # ProcessStartInfo.ArgumentList quotes each argument correctly; Start-Process joins them with spaces.
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new($Plan.FilePath)
        foreach ($argument in $Plan.ArgumentList) { $startInfo.ArgumentList.Add($argument) }
        $startInfo.UseShellExecute = $false
        $process = [System.Diagnostics.Process]::Start($startInfo)
    }

    # Reading Handle now keeps ExitCode available after the process ends on Windows.
    $null = $process.Handle
    return $process
}

function Stop-SmokeApp {
    param([string] $Platform, [string] $AppName, [System.Diagnostics.Process] $Process)

    switch ($Platform) {
        'Windows' {
            $app = Get-Process -Name $AppName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($app) {
                $null = $app.CloseMainWindow()
                if (-not $app.WaitForExit(10000)) { $app.Kill($true) }
            }
        }
        'macOS' {
            & osascript -e "quit app `"$AppName`"" 2>$null
            Start-Sleep -Seconds 2
            & pkill -x $AppName 2>$null
        }
    }

    if (-not $Process.HasExited) { $Process.Kill($true) }
    $null = $Process.WaitForExit(10000)
}

function Invoke-SmokeRun {
    param([string] $AppName, [string] $Platform, [string] $ReleasesDir, [string] $OutputDir, [int] $TimeoutSeconds)

    $outputPath = (New-Item -ItemType Directory -Force -Path $OutputDir).FullName
    $stdoutPath = Join-Path $outputPath 'app-stdout.log'
    $stderrPath = Join-Path $outputPath 'app-stderr.log'
    $resultPath = Join-Path $outputPath 'result.json'
    $workDir = Join-Path (Get-Location) 'smoke-app'

    $target = Find-SmokeTarget -Platform $Platform -AppName $AppName -ReleasesDir $ReleasesDir -WorkDir $workDir
    $environment = Get-SmokeEnvironment -TimeoutSeconds $TimeoutSeconds -ResultPath $resultPath
    if ($Platform -eq 'Windows') {
        # Single-file extraction under %TEMP% trips Windows Defender on hosted runners.
        $extractDir = (New-Item -ItemType Directory -Force -Path (Join-Path (Get-Location) 'dotnet-extract')).FullName
        $environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = $extractDir
    }

    $plan = Get-SmokeLaunchPlan -Platform $Platform -TargetPath $target -StdoutPath $stdoutPath -StderrPath $stderrPath -Environment $environment
    Write-Output "Launching $target"
    $process = Start-SmokeProcess -Plan $plan -StdoutPath $stdoutPath -StderrPath $stderrPath -Environment $environment

    $deadline = $TimeoutSeconds + $script:CiGraceSeconds
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $mode = 'verdict'
    $timedOut = $false
    $legacyAlive = $false

    while (-not $process.HasExited) {
        if (-not $started -and (Test-SmokeStarted -LogPath $stdoutPath)) {
            $started = $true
            Write-Output 'The app printed HERMES_SMOKE_START; waiting for its verdict'
        }

        $elapsed = $stopwatch.Elapsed.TotalSeconds
        if (-not $started -and $elapsed -ge $script:SmokeStartWindowSeconds) {
            $mode = 'legacy'
            $legacyAlive = $true
            Write-Output "No HERMES_SMOKE_START after $($script:SmokeStartWindowSeconds)s; checking liveness only"
            Stop-SmokeApp -Platform $Platform -AppName $AppName -Process $process
            break
        }

        if ($elapsed -ge $deadline) {
            $timedOut = $true
            Write-Output "The app did not exit within ${deadline}s; stopping it"
            Stop-SmokeApp -Platform $Platform -AppName $AppName -Process $process
            break
        }

        Start-Sleep -Milliseconds 500
    }

    if (-not $started -and (Test-SmokeStarted -LogPath $stdoutPath)) {
        if ($mode -eq 'legacy') {
            # The start line was there but unreadable while the app ran; never pass a smoke-aware app on liveness.
            $mode = 'verdict'
            $timedOut = $true
            $legacyAlive = $false
        }
        $started = $true
    }

    if (-not $started -and $mode -eq 'verdict' -and -not $timedOut) {
        # Exited without ever printing the start line: a crash, judged by the legacy rules.
        $mode = 'legacy'
        $legacyAlive = $false
    }

    $exitCode = if ($Platform -eq 'macOS' -or $timedOut -or $mode -eq 'legacy') { $null } else { $process.ExitCode }

    [ordered]@{ mode = $mode; exitCode = $exitCode; timedOut = $timedOut; legacyAlive = $legacyAlive } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputPath 'run.json')

    Write-Output "Run finished: mode=$mode timedOut=$timedOut exitCode=$exitCode"
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Invoke-SmokeRun -AppName $AppName -Platform $Platform -ReleasesDir $ReleasesDir -OutputDir $OutputDir -TimeoutSeconds $TimeoutSeconds
}
