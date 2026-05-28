<#
.SYNOPSIS
    Compares the top-level signed copies (Workloads/, windows-dev-config/,
    wsl-comfort/) against their src/ sources and emits a JSON drift report.

.DESCRIPTION
    The repository carries two parallel copies of every flow: the editable
    source under src/{Workloads,windows-dev-config,wsl-comfort}/ and the
    Authenticode-signed release copy at the matching top-level paths.
    The sign pipeline (.pipelines/OneBranch.SignAndPackage.yml) regenerates
    the top-level copies by signing src/**/*.ps1 (appending a
    "# SIG # Begin signature block" footer) and mirroring every other file
    (.winget / .sh / .md / images / anything else) byte-for-byte.

    This script walks every file under both trees, pairs each one with its
    counterpart, and classifies it as ok | drifted | missing-in-root |
    missing-in-src. For .ps1 files the comparison strips the UTF-8 BOM,
    normalizes CRLF to LF, and on the root copy drops everything from the
    first "# SIG # Begin signature block" line to EOF. For every other
    file the comparison is a strict byte-equal.

    The script always exits 0; it is a pure reporter. Callers decide
    pass/fail based on the JSON output.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of src/tools/ (i.e. two levels
    up from this script). Pass an explicit path to run against an alternate
    checkout.

.PARAMETER OutPath
    Optional file path to write the JSON report to (in addition to stdout).

.OUTPUTS
    JSON drift report on stdout. Always exits 0.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$OutPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    # src/tools/check-signed-drift.ps1 -> repo root is two directories up.
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
} else {
    $RepoRoot = (Resolve-Path $RepoRoot).Path
}

$signedRoots = @('Workloads', 'windows-dev-config', 'wsl-comfort')
$utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)

function ConvertTo-PosixPath {
    param([string]$Path)
    return ($Path -replace '\\', '/')
}

function Get-RelativePath {
    param(
        [string]$Base,
        [string]$Full
    )
    # Build a normalized "Base\" prefix and strip it. Avoids platform churn
    # with [System.IO.Path]::GetRelativePath and PowerShell 7 quirks.
    $baseFull = (Resolve-Path $Base).Path
    if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFull = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    }
    if ($Full.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Full.Substring($baseFull.Length)
    }
    return $Full
}

function Get-NormalizedPs1Bytes {
    param(
        [byte[]]$Bytes,
        [switch]$StripSignatureBlock
    )

    if ($null -eq $Bytes) { return [byte[]]@() }

    # Strip leading UTF-8 BOM if present.
    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq $utf8Bom[0] -and
        $Bytes[1] -eq $utf8Bom[1] -and
        $Bytes[2] -eq $utf8Bom[2]) {
        $Bytes = $Bytes[3..($Bytes.Length - 1)]
    }

    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)

    # Split on both CRLF and lone LF so we can compare against either side.
    $lines = $text -split "`r`n|`n"

    if ($StripSignatureBlock) {
        $cutoff = -1
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i].Trim() -eq '# SIG # Begin signature block') {
                $cutoff = $i
                break
            }
        }
        if ($cutoff -ge 0) {
            if ($cutoff -eq 0) {
                $lines = @()
            } else {
                $lines = $lines[0..($cutoff - 1)]
            }
        }
    }

    $joined = [string]::Join("`n", $lines)
    return [System.Text.Encoding]::UTF8.GetBytes($joined)
}

function Get-FirstDifferenceOffset {
    param(
        [byte[]]$A,
        [byte[]]$B
    )
    $min = [Math]::Min($A.Length, $B.Length)
    for ($i = 0; $i -lt $min; $i++) {
        if ($A[$i] -ne $B[$i]) { return $i }
    }
    if ($A.Length -ne $B.Length) { return $min }
    return -1
}

