#!/usr/bin/env pwsh
# Phase 0.O -- build the 3 Vitess Packer templates sequentially.
# Order: tablet (riskiest -- Percona 8.4 apt + Vitess tarball) -> gate -> etcd.
# Usage: pwsh -File scripts\build-templates.ps1 [-Only etcd|gate|tablet]
[CmdletBinding()]
param([string]$Only = '', [string]$Iso = 'H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso')

$ErrorActionPreference = 'Stop'
$base = Join-Path (Split-Path -Parent $PSScriptRoot) 'packer'
$order = @('vitess-tablet-node', 'vitess-gate-node', 'vitess-etcd-node')
if ($Only) { $order = @("vitess-$Only-node") }

foreach ($t in $order) {
    Write-Host ""
    Write-Host "==== packer build $t ($(Get-Date -Format o)) ====" -ForegroundColor Cyan
    Push-Location (Join-Path $base $t)
    try {
        packer build -force -var "iso_url=$Iso" .
        if ($LASTEXITCODE -ne 0) { throw "packer build $t FAILED (exit $LASTEXITCODE)" }
        Write-Host "==== $t DONE ($(Get-Date -Format o)) ====" -ForegroundColor Green
    }
    finally { Pop-Location }
}
Write-Host ""
Write-Host "ALL TEMPLATE BUILDS COMPLETE" -ForegroundColor Green
