Set-StrictMode -Version Latest

function Get-SlipstreamPackageManifest {
    param([Parameter(Mandatory)] [string] $PayloadRoot)

    return Get-Content `
        -LiteralPath (Join-Path $PayloadRoot 'config\packages.json') `
        -Raw `
        -Encoding UTF8 | ConvertFrom-Json
}

function Get-SlipstreamRegistryManifest {
    param([Parameter(Mandatory)] [string] $PayloadRoot)

    return Get-Content `
        -LiteralPath (Join-Path $PayloadRoot 'config\registry.json') `
        -Raw `
        -Encoding UTF8 | ConvertFrom-Json
}

function Test-SlipstreamPackageInstalled {
    param(
        [Parameter(Mandatory)] [string] $WinGetPath,
        [Parameter(Mandatory)] [string] $Id
    )

    $output = & $WinGetPath list `
        --id $Id `
        --exact `
        --disable-interactivity `
        --accept-source-agreements 2>&1
    $exitCode = $LASTEXITCODE
    return $exitCode -eq 0 -and (($output -join "`n") -match [regex]::Escape($Id))
}

function Install-SlipstreamPackage {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [object] $Package
    )

    $winget = Get-SlipstreamWinGetCommand
    if (-not $winget) {
        throw 'winget.exe disappeared after platform repair.'
    }

    if (Test-SlipstreamPackageInstalled -WinGetPath $winget -Id $Package.id) {
        Write-SlipstreamLog `
            -RunId $State.runId `
            -Message "Package already installed: $($Package.name) [$($Package.id)]"
        return New-SlipstreamPhaseResult
    }

    $arguments = @(
        'install',
        '--id', $Package.id,
        '--exact',
        '--source', $Package.source,
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($Package.PSObject.Properties.Name -contains 'scope' -and $Package.scope) {
        $arguments += @('--scope', $Package.scope)
    }
    if ($Package.PSObject.Properties.Name -contains 'arguments' -and $Package.arguments) {
        $arguments += @($Package.arguments)
    }

    $result = Invoke-SlipstreamNative `
        -RunId $State.runId `
        -FilePath $winget `
        -ArgumentList $arguments `
        -Name "Install $($Package.name)" `
        -MaxAttempts 3 `
        -AllowAnyExitCode

    $rebootCodes = @(
        '0x00000669',
        '0x00000BC2',
        '0x8A150109',
        '0x8A15010A',
        '0x8A15010B'
    )
    if ($result.ExitCodeHex -in $rebootCodes) {
        return New-SlipstreamPhaseResult `
            -RebootRequired `
            -AdvancePhase:$false `
            -Reason "Package:$($Package.id)"
    }
    if ($result.ExitCode -ne 0) {
        throw "WinGet failed to install $($Package.id): $($result.ExitCodeHex)"
    }

    return New-SlipstreamPhaseResult
}

function Install-SlipstreamPackages {
    param([Parameter(Mandatory)] [object] $State)

    $manifest = Get-SlipstreamPackageManifest -PayloadRoot $State.payloadRoot
    foreach ($package in $manifest.packages) {
        $result = Install-SlipstreamPackage -State $State -Package $package
        if ($result.RebootRequired) {
            return $result
        }
    }

    Refresh-SlipstreamPath
    return New-SlipstreamPhaseResult
}

function Test-SlipstreamRegistryValue {
    param([Parameter(Mandatory)] [object] $Entry)

    $path = ConvertTo-SlipstreamRegistryPath -Path $Entry.path
    $current = Get-ItemPropertyValue `
        -LiteralPath $path `
        -Name $Entry.valueName `
        -ErrorAction SilentlyContinue
    if ($null -eq $current) {
        return $false
    }

    if ($Entry.type -eq 'DWord') {
        return [int64]$current -eq [int64]$Entry.value
    }
    return [string]$current -ceq [string]$Entry.value
}

function Set-SlipstreamRegistryValue {
    param(
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [object] $Entry
    )

    if (Test-SlipstreamRegistryValue -Entry $Entry) {
        Write-SlipstreamLog -RunId $RunId -Message "Registry already configured: $($Entry.name)"
        return
    }

    $path = ConvertTo-SlipstreamRegistryPath -Path $Entry.path
    New-Item -Path $path -Force | Out-Null
    New-ItemProperty `
        -LiteralPath $path `
        -Name $Entry.valueName `
        -Value $Entry.value `
        -PropertyType $Entry.type `
        -Force | Out-Null

    if (-not (Test-SlipstreamRegistryValue -Entry $Entry)) {
        throw "Registry verification failed: $($Entry.name)"
    }
    Write-SlipstreamLog -RunId $RunId -Message "Configured registry: $($Entry.name)"
}

function Set-SlipstreamRegistryConfiguration {
    param([Parameter(Mandatory)] [object] $State)

    $manifest = Get-SlipstreamRegistryManifest -PayloadRoot $State.payloadRoot
    foreach ($entry in $manifest.values) {
        Set-SlipstreamRegistryValue -RunId $State.runId -Entry $entry
    }

    $rundll32 = Join-Path $env:SystemRoot 'System32\rundll32.exe'
    & $rundll32 user32.dll,UpdatePerUserSystemParameters 1, $true 2>$null
    Write-SlipstreamLog -RunId $State.runId -Message 'Broadcast the per-user settings refresh.'
}

function Test-SlipstreamCascadiaFonts {
    $fontsDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $fontNames = @('CascadiaCodeNF.ttf', 'CascadiaMonoNF.ttf')
    $registryPath = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $registryItem = Get-ItemProperty $registryPath -ErrorAction SilentlyContinue
    $registryValues = if ($registryItem) {
        @($registryItem.PSObject.Properties |
            Where-Object Name -notin @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') |
            ForEach-Object Value)
    }
    else {
        @()
    }

    foreach ($fontName in $fontNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $fontsDirectory $fontName))) {
            return $false
        }
        if (-not ($registryValues | Where-Object { $_ -like "*\$fontName" })) {
            return $false
        }
    }
    return $true
}

function Install-SlipstreamCascadiaFonts {
    param([Parameter(Mandatory)] [object] $State)

    if (Test-SlipstreamCascadiaFonts) {
        Write-SlipstreamLog -RunId $State.runId -Message 'Cascadia Nerd Fonts are already installed.'
        return
    }

    $version = '2407.24'
    $fontNames = @('CascadiaCodeNF.ttf', 'CascadiaMonoNF.ttf')
    $uri = "https://github.com/microsoft/cascadia-code/releases/download/v$version/CascadiaCode-$version.zip"
    $workDirectory = Join-Path $env:TEMP "WindowsDeveloperConfig-Cascadia-$version"
    $zipPath = Join-Path $workDirectory 'CascadiaCode.zip'
    $fontsDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $registryPath = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $fontsDirectory -Force | Out-Null
    New-Item -Path $registryPath -Force | Out-Null
    try {
        Get-SlipstreamDownload `
            -State $State `
            -Uri $uri `
            -Destination $zipPath `
            -Sha256 'E67A68EE3386DB63F48B9054BD196EA752BC6A4EBB4DF35ADCE6733DA50C8474'

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -AssemblyName System.Drawing
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($fontName in $fontNames) {
                $entry = $archive.Entries |
                    Where-Object Name -eq $fontName |
                    Select-Object -First 1
                if (-not $entry) {
                    throw "$fontName is missing from Cascadia Code $version."
                }

                $destination = Join-Path $fontsDirectory $fontName
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
                    $entry,
                    $destination,
                    $true
                )

                $collection = New-Object System.Drawing.Text.PrivateFontCollection
                try {
                    $collection.AddFontFile($destination)
                    $family = $collection.Families[0].Name
                }
                finally {
                    $collection.Dispose()
                }
                New-ItemProperty `
                    -Path $registryPath `
                    -Name "$family (TrueType)" `
                    -Value $destination `
                    -PropertyType String `
                    -Force | Out-Null
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        if (Test-Path -LiteralPath $workDirectory) {
            Remove-Item -LiteralPath $workDirectory -Recurse -Force
        }
    }

    if (-not (Test-SlipstreamCascadiaFonts)) {
        throw 'Cascadia Nerd Font verification failed.'
    }
    Write-SlipstreamLog -RunId $State.runId -Message 'Installed Cascadia Code and Mono Nerd Fonts.'
}

