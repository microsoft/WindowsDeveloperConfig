$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-AiGpuInventory {
    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match '^PCI\\' -and $_.Name -notmatch '(?i)\bNPU\b' })
    return @($controllers | ForEach-Object {
        $vendor = if ($_.PNPDeviceID -match 'VEN_10DE' -or $_.Name -match 'NVIDIA') {
            'NVIDIA'
        } elseif ($_.PNPDeviceID -match 'VEN_1002' -or $_.Name -match 'AMD|Radeon') {
            'AMD'
        } elseif ($_.PNPDeviceID -match 'VEN_8086' -or $_.Name -match 'Intel') {
            'Intel'
        } elseif ($_.PNPDeviceID -match 'VEN_17CB' -or $_.Name -match 'Qualcomm|Adreno') {
            'Qualcomm'
        } else {
            'Unknown'
        }
        [ordered]@{
            vendor = $vendor
            name = $_.Name
            pnpDeviceId = $_.PNPDeviceID
            driverVersion = $_.DriverVersion
        }
    })
}

function Get-AiNpuInventory {
    return @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match '(?i)(\bNPU\b|AI Boost|Neural Processing)' } |
        ForEach-Object {
            [ordered]@{
                name = $_.FriendlyName
                instanceId = $_.InstanceId
                status = $_.Status
            }
        })
}

function New-AiWorkloadReport {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [hashtable] $Request = @{}
    )
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    return [ordered]@{
        schemaVersion = 1
        workload = $Id
        startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        completedAtUtc = $null
        host = [ordered]@{
            os = $os.Caption
            osVersion = $os.Version
            osBuild = $os.BuildNumber
            architecture = (Get-DevConfigArchitecture)
            powershell = $PSVersionTable.PSVersion.ToString()
            gpus = @(Get-AiGpuInventory)
            npus = @(Get-AiNpuInventory)
        }
        request = $Request
        acquisitions = [System.Collections.ArrayList]::new()
        phases = [System.Collections.ArrayList]::new()
        acceptance = [ordered]@{}
        result = [ordered]@{
            ready = $false
            planOnly = [bool]$(if ($Request.ContainsKey('PlanOnly')) { $Request.PlanOnly } else { $false })
            fallbackUsed = $false
            warnings = [System.Collections.ArrayList]::new()
            blockers = [System.Collections.ArrayList]::new()
        }
    }
}

function Add-AiReportAcquisition {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] $Entry
    )
    [void]$Report.acquisitions.Add($Entry)
}

function Add-AiReportPhase {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Status,
        $Evidence = $null
    )
    [void]$Report.phases.Add([ordered]@{ name = $Name; status = $Status; evidence = $Evidence })
}

function Complete-AiWorkloadReport {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] [bool] $Ready,
        [Parameter(Mandatory)] [string] $Path
    )
    $Report.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $Report.result.ready = $Ready
    Write-DevConfigTextFile -Path $Path -Content ($Report | ConvertTo-Json -Depth 20)
    Write-Host "AI_REPORT: $Path"
}

function Write-AiFailureReport {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $ErrorRecord
    )
    [void]$Report.result.blockers.Add($ErrorRecord.Exception.Message)
    Complete-AiWorkloadReport -Report $Report -Ready $false -Path $Path
}

function Get-AiDefaultReportPath {
    param([Parameter(Mandatory)] [string] $Id)
    return Join-Path $env:LOCALAPPDATA "DevConfig\reports\$Id-latest.json"
}

function Get-AiCatalog {
    return Get-AiCatalogData
}

function Get-AiCatalogValue {
    param(
        [Parameter(Mandatory)] [hashtable] $Entry,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($Entry.ContainsKey($Name)) {
        return $Entry[$Name]
    }
    return $null
}

function Set-AiAcquisitionAction {
    param(
        [Parameter(Mandatory)] [hashtable] $Report,
        [Parameter(Mandatory)] [int] $Index,
        [Parameter(Mandatory)] [string] $Action
    )
    $Report.acquisitions[$Index].action = $Action
}
