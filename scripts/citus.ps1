#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.O operator wrapper for the vitess env (Vitess-sharded MySQL cluster).

.DESCRIPTION
  pwsh-native equivalent of `make` targets. Drives terraform/envs/vitess/ with
  apply/destroy/cycle/smoke/plan/validate. The FIRST 12-VM apply should use
  -parallelism=3 to avoid the vmrun power-on storm (Phase 0.N lesson N10) --
  pass it via -Parallelism 3 (default) or override.

.PARAMETER Verb
  apply | destroy | smoke | cycle | plan | validate

.PARAMETER Vars
  Forwarded -var pairs (comma- or array-separated).

.PARAMETER Parallelism
  terraform -parallelism for apply/cycle (default 3 for the vmrun-storm-safe
  first apply; bump to 10 for overlay-only re-applies once VMs exist).

.EXAMPLE
  pwsh -File scripts\vitess.ps1 apply
  pwsh -File scripts\vitess.ps1 apply -Parallelism 10
  pwsh -File scripts\vitess.ps1 cycle
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('apply', 'destroy', 'smoke', 'cycle', 'plan', 'validate')]
    [string]$Verb,
    [string[]]$Vars = @(),
    [int]$Parallelism = 3
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$envDir    = Join-Path $repoRoot 'terraform\envs\vitess'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.O.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$TfArgs)
    Push-Location $envDir
    try {
        & terraform @TfArgs
        if ($LASTEXITCODE -ne 0) { throw "terraform $($TfArgs[0]) failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
}

function Get-VarFlags {
    $flags = @()
    foreach ($v in $Vars) {
        foreach ($piece in ($v -split ',')) {
            $trimmed = $piece.Trim()
            if ($trimmed) { $flags += @('-var', $trimmed) }
        }
    }
    return $flags
}

function Invoke-Apply {
    Write-Step "terraform apply -auto-approve -parallelism=$Parallelism"
    $argv = @('apply', '-auto-approve', "-parallelism=$Parallelism")
    $argv += (Get-VarFlags)
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step "pwsh -File $(Split-Path -Leaf $smokePath)"
    if (-not (Test-Path $smokePath)) { throw "smoke script not found: $smokePath" }
    & pwsh -NoProfile -File $smokePath
    if ($LASTEXITCODE -ne 0) { throw "smoke gate failed (exit $LASTEXITCODE)" }
}

function Invoke-Plan {
    Write-Step 'terraform plan'
    $argv = @('plan')
    $argv += (Get-VarFlags)
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate'
    Invoke-Terraform @('validate')
}

switch ($Verb) {
    'apply'    { Invoke-Apply }
    'destroy'  { Invoke-Destroy }
    'smoke'    { Invoke-Smoke }
    'plan'     { Invoke-Plan }
    'validate' { Invoke-Validate }
    'cycle' {
        Invoke-Destroy
        Invoke-Apply
        Invoke-Smoke
    }
}

Write-Host ''
Write-Host "vitess $Verb complete" -ForegroundColor Green
