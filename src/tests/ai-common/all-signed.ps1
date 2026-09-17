$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'ALL_SIGNED_SKIPPED: Windows only'
    return
}

function Get-TestPowerShellHosts {
    $hosts = @((Get-Command 'powershell.exe' -ErrorAction Stop).Source)
    $pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($pwsh) {
        $pwshPath = $pwsh.Source
        if ($pwshPath -like "$env:LOCALAPPDATA\Microsoft\WindowsApps\*") {
            $package = Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction SilentlyContinue |
                Sort-Object Version -Descending |
                Select-Object -First 1
            if ($package) {
                $packagedPwsh = Join-Path $package.InstallLocation 'pwsh.exe'
                if (Test-Path -LiteralPath $packagedPwsh) {
                    $pwshPath = $packagedPwsh
                }
            }
        }
        if ((Test-Path -LiteralPath $pwshPath) -and $pwshPath -notin $hosts) {
            $hosts += $pwshPath
        }
    }
    return $hosts
}

function Invoke-AllSignedProcess {
    param(
        [Parameter(Mandatory)] [string] $Shell,
        [Parameter(Mandatory)] [string] $Script,
        [string[]] $Arguments = @(),
        [int] $PublisherConsentCount = 0
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Shell
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $nativeArguments = @('-NoProfile', '-ExecutionPolicy', 'AllSigned', '-File', $Script) + $Arguments
    $startInfo.Arguments = ($nativeArguments | ForEach-Object {
        '"' + ([string]$_).Replace('"', '\"') + '"'
    }) -join ' '

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start '$Shell'."
        }
        for ($index = 0; $index -lt $PublisherConsentCount; $index++) {
            $process.StandardInput.WriteLine('R')
        }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill()
            throw "$Shell AllSigned validation timed out for '$Script'."
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = ($stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()).Trim()
        }
    } finally {
        $process.Dispose()
    }
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$sourceRoot = Join-Path $repositoryRoot 'src\Workloads'
$releaseRoot = Join-Path $repositoryRoot 'Workloads'
$flows = @('cuda', 'rocm', 'intel-ai', 'foundry', 'pytorch', 'local-ai', 'llama.cpp', 'ollama')
$shells = @(Get-TestPowerShellHosts)
$microsoftSignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'

$pipeline = Get-Content -LiteralPath (Join-Path $repositoryRoot '.pipelines\OneBranch.SignAndPackage.yml') -Raw
if ($pipeline -notmatch 'files_to_sign:\s*src/\*\*/\*\.ps1' -or
    $pipeline -notmatch 'src/Workloads/\*\*') {
    throw 'The release pipeline no longer signs src/**/*.ps1 and packages src/Workloads/**.'
}

foreach ($shell in $shells) {
    $shellName = [System.IO.Path]::GetFileNameWithoutExtension($shell)
    $unsigned = Join-Path $sourceRoot 'cuda\install.ps1'
    $unsignedResult = Invoke-AllSignedProcess `
        -Shell $shell `
        -Script $unsigned `
        -Arguments @('-PlanOnly', '-ReportPath', (Join-Path $env:TEMP "$shellName-unsigned-ai.json"))
    if ($unsignedResult.ExitCode -eq 0 -or
        $unsignedResult.Output -notmatch '(?i)(not digitally signed|cannot be loaded)') {
        throw "$shellName did not enforce AllSigned for unsigned AI source: $($unsignedResult.Output)"
    }

    $signedProbe = Get-ChildItem -LiteralPath $releaseRoot -Recurse -Filter 'install.ps1' |
        Where-Object { (Get-AuthenticodeSignature -LiteralPath $_.FullName).Status -eq 'Valid' } |
        Select-Object -First 1
    if (-not $signedProbe) {
        throw 'No Microsoft-signed release workload was available for the AllSigned host contract probe.'
    }
    $probeSignature = Get-AuthenticodeSignature -LiteralPath $signedProbe.FullName
    if ($probeSignature.SignerCertificate.Subject -ne $microsoftSignerSubject) {
        throw "Signed release probe has unexpected signer '$($probeSignature.SignerCertificate.Subject)'."
    }
    $probeResult = Invoke-AllSignedProcess `
        -Shell $shell `
        -Script $signedProbe.FullName `
        -Arguments @('-?') `
        -PublisherConsentCount 4
    if ($probeResult.ExitCode -ne 0) {
        throw "$shellName could not load a valid Microsoft-signed release workload under AllSigned: $($probeResult.Output)"
    }
}

$missingReleaseFlows = @($flows | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $releaseRoot "$_\install.ps1"))
})
if ($missingReleaseFlows.Count -gt 0) {
    Write-Host "ALL_SIGNED_RELEASE_PENDING: sign cycle must publish $($missingReleaseFlows -join ', ')"
} else {
    $signedScope = @(
        Get-ChildItem -LiteralPath (Join-Path $releaseRoot '_common') -File -Filter '*.ps1'
        foreach ($flow in $flows) {
            Get-ChildItem -LiteralPath (Join-Path $releaseRoot $flow) -File -Filter '*.ps1'
        }
    )
    foreach ($script in $signedScope) {
        $signature = Get-AuthenticodeSignature -LiteralPath $script.FullName
        if ($signature.Status -ne 'Valid' -or
            $signature.SignerCertificate.Subject -ne $microsoftSignerSubject) {
            throw "Signed AI release file failed Microsoft signature validation: '$($script.FullName)' [$($signature.Status)]."
        }
    }

    foreach ($shell in $shells) {
        $shellName = [System.IO.Path]::GetFileNameWithoutExtension($shell)
        foreach ($flow in $flows) {
            $reportPath = Join-Path $env:TEMP "$shellName-$flow-all-signed.json"
            $result = Invoke-AllSignedProcess `
                -Shell $shell `
                -Script (Join-Path $releaseRoot "$flow\install.ps1") `
                -Arguments @('-PlanOnly', '-ReportPath', $reportPath) `
                -PublisherConsentCount 64
            if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $reportPath)) {
                throw "$shellName AllSigned launch failed for signed $flow release: $($result.Output)"
            }
        }
    }
    Write-Host "ALL_SIGNED_RELEASE_OK: $($flows.Count) AI flows in $($shells.Count) PowerShell host(s)"
}

Write-Host "ALL_SIGNED_CONTRACT_OK: unsigned source rejected and signed release accepted in $($shells.Count) PowerShell host(s)"
