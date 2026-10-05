# Checks WSL probes without installing WSL or changing the machine.
param(
    [string] $StepsDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $StepsDirectory) {
    $StepsDirectory = Join-Path $PSScriptRoot '..\..\windows-dev-config\steps'
}
. (Join-Path $StepsDirectory '_environment.ps1')
. (Join-Path $StepsDirectory '_retry.ps1')
. (Join-Path $StepsDirectory 'wsl.ps1')
$nativeProcess = ${function:Invoke-DevConfigProcess}
$originalUtf8 = $env:WSL_UTF8
$passed = 0
$failed = 0

function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Check([string] $Name, [scriptblock] $Action) {
    try {
        & $Action
        Write-Host "PASS  $Name" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host "FAIL  ${Name}: $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
    }
}
function Reset-TestState([int] $Code = 0, [string] $Output = 'Ubuntu') {
    $script:Calls = @()
    $script:Code = $Code
    $script:Output = $Output
    $script:Missing = $false
    $script:ProcessFailure = $null
}
function Get-Command {
    [CmdletBinding()]
    param([string] $Name)
    Assert ($Name -eq 'wsl.exe') "Unexpected executable lookup: $Name"
    if (-not $script:Missing) { [pscustomobject]@{ Name = 'wsl.exe' } }
}
function Invoke-DevConfigProcess {
    param(
        $FilePath, $Arguments, $TimeoutSeconds, [switch] $NoNewWindow,
        $RedirectStandardOutput, $RedirectStandardError, $RedirectStandardInput
    )
    $script:Calls += [pscustomobject]@{
        FilePath = $FilePath
        Arguments = $Arguments -join ' '
        Timeout = $TimeoutSeconds
        NoNewWindow = [bool]$NoNewWindow
        InputPath = $RedirectStandardInput
        InputWasEmpty = ($RedirectStandardInput -and
            (Test-Path -LiteralPath $RedirectStandardInput) -and
            (Get-Item -LiteralPath $RedirectStandardInput).Length -eq 0)
        Paths = @($RedirectStandardInput, $RedirectStandardOutput, $RedirectStandardError) |
            Where-Object { $_ }
    }
    if ($script:ProcessFailure) { throw $script:ProcessFailure }
    if ($RedirectStandardOutput) {
        [IO.File]::WriteAllText($RedirectStandardOutput, $script:Output, [Text.Encoding]::UTF8)
    }
    return $script:Code
}
function Assert-Probe([string] $Arguments) {
    Assert ($script:Calls.Count -eq 1) 'Expected exactly one native query.'
    $call = $script:Calls[0]
    Assert ($call.FilePath -eq 'wsl.exe' -and $call.Arguments -eq $Arguments) 'Query arguments changed.'
    Assert ($call.InputWasEmpty) 'Query must receive an existing, empty stdin file.'
    Assert ($call.NoNewWindow -and $call.Timeout -eq 120) 'Query console or timeout behavior changed.'
    Assert (@($call.Paths).Count -eq 3) 'Query must redirect all three standard streams.'
    foreach ($path in $call.Paths) {
        Assert (-not (Test-Path -LiteralPath $path)) 'Query left a temporary file behind.'
    }
}

