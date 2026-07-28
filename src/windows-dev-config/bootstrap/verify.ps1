Set-StrictMode -Version Latest

function Test-SlipstreamTerminalConfiguration {
    $settingsPath = Get-SlipstreamTerminalSettingsPath
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        return $false
    }

    try {
        $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
        $clean = [regex]::Replace($raw, '/\*[\s\S]*?\*/', '')
        $clean = [regex]::Replace($clean, '(?m)^\s*//.*$', '')
        $settings = $clean | ConvertFrom-Json
        return $settings.profiles.defaults.font.face -eq 'Cascadia Mono NF' -and
            $settings.defaultProfile -eq '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    }
    catch {
        return $false
    }
}

function Test-SlipstreamOhMyPoshProfile {
    try {
        $pwsh = Get-SlipstreamSignedCommand `
            -Name pwsh.exe `
            -PublisherPattern 'O=Microsoft Corporation'
        $profileOutput = & $pwsh -NoLogo -NoProfile -Command '$PROFILE' 2>$null |
            Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or -not $profileOutput) {
            return $false
        }
        $profilePath = $profileOutput.ToString().Trim()
        return (Test-Path -LiteralPath $profilePath) -and
            [bool](Select-String `
                -LiteralPath $profilePath `
                -SimpleMatch '# Windows Developer Config: Oh My Posh' `
                -Quiet)
    }
    catch {
        return $false
    }
}

function Invoke-SlipstreamVerification {
    param(
        [Parameter(Mandatory)] [object] $State,
        [switch] $AllowUnsigned
    )

    Refresh-SlipstreamPath
    $failures = [System.Collections.Generic.List[string]]::new()
    $winget = Get-SlipstreamWinGetCommand
    if (-not $winget) {
        $failures.Add('winget.exe is unavailable')
    }
    else {
        $packages = Get-SlipstreamPackageManifest -PayloadRoot $State.payloadRoot
        foreach ($package in $packages.packages) {
            if (-not (Test-SlipstreamPackageInstalled -WinGetPath $winget -Id $package.id)) {
                $failures.Add("package missing: $($package.id)")
            }
            foreach ($command in @($package.verifyCommands)) {
                if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
                    $failures.Add("command missing: $command [$($package.id)]")
                }
            }
        }
    }

    $registry = Get-SlipstreamRegistryManifest -PayloadRoot $State.payloadRoot
    foreach ($entry in $registry.values) {
        if (-not (Test-SlipstreamRegistryValue -Entry $entry)) {
            $failures.Add("registry mismatch: $($entry.name)")
        }
    }

    if (-not (Test-SlipstreamWslPlatformReady)) {
        $failures.Add('WSL platform features are not active')
    }
    if (@(Get-SlipstreamWslDistros) -notcontains 'Ubuntu') {
        $failures.Add('Ubuntu is not registered with WSL')
    }
    if (-not (Test-SlipstreamCascadiaFonts)) {
        $failures.Add('Cascadia Nerd Fonts are not registered')
    }
    if (-not (Test-SlipstreamTerminalConfiguration)) {
        $failures.Add('Windows Terminal defaults are not configured')
    }
    if (-not (Test-SlipstreamOhMyPoshProfile)) {
        $failures.Add('Oh My Posh is not configured in the PowerShell 7 profile')
    }

    try {
        $dotnet = Get-SlipstreamSignedCommand `
            -Name dotnet.exe `
            -PublisherPattern 'O=Microsoft Corporation'
    }
    catch {
        $dotnet = $null
    }
    $templateOutput = if ($dotnet) {
        & $dotnet new list 2>&1
    }
    else {
        @()
    }
    if (-not $dotnet -or $LASTEXITCODE -ne 0 -or ($templateOutput -join "`n") -notmatch '(?i)winui') {
        $failures.Add('WinUI .NET templates are not installed')
    }

    try {
        Invoke-SlipstreamUserConfiguration `
            -State $State `
            -Mode Verify `
            -AllowUnsigned:$AllowUnsigned
    }
    catch {
        $failures.Add("limited-token Copilot verification failed: $($_.Exception.Message)")
    }

    if ($failures.Count -gt 0) {
        throw "Final verification failed:`n - $($failures -join "`n - ")"
    }

    $pendingReasons = @(Get-SlipstreamPendingRebootReasons)
    $alreadyRestarted = @($State.rebootHistory) -contains 'FinalVerification'
    if ($pendingReasons.Count -gt 0 -and -not $alreadyRestarted) {
        return New-SlipstreamPhaseResult `
            -RebootRequired `
            -AdvancePhase:$false `
            -Reason 'FinalVerification'
    }
    if ($pendingReasons.Count -gt 0) {
        Write-SlipstreamLog `
            -RunId $State.runId `
            -Level WARN `
            -Message "Restart markers remain after final restart and may be stale: $($pendingReasons -join ', ')"
    }

    Write-SlipstreamLog -RunId $State.runId -Message 'Final verification passed.'
    return New-SlipstreamPhaseResult
}
