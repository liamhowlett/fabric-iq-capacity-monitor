#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$Config,
    [switch]$DeleteWorkspace,
    [Parameter(Mandatory)][string]$ConfirmWorkspaceName,
    [switch]$DeleteConnection
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\FabricIqMonitor.psm1') -Force -DisableNameChecking
$parameters = @{
    Config = $Config; DeleteWorkspace = $DeleteWorkspace
    ConfirmWorkspaceName = $ConfirmWorkspaceName; DeleteConnection = $DeleteConnection
    WhatIf = $WhatIfPreference
}
if ($PSBoundParameters.ContainsKey('Confirm')) { $parameters.Confirm = $PSBoundParameters.Confirm }
Remove-PocDeployment @parameters
