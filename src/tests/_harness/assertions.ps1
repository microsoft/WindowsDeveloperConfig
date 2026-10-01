$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AssertionCount = 0

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
    $script:AssertionCount++
}

function Assert-Equal {
    param(
        [AllowNull()] $Actual,
        [AllowNull()] $Expected,
        [Parameter(Mandatory)] [string] $Message
    )
    if ($Actual -ne $Expected) {
        throw "Assertion failed: $Message. Expected '$Expected'; got '$Actual'."
    }
    $script:AssertionCount++
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Message
    )
    try {
        & $ScriptBlock
    } catch {
        if ($_.Exception.Message -notlike $Pattern) {
            throw "Assertion failed: $Message. Error '$($_.Exception.Message)' did not match '$Pattern'."
        }
        $script:AssertionCount++
        return
    }
    throw "Assertion failed: $Message. Expected an exception."
}
