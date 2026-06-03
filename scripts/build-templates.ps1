#!/usr/bin/env pwsh
# Phase 0.P -- build the 2 Citus Packer templates sequentially.
# Order: pg (riskiest -- PG 17 + Citus apt repo + Patroni venv + keepalived) -> etcd.
# Usage: pwsh -File scripts\build-templates.ps1 [-Only etcd|pg]
[CmdletBinding()]
param([string]$Only = '', [string]$Iso = 'H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso')

$ErrorActionPreference = 'Stop'
$base = Join-Path (Split-Path -Parent $PSScriptRoot) 'packer'
$order = @('citus-pg-node', 'citus-etcd-node')
if ($Only) { $order = @("citus-$Only-node") }

foreach ($t in $order) {
    Write-Host ""
    Write-Host "==== packer build $t ($(Get-Date -Format o)) ====" -ForegroundColor Cyan
    Push-Location (Join-Path $base $t)
    try {
        packer init . | Out-Null
        packer build -force -var "iso_url=$Iso" .
        if ($LASTEXITCODE -ne 0) { throw "packer build $t FAILED (exit $LASTEXITCODE)" }
        Write-Host "==== $t DONE ($(Get-Date -Format o)) ====" -ForegroundColor Green
    }
    finally { Pop-Location }
}
Write-Host ""
Write-Host "ALL TEMPLATE BUILDS COMPLETE" -ForegroundColor Green
