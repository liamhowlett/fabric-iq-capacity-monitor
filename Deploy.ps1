#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$Config, [switch]$FolderOnly)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\FabricIqMonitor.psm1') -Force -DisableNameChecking
if ($FolderOnly) {
    Set-PocDeploymentFolder -Config $Config -WhatIf:$WhatIfPreference -Confirm:$false
} else {
    Start-PocDeployment -Config $Config -WhatIf:$WhatIfPreference -Confirm:$false
}
