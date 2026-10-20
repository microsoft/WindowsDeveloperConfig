<#
.SYNOPSIS
  Configures PSScriptAnalyzer settings for the VS Code PowerShell extension.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigPowerShellAnalyzerRuleNames = @(
    'PSAvoidDefaultValueSwitchParameter'
    'PSAvoidGlobalVars'
    'PSAvoidUsingCmdletAliases'
    'PSAvoidUsingComputerNameHardcoded'
    'PSAvoidUsingConvertToSecureStringWithPlainText'
    'PSAvoidUsingEmptyCatchBlock'
    'PSAvoidUsingInvokeExpression'
    'PSAvoidUsingPlainTextForPassword'
    'PSAvoidUsingPositionalParameters'
    'PSAvoidUsingUsernameAndPasswordParams'
    'PSAvoidUsingWMICmdlet'
    'PSAvoidUsingWriteHost'
    'PSDSCDscExamplesPresent'
    'PSDSCDscTestsPresent'
    'PSDSCReturnCorrectTypesForDSCFunctions'
    'PSDSCStandardDSCFunctionsInResource'
    'PSDSCUseIdenticalMandatoryParametersForDSC'
    'PSDSCUseIdenticalParametersForDSC'
    'PSMissingModuleManifestField'
    'PSProvideCommentHelp'
    'PSReservedCmdletChar'
    'PSReservedParams'
    'PSShouldProcess'
    'PSUseApprovedVerbs'
    'PSUseCmdletCorrectly'
    'PSUseDeclaredVarsMoreThanAssignments'
    'PSUsePSCredentialType'
    'PSUseShouldProcessForStateChangingFunctions'
    'PSUseSingularNouns'
    'PSUseSupportsShouldProcess'
)

function Get-DevConfigVSCodeUserDirectory {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw 'APPDATA is not set; VS Code user settings cannot be located.'
    }
    Join-Path $env:APPDATA 'Code\User'
}

function Get-DevConfigVSCodeSettingsPath {
    Join-Path (Get-DevConfigVSCodeUserDirectory) 'settings.json'
}

function Skip-DevConfigJsoncTrivia {
    param([string]$Text, [int]$Index)
    while ($Index -lt $Text.Length) {
        $char = $Text[$Index]
        $next = if ($Index + 1 -lt $Text.Length) { $Text[$Index + 1] } else { [char]0 }
        if ([char]::IsWhiteSpace($char)) {
            $Index++
        } elseif ($char -eq '/' -and $next -eq '/') {
            $end = $Text.IndexOfAny([char[]]"`r`n", $Index)
            $Index = if ($end -lt 0) { $Text.Length } else { $end }
        } elseif ($char -eq '/' -and $next -eq '*') {
            $end = $Text.IndexOf('*/', $Index + 2, [StringComparison]::Ordinal)
            if ($end -lt 0) {
                throw 'VS Code settings contain an unterminated block comment.'
            }
            $Index = $end + 2
        } else {
            break
        }
    }
    $Index
}

function Get-DevConfigJsoncStringEnd {
    param([string]$Text, [int]$Index)
    $Index++
    while ($Index -lt $Text.Length) {
        $Index = $Text.IndexOfAny([char[]]'\"', $Index)
        if ($Index -lt 0) {
            break
        }
        if ($Text[$Index] -eq '"') {
            return $Index + 1
        }
        $Index += 2
    }
    throw 'VS Code settings contain an unterminated string.'
}

function Get-DevConfigJsoncValueEnd {
    param([string]$Text, [int]$Index)
    if ($Index -ge $Text.Length) {
        throw 'VS Code settings end before a value.'
    }
    $char = $Text[$Index]
    if ($char -eq '"') {
        return Get-DevConfigJsoncStringEnd -Text $Text -Index $Index
    }
    if ($char -eq '{' -or $char -eq '[') {
        $depth = 0
        while ($Index -lt $Text.Length) {
            $Index = $Text.IndexOfAny([char[]]'"/{}[]', $Index)
            if ($Index -lt 0) {
                break
            }
            $char = $Text[$Index]
            if ($char -eq '"') {
                $Index = Get-DevConfigJsoncStringEnd -Text $Text -Index $Index
                continue
            }
            if ($char -eq '/') {
                $afterComment = Skip-DevConfigJsoncTrivia -Text $Text -Index $Index
                $Index = if ($afterComment -gt $Index) { $afterComment } else { $Index + 1 }
                continue
            }
            $depth += if ($char -eq '{' -or $char -eq '[') { 1 } else { -1 }
            $Index++
            if ($depth -eq 0) {
                return $Index
            }
        }
        throw 'VS Code settings contain an unterminated object or array.'
    }
    $end = $Text.IndexOfAny([char[]]",}]/ `t`r`n", $Index)
    if ($end -lt 0) {
        $end = $Text.Length
    }
    if ($end -eq $Index) {
        throw "VS Code settings contain an unexpected '$char'."
    }
    $end
}