try {
    foreach ($code in @(0, 1)) {
        Check "Version exit code $code preserves readiness and closes stdin" {
            Reset-TestState -Code $code
            Assert ((Test-DevConfigWslRuntimeCurrent) -eq ($code -eq 0)) 'Wrong runtime readiness.'
            Assert-Probe '--version'
        }
    }
    foreach ($output in @('Ubuntu', "Debian`r`nUbuntu-24.04", " U`0b`0u`0n`0t`0u`0 `r`n")) {
        Check 'Ubuntu listing retains versioned, whitespace and NUL handling' {
            Reset-TestState -Output $output
            Assert (Test-DevConfigUbuntuInstalled) 'Installed Ubuntu was not recognized.'
            Assert-Probe '--list --quiet'
        }
    }
    foreach ($output in @('', 'Debian')) {
        Check 'Empty and non-Ubuntu listings remain not installed' {
            Reset-TestState -Output $output
            Assert (-not (Test-DevConfigUbuntuInstalled)) 'Listing falsely reported Ubuntu.'
            Assert-Probe '--list --quiet'
        }
    }
    Check 'Failed listing cannot report Ubuntu from its output' {
        Reset-TestState -Code 1 -Output 'Ubuntu'
        Assert (-not (Test-DevConfigUbuntuInstalled)) 'Nonzero exit code must fail readiness.'
        Assert-Probe '--list --quiet'
    }
    foreach ($query in @('Test-DevConfigWslRuntimeCurrent', 'Test-DevConfigUbuntuInstalled')) {
        Check "$query handles a missing executable without launching a process" {
            Reset-TestState
            $script:Missing = $true
            Assert (-not (& $query)) 'Missing WSL must not be ready.'
            Assert ($script:Calls.Count -eq 0) 'Missing WSL must not launch a process.'
        }
        foreach ($failure in @([InvalidOperationException]::new('Launch failed'), [TimeoutException]::new('Timed out'))) {
            Check "$query cleans up after $($failure.GetType().Name)" {
                Reset-TestState
                $script:ProcessFailure = $failure
                Assert (-not (& $query)) 'A failed query must not be ready.'
                Assert-Probe $(if ($query -eq 'Test-DevConfigWslRuntimeCurrent') { '--version' } else { '--list --quiet' })
            }
        }
    }
    Check 'Both update routes retain console input and their original timeouts' {
        Reset-TestState -Code 1
        Assert (-not (Update-DevConfigWslRuntime)) 'Failed updates must remain unsuccessful.'
        Assert (($script:Calls.Arguments -join ',') -eq '--update,--update --web-download') 'Update routes changed.'
        foreach ($call in $script:Calls) {
            Assert (-not $call.InputPath) 'Updates must not receive closed stdin.'
            Assert ($call.Timeout -eq 900 -and $call.NoNewWindow) 'Update process options changed.'
            foreach ($path in $call.Paths) {
                Assert (-not (Test-Path -LiteralPath $path)) 'Update left a temporary file behind.'
            }
        }
    }
    Check 'Platform and Ubuntu installs retain their separate consoles and input' {
        Reset-TestState
        Install-DevConfigWslComponents
        Invoke-DevConfigWslUbuntuInstall -Arguments @('--install', '-d', 'Ubuntu', '--no-launch')
        Assert ($script:Calls.Count -eq 3) 'Expected two installs and one readiness check.'
        foreach ($index in @(0, 2)) {
            $call = $script:Calls[$index]
            Assert (-not $call.InputPath -and -not $call.NoNewWindow) 'Install console behavior changed.'
            Assert ($call.Timeout -eq $(if ($index -eq 0) { 900 } else { 1200 })) 'Install timeout changed.'
        }
        Assert ($script:Calls[1].InputWasEmpty) 'Post-install readiness must still close stdin.'
    }
    foreach ($text in @('', 'probe-input')) {
        Check 'Native process helper forwards stdin and preserves the exit code' {
            $stdin = [IO.Path]::GetTempFileName()
            $stdout = [IO.Path]::GetTempFileName()
            $stderr = [IO.Path]::GetTempFileName()
            try {
                [IO.File]::WriteAllText($stdin, $text)
                $command = '[Console]::Out.Write("input:" + [Console]::In.ReadToEnd()); exit 7'
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
                $exitCode = & $nativeProcess -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
                    -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
                    -TimeoutSeconds 15 -NoNewWindow -RedirectStandardInput $stdin `
                    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
                Assert ($exitCode -eq 7) 'Native exit code was not preserved.'
                Assert ([IO.File]::ReadAllText($stdout) -eq "input:$text") 'Native stdin was not forwarded.'
                Assert ((Get-Item -LiteralPath $stderr).Length -eq 0) 'Native child reported an error.'
            } finally {
                Remove-Item -LiteralPath $stdin, $stdout, $stderr -Force
            }
        }
    }
} finally {
    $env:WSL_UTF8 = $originalUtf8
}
Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 }