function Add-SlipstreamProperty {
    param(
        [Parameter(Mandatory)] [object] $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [object] $Value
    )

    if ($InputObject.PSObject.Properties.Name -notcontains $Name) {
        $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
    elseif ($null -eq $InputObject.$Name) {
        $InputObject.$Name = $Value
    }
}

function Get-SlipstreamTerminalSettingsPath {
    $package = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($package) {
        return Join-Path `
            (Join-Path $env:LOCALAPPDATA "Packages\$($package.PackageFamilyName)\LocalState") `
            'settings.json'
    }

    return Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
}

function Set-SlipstreamTerminalSettings {
    param([Parameter(Mandatory)] [object] $State)

    $settingsPath = Get-SlipstreamTerminalSettingsPath
    $settingsDirectory = Split-Path -Parent $settingsPath
    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null

    $raw = '{}'
    if (Test-Path -LiteralPath $settingsPath) {
        Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.slipstream.bak" -Force
        $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
    }
    $clean = [regex]::Replace($raw, '/\*[\s\S]*?\*/', '')
    $clean = [regex]::Replace($clean, '(?m)^\s*//.*$', '')
    $clean = [regex]::Replace($clean, ',\s*([}\]])', '$1')
    if ([string]::IsNullOrWhiteSpace($clean)) {
        $clean = '{}'
    }
    $settings = $clean | ConvertFrom-Json

    Add-SlipstreamProperty -InputObject $settings -Name profiles -Value ([pscustomobject]@{})
    Add-SlipstreamProperty -InputObject $settings.profiles -Name defaults -Value ([pscustomobject]@{})
    Add-SlipstreamProperty -InputObject $settings.profiles.defaults -Name font -Value ([pscustomobject]@{})
    Add-SlipstreamProperty `
        -InputObject $settings.profiles.defaults.font `
        -Name face `
        -Value 'Cascadia Mono NF'
    $settings.profiles.defaults.font.face = 'Cascadia Mono NF'

    $powerShellProfileGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    Add-SlipstreamProperty `
        -InputObject $settings `
        -Name defaultProfile `
        -Value $powerShellProfileGuid
    $settings.defaultProfile = $powerShellProfileGuid

    $settings | ConvertTo-Json -Depth 32 |
        Set-Content -LiteralPath $settingsPath -Encoding UTF8
    Write-SlipstreamLog -RunId $State.runId -Message "Configured Windows Terminal: $settingsPath"
}

function Set-SlipstreamCopilotTerminalProfile {
    param([Parameter(Mandatory)] [object] $State)

    $fragmentsDirectory = Join-Path `
        $env:LOCALAPPDATA `
        'Microsoft\Windows Terminal\Fragments\WindowsDeveloperConfig'
    New-Item -ItemType Directory -Path $fragmentsDirectory -Force | Out-Null

    $fragment = [ordered]@{
        profiles = @(
            [ordered]@{
                guid = '{b1a4d2c8-6f3e-4a7b-9e2d-1c8f5a3b7d91}'
                name = 'GitHub Copilot'
                commandline = 'pwsh.exe -NoExit -Command "copilot"'
                startingDirectory = '%USERPROFILE%'
                hidden = $false
                tabTitle = 'Copilot'
            }
        )
    }
    $fragmentPath = Join-Path $fragmentsDirectory 'github-copilot.fragment.json'
    $fragment | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $fragmentPath -Encoding UTF8
    Write-SlipstreamLog -RunId $State.runId -Message "Created GitHub Copilot Terminal profile: $fragmentPath"
}

function Set-SlipstreamOhMyPoshProfile {
    param([Parameter(Mandatory)] [object] $State)

    $pwsh = Get-SlipstreamSignedCommand `
        -Name pwsh.exe `
        -PublisherPattern 'O=Microsoft Corporation'
    $profileOutput = & $pwsh -NoLogo -NoProfile -Command '$PROFILE' 2>$null |
        Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or -not $profileOutput) {
        throw 'Unable to resolve the PowerShell 7 profile path.'
    }
    $profilePath = $profileOutput.ToString().Trim()

    $marker = '# Windows Developer Config: Oh My Posh'
    $existing = if (Test-Path -LiteralPath $profilePath) {
        Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8
    } else {
        ''
    }
    if ($existing -match [regex]::Escape($marker)) {
        Write-SlipstreamLog -RunId $State.runId -Message 'Oh My Posh is already configured in the PowerShell 7 profile.'
        return
    }

    $profileDirectory = Split-Path -Parent $profilePath
    New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
    $block = @"

$marker
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    oh-my-posh init pwsh | Invoke-Expression
}
"@
    [System.IO.File]::AppendAllText(
        $profilePath,
        $block,
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-SlipstreamLog -RunId $State.runId -Message "Configured Oh My Posh in $profilePath"
}