function Get-DevConfigJsoncObjectLayout {
    param([string]$Text)
    $index = Skip-DevConfigJsoncTrivia -Text $Text -Index 0
    if ($index -ge $Text.Length) {
        return $null
    }
    if ($Text[$index] -ne '{') {
        throw 'VS Code settings must contain a JSON object.'
    }
    $open = $index
    $properties = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $first = $null
    $last = $null
    $index = Skip-DevConfigJsoncTrivia -Text $Text -Index ($index + 1)
    while ($index -lt $Text.Length -and $Text[$index] -ne '}') {
        if ($Text[$index] -ne '"') {
            throw "VS Code settings contain an unexpected '$($Text[$index])'."
        }
        $nameStart = $index
        $nameEnd = Get-DevConfigJsoncStringEnd -Text $Text -Index $nameStart
        $name = $Text.Substring($nameStart + 1, $nameEnd - $nameStart - 2)
        if ($name.Contains('\')) {
            $name = [regex]::Unescape($name)
        }
        $index = Skip-DevConfigJsoncTrivia -Text $Text -Index $nameEnd
        if ($index -ge $Text.Length -or $Text[$index] -ne ':') {
            throw "VS Code settings are missing ':' after '$name'."
        }
        $valueStart = Skip-DevConfigJsoncTrivia -Text $Text -Index ($index + 1)
        $valueEnd = Get-DevConfigJsoncValueEnd -Text $Text -Index $valueStart
        $last = [pscustomobject]@{
            NameStart  = $nameStart
            ValueStart = $valueStart
            ValueEnd   = $valueEnd
            CommaIndex = -1
        }
        if ($null -eq $first) {
            $first = $last
        }
        $properties[$name] = $last
        $index = Skip-DevConfigJsoncTrivia -Text $Text -Index $valueEnd
        if ($index -lt $Text.Length -and $Text[$index] -eq ',') {
            $last.CommaIndex = $index
            $index = Skip-DevConfigJsoncTrivia -Text $Text -Index ($index + 1)
        } elseif ($index -lt $Text.Length -and $Text[$index] -ne '}') {
            throw "VS Code settings are missing ',' after '$name'."
        }
    }
    if ($index -ge $Text.Length) {
        throw 'VS Code settings contain an unterminated object.'
    }
    if ((Skip-DevConfigJsoncTrivia -Text $Text -Index ($index + 1)) -lt $Text.Length) {
        throw 'VS Code settings contain text after the top-level object.'
    }
    [pscustomobject]@{
        Open       = $open
        Close      = $index
        Properties = $properties
        First      = $first
        Last       = $last
    }
}

function Read-DevConfigVSCodeSettings {
    $path = Get-DevConfigVSCodeSettingsPath
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{}
    }
    $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if ($null -eq (Get-DevConfigJsoncObjectLayout -Text $content)) {
        return [ordered]@{}
    }
    # PowerShell 7 accepts the comments and trailing commas VS Code allows in settings.json.
    ConvertFrom-Json -InputObject $content -AsHashtable -ErrorAction Stop
}

