#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Config, [switch]$GenerateActivity)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\FabricIqMonitor.psm1') -Force -DisableNameChecking
Test-PocDeployment -Config $Config -GenerateActivity:$GenerateActivity