function Compare-Pair {
    param(
        [string]$RootRelPath,        # e.g. Workloads/python/install.ps1
        [string]$SrcAbsPath,
        [string]$RootAbsPath
    )

    $srcExists = Test-Path -LiteralPath $SrcAbsPath -PathType Leaf
    $rootExists = Test-Path -LiteralPath $RootAbsPath -PathType Leaf

    $entry = [ordered]@{
        path     = ConvertTo-PosixPath $RootRelPath
        src_path = ConvertTo-PosixPath ("src/" + $RootRelPath)
        status   = $null
        reason   = $null
    }

    if (-not $srcExists -and -not $rootExists) {
        # Should never happen — we only enumerate paths that exist somewhere.
        $entry.status = 'ok'
        return [pscustomobject]$entry
    }

    if (-not $srcExists) {
        $entry.status = 'missing-in-src'
        $entry.reason = "no matching source at src/$($entry.path)"
        return [pscustomobject]$entry
    }

    if (-not $rootExists) {
        $entry.status = 'missing-in-root'
        $entry.reason = "no matching signed copy at $($entry.path)"
        return [pscustomobject]$entry
    }

    $srcBytes  = [System.IO.File]::ReadAllBytes($SrcAbsPath)
    $rootBytes = [System.IO.File]::ReadAllBytes($RootAbsPath)

    $isPs1 = [System.IO.Path]::GetExtension($RootRelPath).Equals('.ps1', [System.StringComparison]::OrdinalIgnoreCase)

    if ($isPs1) {
        $srcNorm  = Get-NormalizedPs1Bytes -Bytes $srcBytes
        $rootNorm = Get-NormalizedPs1Bytes -Bytes $rootBytes -StripSignatureBlock
        $offset = Get-FirstDifferenceOffset -A $srcNorm -B $rootNorm
        if ($offset -lt 0) {
            $entry.status = 'ok'
        } else {
            $entry.status = 'drifted'
            $entry.reason = "normalized .ps1 bytes differ at offset $offset (src len=$($srcNorm.Length), root len=$($rootNorm.Length))"
        }
    } else {
        $offset = Get-FirstDifferenceOffset -A $srcBytes -B $rootBytes
        if ($offset -lt 0) {
            $entry.status = 'ok'
        } else {
            $entry.status = 'drifted'
            $entry.reason = "bytes differ at offset $offset (src len=$($srcBytes.Length), root len=$($rootBytes.Length))"
        }
    }

    return [pscustomobject]$entry
}

# ---------------------------------------------------------------------------
# Enumerate every file under the three roots in both trees and build the
# union of root-relative paths to compare.
# ---------------------------------------------------------------------------
$pairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($root in $signedRoots) {
    $srcDir  = Join-Path $RepoRoot (Join-Path 'src' $root)
    $rootDir = Join-Path $RepoRoot $root

    if (Test-Path -LiteralPath $srcDir -PathType Container) {
        Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force | ForEach-Object {
            $rel = Get-RelativePath -Base $srcDir -Full $_.FullName
            [void]$pairs.Add((Join-Path $root $rel))
        }
    }

    if (Test-Path -LiteralPath $rootDir -PathType Container) {
        Get-ChildItem -LiteralPath $rootDir -Recurse -File -Force | ForEach-Object {
            $rel = Get-RelativePath -Base $rootDir -Full $_.FullName
            [void]$pairs.Add((Join-Path $root $rel))
        }
    }
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($rel in $pairs) {
    $srcAbs  = Join-Path $RepoRoot (Join-Path 'src' $rel)
    $rootAbs = Join-Path $RepoRoot $rel
    $results.Add((Compare-Pair -RootRelPath $rel -SrcAbsPath $srcAbs -RootAbsPath $rootAbs))
}

# Deterministic ordering by root-relative posix path.
$sorted = $results | Sort-Object -Property path

$summary = [ordered]@{
    ok              = ($sorted | Where-Object { $_.status -eq 'ok' }).Count
    drifted         = ($sorted | Where-Object { $_.status -eq 'drifted' }).Count
    missing_in_root = ($sorted | Where-Object { $_.status -eq 'missing-in-root' }).Count
    missing_in_src  = ($sorted | Where-Object { $_.status -eq 'missing-in-src' }).Count
}

$report = [ordered]@{
    summary = $summary
    files   = @($sorted)
}

$json = $report | ConvertTo-Json -Depth 8

if (-not [string]::IsNullOrWhiteSpace($OutPath)) {
    $outDir = [System.IO.Path]::GetDirectoryName($OutPath)
    if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    [System.IO.File]::WriteAllText($OutPath, $json, [System.Text.UTF8Encoding]::new($false))
}

Write-Output $json
exit 0
