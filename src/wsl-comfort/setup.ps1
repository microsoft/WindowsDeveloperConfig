[CmdletBinding()]
param(
    [switch] $NonInteractive,
    [string] $Distro,
    [string[]] $BootstrapArgs = @()
)

& {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Replace main with the full signed payload commit SHA before release.
    $payloadRef = 'main'
    $baseUri = "https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/$payloadRef/wsl-comfort"
    $microsoftSignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'

    foreach ($scope in @('MachinePolicy', 'UserPolicy')) {
        $policy = Get-ExecutionPolicy -Scope $scope
        if ($policy -ne 'Undefined') {
            if ($policy -eq 'Restricted') {
                throw "Organization policy ($scope) requires $policy. Script execution is disabled; contact your administrator."
            }
            break
        }
    }

    # install.ps1 resumes from its own folder after the WSL reboot, so each run stages
    # into a new folder that later runs never change.
    $runName = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) +
        '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $target = Join-Path $env:LOCALAPPDATA "DevConfig\wsl-comfort\$runName"

    Write-Host ''
    Write-Host 'WSL Comfort setup' -ForegroundColor Cyan
    Write-Host "  Fetching '$payloadRef' from microsoft/WindowsDeveloperConfig..." -ForegroundColor DarkGray

    $ProgressPreference = 'SilentlyContinue'
    $null = New-Item -ItemType Directory -Path $target -Force
    $verified = $false
    try {
        foreach ($name in @('install.ps1', 'content-hashes.psd1')) {
            $path = Join-Path $target $name
            Invoke-WebRequest -Uri "$baseUri/$name" -OutFile $path -UseBasicParsing -TimeoutSec 60
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
                $signature.SignerCertificate.Subject -ne $microsoftSignerSubject) {
                throw "WSL Comfort $name failed Microsoft signature verification ($($signature.Status)). Setup was not started."
            }
        }

        $hashes = Microsoft.PowerShell.Utility\Import-PowerShellDataFile -LiteralPath (Join-Path $target 'content-hashes.psd1')
        $latin1 = [Text.Encoding]::GetEncoding(28591)
        foreach ($entry in $hashes.GetEnumerator()) {
            if ($entry.Key -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $entry.Key -match '\.(ps1|psd1)$') {
                throw "The WSL Comfort content manifest lists an unexpected file: '$($entry.Key)'. Setup was not started."
            }
            $path = Join-Path $target $entry.Key
            Invoke-WebRequest -Uri "$baseUri/$($entry.Key)" -OutFile $path -UseBasicParsing -TimeoutSec 60

            # Latin-1 maps each byte to one character, so this only drops the CR of each CRLF.
            $canonical = $latin1.GetBytes($latin1.GetString([IO.File]::ReadAllBytes($path)).Replace("`r`n", "`n"))
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $actual = ([BitConverter]::ToString($sha.ComputeHash($canonical))).Replace('-', '').ToLowerInvariant()
            } finally {
                $sha.Dispose()
            }
            if ($actual -ne ([string]$entry.Value).ToLowerInvariant()) {
                throw "WSL Comfort $($entry.Key) failed SHA-256 verification. Setup was not started."
            }
        }

        Get-ChildItem -LiteralPath $target -File | Unblock-File
        $verified = $true
    } finally {
        if (-not $verified) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "  Verified the signed payload. Ready in $target" -ForegroundColor DarkGray

    $quote = {
        param([string] $Value)
        "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'"
    }
    # The child can inherit incompatible built-in modules from another PowerShell edition.
    $command = '$env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"; & ' + (& $quote (Join-Path $target 'install.ps1'))
    if ($NonInteractive) { $command += ' -NonInteractive' }
    if ($Distro) { $command += ' -Distro ' + (& $quote $Distro) }
    if (@($BootstrapArgs).Count -gt 0) {
        $command += ' -BootstrapArgs @(' + ((@($BootstrapArgs) | ForEach-Object { & $quote $_ }) -join ', ') + ')'
    }

    $shell = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        # A 32-bit shell can't see the 64-bit wsl.exe.
        $shell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    }
    # Start-Process keeps the real console attached, which the prompts and wsl.exe need.
    $process = Start-Process -FilePath $shell -NoNewWindow -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-Command',
        ('"' + [regex]::Replace($command, '(\\*)"', '$1$1\"') + '"')
    )
    # The cached handle keeps ExitCode readable; -Wait would also wait on anything WSL leaves running.
    $null = $process.Handle
    $process.WaitForExit()

    # Throw rather than exit so the caller's window stays open.
    if ($process.ExitCode -ne 0) {
        throw "WSL Comfort setup finished with exit code $($process.ExitCode)."
    }
}
