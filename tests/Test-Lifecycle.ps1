#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot) 'scripts\FabricIqMonitor.psm1') -Force -DisableNameChecking -PassThru

& $module {
    function Reset-RemovalFixture {
        $script:FixtureState = @{
            deploymentId = 'fixture'; workspaceId = 'test-workspace'; workspaceName = 'Removal fixture'
            workspaceCreated = $true; workspaceInventory = @('owned-model', 'owned-house')
            resources = @{
                model = @{ id = 'owned-model'; name = 'Model'; type = 'SemanticModel'; collection = 'semanticModels'; owned = $true }
                eventhouse = @{ id = 'owned-house'; name = 'House'; type = 'Eventhouse'; collection = 'eventhouses'; owned = $true }
                connection = @{ id = 'reused-connection'; name = 'Existing connection'; owned = $false }
            }
            folder = @{ id = 'reused-folder'; name = 'Existing folder'; owned = $false }
        }
        $script:FixtureItems = @(@{ id = 'owned-model' }, @{ id = 'owned-house' })
        $script:FixtureDeleted = [Collections.Generic.List[string]]::new()
        $script:FixtureChangedMarker = ''
        $script:FixtureRemovalMode = $false
    }

    function script:Read-PocDeployment {
        param([string]$Config, [switch]$ForRemoval)
        $script:FixtureRemovalMode = $ForRemoval.IsPresent
        return @{ context = @{ statePath = 'unused'; config = @{ operationTimeoutSeconds = 60 } }; state = $script:FixtureState }
    }
    function script:Invoke-PocRequest {
        param([string]$Method, [string]$Uri, $Body, [switch]$Idempotent, [switch]$AllowNotFound)
        $id = ($Uri -split '/')[-1]
        if ($Method -eq 'DELETE') {
            $script:FixtureDeleted.Add($id)
            return @{ status = 200; data = $null }
        }
        if ($script:FixtureDeleted.Contains($id)) { return @{ status = 404; data = $null } }
        $marker = if ($id -eq $script:FixtureChangedMarker) { 'Another owner' } else { Get-PocMarker $script:FixtureState }
        return @{ status = 200; data = @{ id = $id; description = $marker } }
    }
    function script:Get-PocCollection { param([string]$Uri); return $script:FixtureItems }
    function script:Save-PocState { param($State, $Path) }
    function script:Wait-PocOperation { param($Response, $TimeoutSeconds, [switch]$NoResult); return $Response.data }

    function Assert-RemovalRefused {
        param([string]$Expected, [hashtable]$Extra = @{})
        $caught = $null
        try {
            Remove-PocDeployment -Config unused -ConfirmWorkspaceName 'Removal fixture' -Confirm:$false @Extra
        } catch { $caught = $_.Exception.Message }
        if (-not $caught -or $caught -notlike "*$Expected*") { throw "Expected removal refusal '$Expected'; received '$caught'." }
        if ($script:FixtureDeleted.Count -ne 0) { throw 'A destructive request was sent before the safety refusal.' }
    }

    Reset-RemovalFixture
    Assert-RemovalRefused 'reused connection' @{ DeleteConnection = $true }

    Reset-RemovalFixture
    $script:FixtureChangedMarker = 'owned-house'
    Assert-RemovalRefused 'Ownership marker changed'

    Reset-RemovalFixture
    $script:FixtureItems += @{ id = 'foreign-child' }
    Assert-RemovalRefused 'Parent-item removal is refused'

    Reset-RemovalFixture
    $script:FixtureState.Remove('workspaceInventory')
    Assert-RemovalRefused 'No saved inventory'

    Reset-RemovalFixture
    $script:FixtureItems += @{ id = 'foreign-model' }
    Assert-RemovalRefused 'Whole-workspace deletion is refused' @{ DeleteWorkspace = $true }

    Reset-RemovalFixture
    $script:FixtureState.resources.Remove('eventhouse')
    $script:FixtureItems += @{ id = 'foreign-model' }
    Remove-PocDeployment -Config unused -ConfirmWorkspaceName 'Removal fixture' -Confirm:$false
    if ($script:FixtureDeleted.Count -ne 1 -or $script:FixtureDeleted[0] -ne 'owned-model') {
        throw 'Partial removal did not preserve unrelated items, the destination folder and the reused connection.'
    }
    if (-not $script:FixtureRemovalMode) { throw 'Removal unexpectedly required an active capacity.' }
    Remove-PocDeployment -Config unused -ConfirmWorkspaceName 'Removal fixture' -Confirm:$false
    if ($script:FixtureDeleted.Count -ne 1) { throw 'A repeated partial removal sent another delete for an absent item.' }

    Reset-RemovalFixture
    Remove-PocDeployment -Config unused -ConfirmWorkspaceName 'Removal fixture' -DeleteWorkspace -Confirm:$false
    if ($script:FixtureDeleted.Count -ne 1 -or $script:FixtureDeleted[0] -ne 'test-workspace') {
        throw 'Owned workspace deletion did not target exactly the approved workspace.'
    }
    Write-Host 'Removal fixtures passed: preflight refusals, unrelated/reused preservation, repeat removal and exact workspace targeting.'
}