# Edits only the requested top-level values in place so comments and formatting elsewhere survive.
function Set-DevConfigVSCodeSettingValues {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $path = Get-DevConfigVSCodeSettingsPath
    $text = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -ErrorAction Stop } else { '' }
    if ($null -eq $text) {
        $text = ''
    }
    $layout = Get-DevConfigJsoncObjectLayout -Text $text
    $newLine = if ($text.Contains("`r`n")) { "`r`n" } elseif ($text.Contains("`n")) { "`n" } else { [Environment]::NewLine }
    $indent = '    '
    if ($layout -and $layout.First) {
        $lineStart = $text.LastIndexOfAny([char[]]"`r`n", $layout.First.NameStart) + 1
        $leading = $text.Substring($lineStart, $layout.First.NameStart - $lineStart)
        if ($leading.Length -gt 0 -and [string]::IsNullOrWhiteSpace($leading)) {
            $indent = $leading
        }
    }

    $edits = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Values.Keys) {
        $json = ConvertTo-Json -InputObject $Values[$name] -Compress
        if ($layout -and $layout.Properties.ContainsKey($name)) {
            $property = $layout.Properties[$name]
            $length = $property.ValueEnd - $property.ValueStart
            if ($text.Substring($property.ValueStart, $length) -cne $json) {
                $edits.Add([pscustomobject]@{ Start = $property.ValueStart; Length = $length; Text = $json })
            }
        } else {
            $missing.Add("$(ConvertTo-Json -InputObject ([string]$name) -Compress): $json")
        }
    }

    if ($null -eq $layout) {
        $body = ($missing | ForEach-Object { $indent + $_ }) -join (',' + $newLine)
        $object = '{' + $newLine + $body + $newLine + '}' + $newLine
        $prefix = $text.TrimEnd()
        $newText = if ($prefix) { $prefix + $newLine + $object } else { $object }
    } else {
        if ($missing.Count -gt 0) {
            $body = $newLine + $indent + ($missing -join (',' + $newLine + $indent))
            $last = $layout.Last
            if ($null -eq $last) {
                $interiorStart = $layout.Open + 1
                $interior = $text.Substring($interiorStart, $layout.Close - $interiorStart)
                if ([string]::IsNullOrWhiteSpace($interior)) {
                    $edits.Add([pscustomobject]@{ Start = $interiorStart; Length = $interior.Length; Text = $body + $newLine })
                } else {
                    $edits.Add([pscustomobject]@{ Start = $interiorStart; Length = 0; Text = $body })
                }
            } else {
                $anchor = $last.ValueEnd
                if ($last.CommaIndex -ge 0) {
                    $anchor = $last.CommaIndex + 1
                    $body += ','
                } else {
                    $edits.Add([pscustomobject]@{ Start = $last.ValueEnd; Length = 0; Text = ',' })
                }
                # Keep a trailing same-line comment attached to the property it annotates.
                $insertAt = $anchor
                $lineEnd = $text.IndexOfAny([char[]]"`r`n", $anchor)
                if ($lineEnd -ge 0 -and $lineEnd -lt $layout.Close) {
                    $rest = $text.Substring($anchor, $lineEnd - $anchor)
                    $restIsTrivia = try { (Skip-DevConfigJsoncTrivia -Text $rest -Index 0) -eq $rest.Length } catch { $false }
                    if ($restIsTrivia) {
                        $insertAt = $lineEnd
                    }
                }
                $edits.Add([pscustomobject]@{ Start = $insertAt; Length = 0; Text = $body })
            }
        }
        $newText = $text
        # Apply from the end so offsets stay valid; same-offset edits apply last-added first.
        $sortedEdits = @($edits | Sort-Object -Property Start -Stable)
        for ($i = $sortedEdits.Count - 1; $i -ge 0; $i--) {
            $edit = $sortedEdits[$i]
            $newText = $newText.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Text)
        }
    }

    if ($newText -ceq $text) {
        return
    }
    $null = Get-DevConfigJsoncObjectLayout -Text $newText
    $null = ConvertFrom-Json -InputObject $newText -AsHashtable -ErrorAction Stop
    Set-Content -LiteralPath $path -Value $newText -NoNewline -Encoding utf8 -ErrorAction Stop
}

function Test-DevConfigPowerShellAnalyzerSettings {
    $userDirectory = Get-DevConfigVSCodeUserDirectory
    $settings = Read-DevConfigVSCodeSettings
    $analyzerSettingsPath = Join-Path $userDirectory 'PSScriptAnalyzerSettings.psd1'
    if ($settings['powershell.scriptAnalysis.enable'] -ne $true -or
        $settings['powershell.scriptAnalysis.settingsPath'] -ne $analyzerSettingsPath -or
        -not (Test-Path -LiteralPath $analyzerSettingsPath)) {
        return $false
    }

    $analyzerSettings = Import-PowerShellDataFile -LiteralPath $analyzerSettingsPath -ErrorAction Stop
    if ($analyzerSettings.IncludeDefaultRules -ne $true) {
        return $false
    }
    foreach ($ruleName in $Script:DevConfigPowerShellAnalyzerRuleNames) {
        if ($ruleName -notin $analyzerSettings.IncludeRules) {
            return $false
        }
    }
    return $true
}

function Set-DevConfigPowerShellAnalyzerSettings {
    $userDirectory = Get-DevConfigVSCodeUserDirectory
    New-Item -ItemType Directory -Path $userDirectory -Force | Out-Null
    $analyzerSettingsPath = Join-Path $userDirectory 'PSScriptAnalyzerSettings.psd1'
    $lines = @(
        '@{'
        '    IncludeDefaultRules = $true'
        '    IncludeRules = @('
        foreach ($ruleName in $Script:DevConfigPowerShellAnalyzerRuleNames) {
            "        '$ruleName'"
        }
        '    )'
        '}'
    )
    Set-Content -LiteralPath $analyzerSettingsPath -Value ($lines -join [Environment]::NewLine) -Encoding utf8 -ErrorAction Stop

    Set-DevConfigVSCodeSettingValues -Values ([ordered]@{
            'powershell.scriptAnalysis.enable'       = $true
            'powershell.scriptAnalysis.settingsPath' = $analyzerSettingsPath
        })

    if (-not (Test-DevConfigPowerShellAnalyzerSettings)) {
        throw 'The VS Code PowerShell analyzer settings did not reach the desired state.'
    }
}

function Invoke-PowerShellAnalyzerPhase {
    Show-DevConfigPhaseHeader
    $steps = @(
        New-DevConfigStep -Name 'PowerShellAnalyzerSettings' -Description 'Configure PSScriptAnalyzer in VS Code.' `
            -Check { Test-DevConfigPowerShellAnalyzerSettings } `
            -Apply { Set-DevConfigPowerShellAnalyzerSettings }
    )
    Invoke-DevConfigSteps -Steps $steps
}