function Install-SlipstreamWinUiTemplates {
    param([Parameter(Mandatory)] [object] $State)

    $dotnet = Get-SlipstreamSignedCommand `
        -Name dotnet.exe `
        -PublisherPattern 'O=Microsoft Corporation'
    $output = & $dotnet new list 2>&1
    if ($LASTEXITCODE -eq 0 -and ($output -join "`n") -match '(?i)winui') {
        Write-SlipstreamLog -RunId $State.runId -Message 'WinUI .NET templates are already installed.'
        return
    }

    Invoke-SlipstreamNative `
        -RunId $State.runId `
        -FilePath $dotnet `
        -ArgumentList @('new', 'install', 'Microsoft.WindowsAppSDK.WinUI.CSharp.Templates') `
        -Name 'Install WinUI .NET templates' | Out-Null
}

function Invoke-SlipstreamComplexConfiguration {
    param(
        [Parameter(Mandatory)] [object] $State,
        [switch] $AllowUnsigned
    )

    Install-SlipstreamCascadiaFonts -State $State
    Set-SlipstreamTerminalSettings -State $State
    Set-SlipstreamCopilotTerminalProfile -State $State
    Set-SlipstreamOhMyPoshProfile -State $State
    Install-SlipstreamWinUiTemplates -State $State
    Invoke-SlipstreamUserConfiguration `
        -State $State `
        -AllowUnsigned:$AllowUnsigned
}

function Invoke-SlipstreamDesiredState {
    param(
        [Parameter(Mandatory)] [object] $State,
        [switch] $AllowUnsigned
    )

    $packageResult = Install-SlipstreamPackages -State $State
    if ($packageResult.RebootRequired) {
        return $packageResult
    }

    Set-SlipstreamRegistryConfiguration -State $State
    Invoke-SlipstreamComplexConfiguration `
        -State $State `
        -AllowUnsigned:$AllowUnsigned
    return New-SlipstreamPhaseResult
}
