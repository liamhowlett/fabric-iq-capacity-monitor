#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot) 'scripts\FabricIqMonitor.psm1') -Force -DisableNameChecking -PassThru

& $module {
    function Assert-Folder {
        param([bool]$Condition, [string]$Message)
        if (-not $Condition) { throw $Message }
    }
    function Assert-FolderRefused {
        param([scriptblock]$Action, [string]$Expected)
        $caught = $null
        try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
        if (-not $caught -or $caught -notlike "*$Expected*") { throw "Expected folder refusal '$Expected'; received '$caught'." }
    }
    function Reset-FolderFixture {
        $script:FixtureFolderId = [Guid]::NewGuid().ToString()
        $script:FixtureFolder = $null
        $script:FixtureState = @{
            deploymentId = 'fixture'; workspaceId = 'test-workspace'; workspaceName = 'Folder fixture'
            resources = @{
                model = @{ id = 'owned-model'; name = 'Model'; type = 'SemanticModel'; collection = 'semanticModels'; owned = $true }
                eventhouse = @{ id = 'owned-house'; name = 'House'; type = 'Eventhouse'; collection = 'eventhouses'; owned = $true }
                database = @{ id = 'owned-database'; name = 'Database'; type = 'KQLDatabase'; collection = 'kqlDatabases'; owned = $true }
                monitoring = @{ id = 'owned-monitor'; name = 'Monitor'; type = 'Monitoring'; collection = 'monitoringItems'; owned = $true }
                connection = @{ id = 'reused-connection'; type = 'Connection'; owned = $false }
            }
        }
        $marker = Get-PocMarker $script:FixtureState
        $script:FixtureItems = @(
            @{ id = 'owned-model'; type = 'SemanticModel'; displayName = 'Model'; description = $marker },
            @{ id = 'owned-house'; type = 'Eventhouse'; displayName = 'House'; description = $marker },
            @{ id = 'owned-database'; type = 'KQLDatabase'; displayName = 'Database'; description = $marker },
            @{ id = 'owned-monitor'; type = 'Monitoring'; displayName = 'Monitor'; description = $marker },
            @{ id = 'generated-default-database'; type = 'KQLDatabase'; displayName = 'House' },
            @{ id = 'generated-monitor-database'; type = 'KQLDatabase'; displayName = 'Diagnostics' },
            @{ id = 'generated-monitor-stream'; type = 'Eventstream'; displayName = 'DiagnosticsStream' },
            @{ id = 'generated-monitor-activator'; type = 'Activator'; displayName = 'DiagnosticsActivator' }
        )
        $script:FixtureState.workspaceInventory = @($script:FixtureItems | ForEach-Object id)
        $script:FixtureContext = @{ config = @{ folderName = 'Fabric IQ Monitor'; folderId = ''; operationTimeoutSeconds = 60 }; statePath = 'unused' }
        $script:FixtureWrites = [Collections.Generic.List[object]]::new()
        $script:FixtureSaved = 0
        $script:FixtureForFolder = $false
        $script:FixtureCreateBody = $null
        $script:FixtureSuppressChildMove = $false
    }
    function script:Read-PocDeployment {
        param([string]$Config, [switch]$ForFolder)
        $script:FixtureForFolder = $ForFolder.IsPresent
        return @{ context = $script:FixtureContext; state = $script:FixtureState }
    }
    function script:Save-PocState { param($State, $Path); $script:FixtureSaved++ }
    function script:Get-PocCollection {
        param([string]$Uri)
        if ($Uri.EndsWith('/folders')) { if ($script:FixtureFolder) { return $script:FixtureFolder }; return }
        if ($Uri.EndsWith('/items')) { return $script:FixtureItems }
        throw "Unexpected collection request: $Uri"
    }
    function script:Wait-PocOperation { param($Response, $TimeoutSeconds); return $Response.data }
    function script:Invoke-PocRequest {
        param([string]$Method, [string]$Uri, $Body, [switch]$Idempotent, [switch]$AllowNotFound)
        if ($Method -ne 'GET') { $script:FixtureWrites.Add(@{ method = $Method; uri = $Uri; body = $Body }) }
        if ($Uri -match '/folders(?:/[^/]+)?$') {
            if ($Method -eq 'POST') { $script:FixtureFolder = @{ id = $script:FixtureFolderId; displayName = $Body.displayName } }
            if (-not $script:FixtureFolder) { throw 'Folder not found.' }
            return @{ status = 200; data = $script:FixtureFolder }
        }
        if ($Method -eq 'POST' -and $Uri.EndsWith('/semanticModels')) {
            $script:FixtureCreateBody = $Body
            $item = @{ id = 'new-model'; type = 'SemanticModel'; displayName = $Body.displayName; description = $Body.description }
            if ($Body.ContainsKey('folderId')) { $item.folderId = $Body.folderId }
            $script:FixtureItems += $item
            return @{ status = 201; data = $item }
        }
        if ($Uri -match '/(?:items|semanticModels|eventhouses|kqlDatabases|monitoringItems)/([^/]+)(/move)?$') {
            $id = $Matches[1]
            $moving = [bool]$Matches[2]
            $item = @($script:FixtureItems | Where-Object id -eq $id)
            if ($item.Count -ne 1) { throw "Missing fixture item $id." }
            if ($Method -eq 'GET') { return @{ status = 200; data = $item[0] } }
            if ($Method -ne 'POST' -or -not $moving) { throw "Unexpected mutation: $Method $Uri" }
            if ($item[0].type -eq 'KQLDatabase') { throw 'A child item was moved independently.' }
            $ids = @($id)
            if ($id -eq 'owned-house') { $ids += @('owned-database', 'generated-default-database') }
            if ($id -eq 'owned-monitor') { $ids += @('generated-monitor-database', 'generated-monitor-stream', 'generated-monitor-activator') }
            $moved = @($script:FixtureItems | Where-Object { $_.id -in $ids })
            foreach ($child in $moved) {
                if (-not ($script:FixtureSuppressChildMove -and $child.id -ne $id)) { $child.folderId = $Body.targetFolderId }
            }
            return @{ status = 200; data = @{ value = $moved } }
        }
        throw "Unexpected API request: $Method $Uri"
    }

    Assert-PocFolderConfig @{}
    Assert-PocFolderConfig @{ folderName = ''; folderId = '' }
    Assert-FolderRefused { Assert-PocFolderConfig @{ folderName = 'Bad/Path' } } 'valid single'
    Assert-FolderRefused { Assert-PocFolderConfig @{ folderName = ' trailing ' } } 'valid single'
    Assert-FolderRefused { Assert-PocFolderConfig @{ folderName = 'recycler' } } 'valid single'
    Assert-FolderRefused { Assert-PocFolderConfig @{ folderName = ('x' * 256) } } 'valid single'
    Assert-FolderRefused { Assert-PocFolderConfig @{ folderId = 'not-a-guid' } } 'GUID'
    Assert-FolderRefused { Assert-PocFolderConfig @{ folderName = 12 } } 'must be a string'
    Assert-FolderRefused { Assert-PocFolderConfig @{ folderName = 'Monitor'; folderId = [Guid]::NewGuid().ToString() } } 'not both'

    Reset-FolderFixture
    $script:FixtureContext.config.Remove('folderName')
    $script:FixtureContext.config.Remove('folderId')
    Ensure-PocFolder $script:FixtureContext $script:FixtureState | Out-Null
    Assert-Folder ($script:FixtureWrites.Count -eq 0 -and -not $script:FixtureState.ContainsKey('folder')) 'Legacy root config unexpectedly selected a folder.'

    Reset-FolderFixture
    Ensure-PocFolder $script:FixtureContext $script:FixtureState | Out-Null
    Assert-Folder ($script:FixtureState.folder.owned -and $script:FixtureWrites.Count -eq 1) 'New folder ownership was not saved.'
    Ensure-PocFolder $script:FixtureContext $script:FixtureState | Out-Null
    Assert-Folder ($script:FixtureWrites.Count -eq 1) 'Rerun created another folder.'
    $script:FixtureContext.config.folderName = 'Changed folder'
    Assert-FolderRefused { Ensure-PocFolder $script:FixtureContext $script:FixtureState } 'differs from saved state'
    $script:FixtureContext.config.folderName = 'Fabric IQ Monitor'
    $script:FixtureContext.config.folderId = [Guid]::NewGuid().ToString()
    $script:FixtureContext.config.folderName = ''
    Assert-FolderRefused { Ensure-PocFolder $script:FixtureContext $script:FixtureState } 'differs from saved state'
    $script:FixtureContext.config.folderName = 'Fabric IQ Monitor'
    $script:FixtureContext.config.folderId = ''
    $script:FixtureFolder.displayName = 'Renamed externally'
    Assert-FolderRefused { Ensure-PocFolder $script:FixtureContext $script:FixtureState } 'renamed'
    $script:FixtureFolder = $null
    Assert-FolderRefused { Ensure-PocFolder $script:FixtureContext $script:FixtureState } 'not found'

    Reset-FolderFixture
    $script:FixtureFolder = @{ id = $script:FixtureFolderId; displayName = 'Fabric IQ Monitor' }
    Assert-FolderRefused { Ensure-PocFolder $script:FixtureContext $script:FixtureState } 'folderId explicitly'
    Assert-Folder ($script:FixtureWrites.Count -eq 0) 'A name collision changed the service.'
    $script:FixtureContext.config.folderName = ''
    $script:FixtureContext.config.folderId = $script:FixtureFolderId
    Ensure-PocFolder $script:FixtureContext $script:FixtureState | Out-Null
    Assert-Folder (-not $script:FixtureState.folder.owned -and $script:FixtureWrites.Count -eq 0) 'Explicit folder reuse changed ownership or sent a create.'

    Reset-FolderFixture
    Set-PocDeploymentFolder -Config unused -WhatIf
    Assert-Folder ($script:FixtureWrites.Count -eq 0 -and $script:FixtureSaved -eq 0) 'Folder-only WhatIf changed state or service.'
    Set-PocDeploymentFolder -Config unused -Confirm:$false
    Assert-Folder $script:FixtureForFolder 'Organisation unexpectedly used the active-capacity deployment path.'
    Assert-Folder ($script:FixtureWrites.Count -eq 4) 'Expected one folder create and three top-level moves.'
    Assert-Folder (@($script:FixtureItems | Where-Object { $_['folderId'] -ne $script:FixtureFolderId }).Count -eq 0) 'Generated children were left outside the folder.'
    $before = $script:FixtureWrites.Count
    Set-PocDeploymentFolder -Config unused -Confirm:$false
    Assert-Folder ($script:FixtureWrites.Count -eq $before) 'Repeat organisation sent duplicate creates or moves.'
    Assert-Folder (-not $script:FixtureState.resources.connection.owned) 'Reused cloud connection was adopted.'

    Reset-FolderFixture
    $script:FixtureItems[0].description = 'Another owner'
    Assert-FolderRefused { Set-PocDeploymentFolder -Config unused -Confirm:$false } 'preflight'
    Assert-Folder ($script:FixtureWrites.Count -eq 0) 'Ownership refusal happened after mutation.'
    Reset-FolderFixture
    $script:FixtureState.Remove('workspaceInventory')
    Assert-FolderRefused { Set-PocDeploymentFolder -Config unused -Confirm:$false } 'completed-install inventory'
    Assert-Folder ($script:FixtureWrites.Count -eq 0) 'Missing-inventory refusal happened after mutation.'
    Reset-FolderFixture
    $script:FixtureItems += @{ id = 'foreign-child' }
    Assert-FolderRefused { Set-PocDeploymentFolder -Config unused -Confirm:$false } 'Untracked items'
    Assert-Folder ($script:FixtureWrites.Count -eq 0) 'Untracked-item refusal happened after mutation.'
    Reset-FolderFixture
    $script:FixtureSuppressChildMove = $true
    Assert-FolderRefused { Set-PocDeploymentFolder -Config unused -Confirm:$false } 'parent or child'

    Reset-FolderFixture
    Ensure-PocFolder $script:FixtureContext $script:FixtureState | Out-Null
    Ensure-PocItem $script:FixtureContext $script:FixtureState 'newModel' 'semanticModels' 'SemanticModel' 'NewModel' | Out-Null
    Assert-Folder ($script:FixtureCreateBody.folderId -eq $script:FixtureFolderId) 'New item creation omitted destination folder.'
    $before = $script:FixtureWrites.Count
    Ensure-PocItem $script:FixtureContext $script:FixtureState 'newModel' 'semanticModels' 'SemanticModel' 'NewModel' | Out-Null
    Assert-Folder ($script:FixtureWrites.Count -eq $before) 'Rerunning an already placed item sent another create or move.'

    Reset-FolderFixture
    $script:FixtureContext.config.Remove('folderName')
    $script:FixtureContext.config.Remove('folderId')
    Ensure-PocItem $script:FixtureContext $script:FixtureState 'newModel' 'semanticModels' 'SemanticModel' 'NewModel' | Out-Null
    Assert-Folder (-not $script:FixtureCreateBody.ContainsKey('folderId')) 'Legacy root item creation unexpectedly included a folder.'

    Write-Host 'Folder fixtures passed: root compatibility, explicit reuse, owned parents/children, preflight refusals, WhatIf and repeat organisation.'
}
