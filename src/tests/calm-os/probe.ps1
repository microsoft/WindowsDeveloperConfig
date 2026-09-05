# Smoke-test probe for the calm-os user-experience flow.
#
# After the flow has run, the packages phase has installed git via winget.
# The simplest signal a human can use to confirm the flow worked is: does
# `git --version` exit 0 afterwards? If so, the packages phase reached
# completion. If not, something tripped during install and the user should
# look at devconfig-log.txt next to dev-config.ps1.
#
# Output: `OK` if git is on PATH and `git --version` exits 0;
#         throw otherwise (which the harness surfaces as a failure).
#
# Why a script file (and not an inline run command in manifest.yml):
# the inline form is fine for this particular probe, but `tests/<id>/`
# probe scripts give us room to grow -- for example, asserting that a
# specific registry value matches an expected state -- without
# touching the manifest.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$null = Get-Command git -ErrorAction Stop
$null = & git --version
if ($LASTEXITCODE -ne 0) {
    throw "git --version exited with code $LASTEXITCODE"
}

Write-Output 'OK'
