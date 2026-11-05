#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path $PSScriptRoot
$script:Tokens = @{}
$script:Fabric = 'https://api.fabric.microsoft.com/v1'
$script:PowerBI = 'https://api.powerbi.com/v1.0/myorg'

function Get-PocToken {
    param([Parameter(Mandatory)][string]$Audience)
    if ($script:Tokens.ContainsKey($Audience) -and $script:Tokens[$Audience].expires -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) {
        return $script:Tokens[$Audience].token
    }
    $result = & az account get-access-token --resource $Audience --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI could not obtain a token for $Audience. Sign in to the configured tenant first." }
    $credential = $result | ConvertFrom-Json -AsHashtable
    $expiry = if ($credential.ContainsKey('expires_on')) {
        [DateTimeOffset]::FromUnixTimeSeconds([long]$credential.expires_on)
    } else { [DateTimeOffset]::UtcNow.AddMinutes(10) }
    $script:Tokens[$Audience] = @{ token = $credential.accessToken; expires = $expiry }
    return $credential.accessToken
}

function Assert-PocEndpoint {
    param([string]$Endpoint)
    $parsed = [Uri]$Endpoint
    if (-not $parsed.IsAbsoluteUri -or $parsed.Scheme -ne 'https' -or $parsed.UserInfo -or $parsed.Query -or $parsed.Fragment -or $parsed.AbsolutePath -ne '/') {
        throw "Invalid Kusto endpoint: $Endpoint"
    }
    if ($parsed.DnsSafeHost -notmatch '\.(kusto\.fabric\.microsoft\.com|kusto\.windows\.net)$') {
        throw 'Only public-cloud Microsoft Kusto endpoints are supported by this PoC.'
    }
}

function Get-PocRetrySeconds {
    param($Headers, [int]$Attempt)
    $header = $Headers['Retry-After']
    if ($null -ne $header) {
        $text = [string]@($header)[0]
        $seconds = 0
        if ([int]::TryParse($text, [ref]$seconds)) { return [Math]::Max(1, $seconds) }
        $date = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($text, [ref]$date)) {
            return [Math]::Max(1, [int][Math]::Ceiling(($date - [DateTimeOffset]::UtcNow).TotalSeconds))
        }
    }
    return [Math]::Min(10, 2 * $Attempt)
}

function Invoke-PocRequest {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [string]$Audience = 'https://api.fabric.microsoft.com',
        [switch]$Idempotent,
        [switch]$AllowNotFound
    )
    $maximum = if ($Method -eq 'GET' -or $Idempotent) { 2 } else { 1 }
    for ($attempt = 1; $attempt -le $maximum; $attempt++) {
        $target = [Uri]$Uri
        $allowed = $target.Scheme -eq 'https' -and (
            $target.DnsSafeHost -in @('api.fabric.microsoft.com', 'api.powerbi.com') -or
            ($Audience -eq 'https://kusto.kusto.windows.net' -and $target.DnsSafeHost -match '\.(kusto\.fabric\.microsoft\.com|kusto\.windows\.net)$')
        )
        if (-not $allowed) { throw 'Refusing to send credentials to an unexpected API host.' }
        $parameters = @{
            Method = $Method; Uri = $Uri
            Headers = @{ Authorization = 'Bearer ' + (Get-PocToken $Audience) }
            SkipHttpErrorCheck = $true; TimeoutSec = 120
        }
        if ($null -ne $Body) {
            $parameters.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 100 -Compress))
            $parameters.ContentType = 'application/json; charset=utf-8'
        }
        $response = Invoke-WebRequest @parameters
        $status = [int]$response.StatusCode
        $data = if ([string]::IsNullOrWhiteSpace($response.Content)) { $null } else { $response.Content | ConvertFrom-Json -AsHashtable }
        if ($status -ge 200 -and $status -lt 300) {
            return @{ status = $status; data = $data; headers = $response.Headers }
        }
        if ($status -eq 404 -and $AllowNotFound) { return @{ status = $status; data = $data; headers = $response.Headers } }
        if ($status -in @(429, 500, 502, 503, 504) -and $attempt -lt $maximum) {
            $delay = Get-PocRetrySeconds $response.Headers $attempt
            if ($delay -gt 120) { throw "Server requested a $delay second delay. No early retry was made. Rerun later." }
            Write-Warning "HTTP $status; retrying the idempotent request after $delay seconds."
            Start-Sleep $delay
            continue
        }
        $detail = if ($null -ne $data) { $data | ConvertTo-Json -Depth 8 -Compress } else { 'No JSON error detail' }
        throw "HTTP $status $Method $Uri : $detail"
    }
}

function Get-PocCollection {
    param([string]$Uri)
    $items = [Collections.Generic.List[object]]::new()
    do {
        $response = Invoke-PocRequest GET $Uri
        foreach ($item in @($response.data['value'])) { if ($null -ne $item) { $items.Add($item) } }
        $next = $response.data['continuationUri']
        if (-not $next) { $next = $response.data['@odata.nextLink'] }
        $Uri = $next
    } while ($Uri)
    return $items.ToArray()
}

function Wait-PocOperation {
    param($Response, [int]$TimeoutSeconds = 600, [switch]$NoResult)
    if ($Response.status -ne 202) { return $Response.data }
    $operation = $Response.headers['x-ms-operation-id']
    if ($operation) { $url = "$script:Fabric/operations/$([string]@($operation)[0])" }
    else { $url = [string]@($Response.headers['Location'])[0] }
    if (-not $url) { throw 'Accepted operation returned neither an operation ID nor a status URL.' }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $delay = Get-PocRetrySeconds $Response.headers 1
        if ($delay -gt $TimeoutSeconds) { throw "Operation asks for a wait longer than the configured budget. Status: $url" }
        Start-Sleep $delay
        $Response = Invoke-PocRequest GET $url
        $status = $Response.data['status']
        if ($status -eq 'Succeeded') {
            if ($NoResult) { return }
            return (Invoke-PocRequest GET "$url/result").data
        }
        if ($status -in @('Failed', 'Cancelled')) { throw ($Response.data | ConvertTo-Json -Depth 10) }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Operation exceeded $TimeoutSeconds seconds. Its server-side operation may still be running: $url. Rerun using the saved state; do not blindly recreate resources."
}

function Get-PocOperationUrl {
    param($Response)
    if ($Response.status -ne 202) { return $null }
    $operation = $Response.headers['x-ms-operation-id']
    if ($operation) { return "$script:Fabric/operations/$([string]@($operation)[0])" }
    $location = [string]@($Response.headers['Location'])[0]
    if (-not $location) { throw 'Accepted item creation returned no operation status URL.' }
    return $location
}

function Save-PocState {
    param([hashtable]$State, [string]$Path)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = "$Path.tmp"
    $State.updatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-PocConfig {
    param([string]$Path)
    $full = (Resolve-Path -LiteralPath $Path).Path
    $config = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json -AsHashtable
    if ($config['schemaVersion'] -ne 1) { throw 'Unsupported config schemaVersion; expected 1.' }
    foreach ($name in @('tenantId', 'capacityId')) {
        $guid = [Guid]::Empty
        if (-not [Guid]::TryParse($config[$name], [ref]$guid) -or $guid -eq [Guid]::Empty) { throw "$name must be a non-empty GUID." }
    }
    if ($config['prefix'] -notmatch '^[A-Za-z][A-Za-z0-9_-]{1,39}$') { throw 'prefix must be 2-40 letters, digits, underscores or hyphens, starting with a letter.' }
    if ($config['createWorkspace']) {
        if (-not $config['workspaceName'] -or $config['workspaceId']) { throw 'New workspace mode needs workspaceName and an empty workspaceId.' }
    } else {
        $id = [Guid]::Empty
        if (-not [Guid]::TryParse($config['workspaceId'], [ref]$id) -or $id -eq [Guid]::Empty) { throw 'Existing workspace mode needs workspaceId.' }
    }
    foreach ($name in @('lookbackDays', 'retentionDays', 'cacheDays', 'operationTimeoutSeconds')) {
        if ($config[$name] -isnot [long] -and $config[$name] -isnot [int]) { throw "$name must be an integer." }
    }
    if ($config.lookbackDays -lt 28 -or $config.lookbackDays -gt 365) { throw 'lookbackDays must be 28-365.' }
    if ($config.retentionDays -lt $config.lookbackDays -or $config.retentionDays -gt 365) { throw 'retentionDays must cover lookbackDays and be at most 365.' }
    if ($config.cacheDays -lt 1 -or $config.cacheDays -gt $config.retentionDays) { throw 'cacheDays must be between 1 and retentionDays.' }
    if ($config.operationTimeoutSeconds -lt 60 -or $config.operationTimeoutSeconds -gt 1800) { throw 'operationTimeoutSeconds must be 60-1800.' }
    if ($config.monitoring.mode -notin @('Create', 'Existing', 'None')) { throw 'monitoring.mode must be Create, Existing or None.' }
    if ($config.monitoring.mode -eq 'Create' -and -not $config.createWorkspace) { throw 'Automatic monitoring enrolment is limited to installer-created workspaces. Use Existing or None for an existing workspace to avoid changing legacy monitoring.' }
    if ($config.monitoring.mode -eq 'None' -and @($config.monitoring.sources).Count -gt 0) { throw 'None monitoring mode cannot include sources.' }
    if ($config.monitoring.mode -eq 'Existing' -and @($config.monitoring.sources).Count -eq 0) { throw 'Existing monitoring mode needs at least one source.' }
    foreach ($source in @($config.monitoring.sources)) {
        Assert-PocEndpoint $source.endpoint
        if (-not $source.database) { throw 'Each monitoring source needs a database identifier.' }
    }
    if ($config['existingConnectionId']) {
        $connectionId = [Guid]::Empty
        if (-not [Guid]::TryParse($config.existingConnectionId, [ref]$connectionId) -or $connectionId -eq [Guid]::Empty) { throw 'existingConnectionId must be a non-empty GUID when supplied.' }
    }
    Assert-PocFolderConfig $config
    $mapKeys = @{}
    foreach ($mapping in @($config.identityMappings)) {
        foreach ($key in @('type', 'value', 'label')) { if (-not $mapping[$key]) { throw "Identity map entry is missing $key." } }
        $key = ($mapping.type + '|' + $mapping.value).ToLowerInvariant()
        if ($mapKeys.ContainsKey($key)) { throw "Duplicate identity mapping: $key" }
        $mapKeys[$key] = $true
    }
    $statePath = if ([IO.Path]::IsPathRooted($config.stateFile)) { $config.stateFile } else { Join-Path (Split-Path $full) $config.stateFile }
    return @{ config = $config; statePath = [IO.Path]::GetFullPath($statePath); configPath = $full }
}

function Assert-PocFolderConfig {
    param([hashtable]$Config)
    foreach ($key in @('folderName', 'folderId')) {
        if ($Config.ContainsKey($key) -and $Config[$key] -isnot [string]) { throw "$key must be a string; use an empty string for no selection." }
    }
    if ($Config['folderName'] -and $Config['folderId']) { throw 'Choose folderName to create a folder, or folderId to reuse one, not both.' }
    if ($Config['folderId']) {
        $id = [Guid]::Empty
        if (-not [Guid]::TryParse($Config.folderId, [ref]$id) -or $id -eq [Guid]::Empty) { throw 'folderId must be a non-empty GUID when supplied.' }
    }
    if ($Config['folderName']) {
        $name = $Config.folderName
        if ($name.Length -gt 255 -or $name.Trim() -cne $name -or $name -match '[\x00-\x1f\x7f-\x9f~"#.&*:<>?/\\{|}]' -or $name -in @('$recycle.bin', 'recycled', 'recycler')) {
            throw 'folderName must be a valid single Fabric folder name, without leading/trailing spaces or reserved characters.'
        }
    }
}

function Ensure-PocFolder {
    param($Context, [hashtable]$State)
    $config = $Context.config
    Assert-PocFolderConfig $config
    $base = "$script:Fabric/workspaces/$($State.workspaceId)/folders"
    if ($State['folder']) {
        $saved = $State.folder
        if (($config['folderId'] -and $config.folderId -ne $saved.id) -or
            ($config['folderName'] -and $config.folderName -cne $saved.name) -or
            (-not $config['folderId'] -and -not $config['folderName'])) {
            throw 'Folder selection differs from saved state. No folder was replaced or items moved.'
        }
        $folder = (Invoke-PocRequest GET "$base/$($saved.id)").data
        if ($folder.displayName -cne $saved.name) { throw 'Saved folder was renamed. Resolve the saved folder selection explicitly before rerunning.' }
        return $folder
    }
    if (-not $config['folderId'] -and -not $config['folderName']) { return }
    if ($config['folderId']) {
        $folder = (Invoke-PocRequest GET "$base/$($config.folderId)").data
        $owned = $false
    } else {
        $matches = @(Get-PocCollection $base | Where-Object { -not $_['parentFolderId'] -and $_.displayName -eq $config.folderName })
        if ($matches.Count -gt 0) { throw 'Folder name already exists. Supply its folderId explicitly to reuse it; no name-matching folder was adopted.' }
        $folder = (Invoke-PocRequest POST $base @{ displayName = $config.folderName }).data
        $owned = $true
    }
    if (-not $folder['id'] -or -not $folder['displayName']) { throw 'Folder API did not return an ID and display name. Inspect the service before retrying.' }
    $State.folder = @{ id = $folder.id; name = $folder.displayName; owned = $owned }
    Save-PocState $State $Context.statePath
    return $folder
}

function Assert-PocParentMoveInventory {
    param([hashtable]$State, [array]$Items)
    if (-not $State['workspaceInventory']) { throw 'Moving a parent item requires the saved completed-install inventory to protect its generated children.' }
    if (-not $PSBoundParameters.ContainsKey('Items')) { $Items = @(Get-PocCollection "$script:Fabric/workspaces/$($State.workspaceId)/items") }
    if (@($Items | Where-Object { $_.id -notin @($State.workspaceInventory) }).Count -gt 0) {
        throw 'Untracked items appeared after installation. Parent-item movement is refused until its child inventory is reconciled.'
    }
}

function Set-PocItemFolder {
    param($Context, [hashtable]$State, [hashtable]$Resource)
    if (-not $State['folder'] -or $Resource.type -in @('Connection', 'KQLDatabase')) { return }
    if (-not $Resource.owned) { throw 'Refusing to move an item not owned by this deployment.' }
    $base = "$script:Fabric/workspaces/$($State.workspaceId)/items"
    $item = (Invoke-PocRequest GET "$base/$($Resource.id)").data
    if ($item.type -ne $Resource.type -or $item.displayName -ne $Resource.name -or $item['description'] -ne (Get-PocMarker $State)) {
        throw 'Folder placement refused because a tracked item changed identity or ownership.'
    }
    if ($item['folderId'] -eq $State.folder.id) { return }
    if ($Resource.type -in @('Monitoring', 'Eventhouse')) {
        Assert-PocParentMoveInventory $State
    }
    $moved = (Invoke-PocRequest POST "$base/$($Resource.id)/move" @{ targetFolderId = $State.folder.id }).data
    $ids = @($moved['value'] | ForEach-Object { $_.id })
    if ($Resource.id -notin $ids) { throw 'Move response omitted the requested item. Inspect its actual folder before retrying.' }
    $State.folderItemIds = @(@($State['folderItemIds']) + $ids | Where-Object { $_ } | Sort-Object -Unique)
    Save-PocState $State $Context.statePath
    foreach ($id in $ids) {
        $actual = (Invoke-PocRequest GET "$base/$id").data
        if ($actual['folderId'] -ne $State.folder.id) { throw 'A moved parent or child did not reach the selected folder. No refresh or definition update was requested.' }
    }
}

function Assert-PocFolderPlacement {
    param([hashtable]$State)
    if (-not $State['folder']) { return }
    $ids = @(@($State.resources.Values | Where-Object { $_.type -ne 'Connection' -and $_.owned } | ForEach-Object { $_.id }) + @($State['folderItemIds']) |
        Where-Object { $_ } | Sort-Object -Unique)
    foreach ($id in $ids) {
        $item = (Invoke-PocRequest GET "$script:Fabric/workspaces/$($State.workspaceId)/items/$id").data
        if ($item['folderId'] -ne $State.folder.id) { throw 'A deployment item is outside the saved destination folder. Inspect parent/child placement before continuing.' }
    }
}

function Set-PocDeploymentFolder {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Config)
    $deployment = Read-PocDeployment $Config -ForFolder
    $context, $state = $deployment.context, $deployment.state
    if (-not $context.config['folderName'] -and -not $context.config['folderId']) { throw 'Folder-only organisation requires folderName or folderId in the local configuration.' }
    $resources = @($state.resources.Values | Where-Object { $_.type -ne 'Connection' -and $_.owned })
    if ($resources.Count -eq 0) { throw 'No installer-owned items are recorded. Folder-only organisation cannot deploy new items.' }
    $items = @(Get-PocCollection "$script:Fabric/workspaces/$($state.workspaceId)/items")
    foreach ($resource in $resources) {
        $item = @($items | Where-Object { $_.id -eq $resource.id })
        if ($item.Count -ne 1 -or $item[0].type -ne $resource.type -or $item[0].displayName -ne $resource.name -or $item[0]['description'] -ne (Get-PocMarker $state)) {
            throw 'Folder-only preflight found a missing or changed owned item. No folder was created or items moved.'
        }
    }
    $targetId = if ($state['folder']) { $state.folder.id } else { $context.config['folderId'] }
    $parentIds = @($resources | Where-Object { $_.type -in @('Monitoring', 'Eventhouse') } | ForEach-Object { $_.id })
    if (@($items | Where-Object { $_.id -in $parentIds -and (-not $targetId -or $_['folderId'] -ne $targetId) }).Count -gt 0) {
        Assert-PocParentMoveInventory $state $items
    }
    $destination = if ($context.config['folderId']) { $context.config.folderId } else { $context.config.folderName }
    if (-not $PSCmdlet.ShouldProcess($state.workspaceName, "Organise owned items in folder $destination; no definitions, ingestion or refresh are changed")) { return }
    Ensure-PocFolder $context $state | Out-Null
    foreach ($resource in $resources) { Set-PocItemFolder $context $state $resource }
    Assert-PocFolderPlacement $state
    $state.folderOrganization = @{ checkedUtc = [DateTimeOffset]::UtcNow.ToString('o'); status = 'Verified' }
    Save-PocState $state $context.statePath
    Write-Host "Owned items are in folder '$($state.folder.name)'. No model refresh or definition update was requested."
}

function Assert-PocAccount {
    param([hashtable]$Config)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Install Azure CLI and sign in before deploying. The installer will not install software or launch sign-in itself.' }
    $accountText = & az account show --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI is not signed in. Run az login --tenant <tenantId> first.' }
    $account = $accountText | ConvertFrom-Json -AsHashtable
    if ($account.tenantId -ne $Config.tenantId) { throw "Signed into the wrong tenant. No resources were changed. Sign into tenant $($Config.tenantId)." }
    $capacities = @(Get-PocCollection "$script:Fabric/capacities")
    $capacity = @($capacities | Where-Object { $_.id -eq $Config.capacityId })
    if ($capacity.Count -ne 1) { throw 'Configured capacity is not visible to this identity. API-created capacity subscriptions require capacity administrator access.' }
    if ($capacity[0].state -ne 'Active') { throw 'Capacity is not Active. The installer will not resume or provision a capacity.' }
    return $capacity[0]
}

function Get-PocState {
    param($Context)
    if (Test-Path -LiteralPath $Context.statePath) {
        $state = Get-Content -LiteralPath $Context.statePath -Raw | ConvertFrom-Json -AsHashtable
        if ($state.tenantId -ne $Context.config.tenantId -or $state.capacityId -ne $Context.config.capacityId -or $state.prefix -ne $Context.config.prefix) {
            throw 'Saved state belongs to another tenant, capacity or prefix. Use a separate state file; no resources were changed.'
        }
        return $state
    }
    return @{
        schemaVersion = 1; deploymentId = [Guid]::NewGuid().ToString()
        tenantId = $Context.config.tenantId; capacityId = $Context.config.capacityId; prefix = $Context.config.prefix
        workspaceId = $Context.config.workspaceId; workspaceName = $Context.config.workspaceName
        workspaceCreated = $false; resources = @{}; sources = @(); sourceInventory = @()
        status = 'NotStarted'; startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Get-PocMarker {
    param([hashtable]$State)
    return "AI-assisted PoC. Deployment $($State.deploymentId). Experimental, not production-ready."
}

function Get-PocHash {
    param($Value)
    function Convert-OrderedValue {
        param($InputValue)
        if ($InputValue -is [Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in @($InputValue.Keys | Sort-Object -CaseSensitive)) { $ordered[$key] = Convert-OrderedValue $InputValue[$key] }
            return $ordered
        }
        if ($InputValue -is [array]) { return ,@(foreach ($item in $InputValue) { Convert-OrderedValue $item }) }
        return $InputValue
    }
    $json = Convert-OrderedValue $Value | ConvertTo-Json -Depth 100 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Wait-PocCapacityAssignment {
    param($Context, [hashtable]$State)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Context.config.operationTimeoutSeconds)
    do {
        $workspace = (Invoke-PocRequest GET "$script:Fabric/workspaces/$($State.workspaceId)").data
        $progress = $workspace['capacityAssignmentProgress']
        if ($workspace['capacityId'] -eq $Context.config.capacityId -and (-not $progress -or $progress -eq 'Completed')) { return $workspace }
        if ($progress -in @('Failed', 'Cancelled')) { throw "Workspace capacity assignment failed: $progress" }
        Start-Sleep 5
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Workspace capacity assignment has not completed within the configured budget. Rerun with the saved state.'
}

function Ensure-PocWorkspace {
    param($Context, [hashtable]$State)
    if ($State.workspaceId) {
        $workspace = (Invoke-PocRequest GET "$script:Fabric/workspaces/$($State.workspaceId)").data
        if ($workspace['capacityId'] -ne $Context.config.capacityId) {
            if ($State.workspaceCreated -and $State['capacityAssignmentRequested']) { return Wait-PocCapacityAssignment $Context $State }
            throw 'Saved/existing workspace is assigned to another capacity. No capacity reassignment is performed for an existing workspace.'
        }
        if ($Context.config['workspaceId'] -and $Context.config.workspaceId -ne $State.workspaceId) { throw 'Config workspaceId disagrees with saved state.' }
        return Wait-PocCapacityAssignment $Context $State
    }
    $matches = @(Get-PocCollection "$script:Fabric/workspaces" | Where-Object { $_.displayName -eq $Context.config.workspaceName })
    if ($matches.Count -gt 0) {
        $owned = @($matches | Where-Object { $_['description'] -eq (Get-PocMarker $State) })
        if ($owned.Count -ne 1) { throw 'Workspace name already exists and is not owned by this deployment. Choose a new name or explicitly configure an existing workspace.' }
        $workspace = $owned[0]
    } else {
        Save-PocState $State $Context.statePath
        $body = @{ displayName = $Context.config.workspaceName; description = (Get-PocMarker $State) }
        $workspace = Wait-PocOperation (Invoke-PocRequest POST "$script:Fabric/workspaces" $body) $Context.config.operationTimeoutSeconds
    }
    $State.workspaceId = $workspace.id
    $State.workspaceCreated = $true
    Save-PocState $State $Context.statePath
    if ($workspace['capacityId'] -ne $Context.config.capacityId) {
        $State.capacityAssignmentRequested = $true
        Save-PocState $State $Context.statePath
        Invoke-PocRequest POST "$script:Fabric/workspaces/$($State.workspaceId)/assignToCapacity" @{ capacityId = $Context.config.capacityId } -Idempotent | Out-Null
    }
    return Wait-PocCapacityAssignment $Context $State
}

function Ensure-PocItem {
    param($Context, [hashtable]$State, [string]$Key, [string]$Collection, [string]$Type, [string]$Name, [hashtable]$Extra = @{})
    $ws = $State.workspaceId
    Write-Host "Ensuring $Type $Name"
    if ($State.resources.ContainsKey($Key)) {
        $tracked = $State.resources[$Key]
        $item = (Invoke-PocRequest GET "$script:Fabric/workspaces/$ws/$Collection/$($tracked.id)").data
        if ($item.type -ne $Type -or $item.displayName -ne $tracked.name) { throw "Tracked $Key was replaced or renamed. Resolve this explicitly before rerunning." }
        Set-PocItemFolder $Context $State $tracked
        return $item
    }
    if ($State['pendingItem'] -and $State.pendingItem.key -eq $Key -and $State.pendingItem['operationUrl']) {
        $status = Invoke-PocRequest GET $State.pendingItem.operationUrl
        if ($status.data.status -in @('Failed', 'Cancelled')) {
            $State.lastFailedCreation = $State.pendingItem
            $State.Remove('pendingItem')
            Save-PocState $State $Context.statePath
            throw 'The previously accepted creation failed. Its details were retained. Resolve the cause and rerun explicitly; no duplicate create was sent.'
        }
        $item = Wait-PocOperation @{ status = 202; headers = @{ Location = $State.pendingItem.operationUrl } } $Context.config.operationTimeoutSeconds
        $State.resources[$Key] = @{ id = $item.id; name = $Name; type = $Type; collection = $Collection; owned = $true }
        $State.Remove('pendingItem')
        Save-PocState $State $Context.statePath
        Set-PocItemFolder $Context $State $State.resources[$Key]
        return $item
    }
    $matches = @(Get-PocCollection "$script:Fabric/workspaces/$ws/items" | Where-Object { $_.type -eq $Type -and $_.displayName -eq $Name })
    if ($matches.Count -gt 0) {
        if ($matches.Count -ne 1 -or $matches[0]['description'] -ne (Get-PocMarker $State)) { throw "Unowned item name collision: $Name. Nothing will be overwritten." }
        $item = $matches[0]
    } else {
        $body = @{ displayName = $Name; description = (Get-PocMarker $State) }
        if ($State['folder']) { $body.folderId = $State.folder.id }
        foreach ($keyName in $Extra.Keys) { $body[$keyName] = $Extra[$keyName] }
        $State['pendingItem'] = @{ key = $Key; name = $Name; type = $Type; collection = $Collection }
        Save-PocState $State $Context.statePath
        $created = Invoke-PocRequest POST "$script:Fabric/workspaces/$ws/$Collection" $body
        if ($created.status -eq 202) {
            $State.pendingItem.operationUrl = Get-PocOperationUrl $created
            Save-PocState $State $Context.statePath
        }
        $item = Wait-PocOperation $created $Context.config.operationTimeoutSeconds
    }
    $State.resources[$Key] = @{ id = $item.id; name = $Name; type = $Type; collection = $Collection; owned = $true }
    $State.Remove('pendingItem')
    Save-PocState $State $Context.statePath
    Set-PocItemFolder $Context $State $State.resources[$Key]
    return $item
}

function Get-PocDefinitionPart {
    param([string]$Path, [string]$Content)
    return @{ path = $Path; payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content)); payloadType = 'InlineBase64' }
}

function Get-PocDefinition {
    param([string]$Directory, [hashtable]$Replacements = @{}, [string]$Format = '')
    $parts = @(
        foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse | Sort-Object FullName) {
            if ($file.Name -in @('.platform', 'definition.json') -or $file.Extension -in @('.bak', '.pbix')) { continue }
            $relative = [IO.Path]::GetRelativePath($Directory, $file.FullName).Replace('\', '/')
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            if ($Replacements.Count -gt 0 -and $file.Extension -notin @('.png', '.jpg', '.jpeg')) {
                $content = [Text.Encoding]::UTF8.GetString($bytes)
                foreach ($old in $Replacements.Keys) { $content = $content.Replace($old, [string]$Replacements[$old]) }
                $bytes = [Text.Encoding]::UTF8.GetBytes($content)
            }
            @{ path = $relative; payload = [Convert]::ToBase64String($bytes); payloadType = 'InlineBase64' }
        }
    )
    $definition = @{ parts = $parts }
    if ($Format) { $definition.format = $Format }
    return $definition
}

function Invoke-PocKusto {
    param([string]$Endpoint, [string]$Database, [string]$Text, [switch]$Management)
    Assert-PocEndpoint $Endpoint
    $api = if ($Management) { 'mgmt' } else { 'query' }
    $response = Invoke-PocRequest POST "$($Endpoint.TrimEnd('/'))/v1/rest/$api" @{ db = $Database; csl = $Text } -Audience 'https://kusto.kusto.windows.net' -Idempotent
    $body = $response.data
    if ($body['error'] -or $body['Exceptions']) { throw ($body | ConvertTo-Json -Depth 8) }
    $tables = @($body['Tables'])
    foreach ($table in $tables) {
        if ($table['TableName'] -eq 'QueryStatus') {
            $severityIndex = [Array]::IndexOf(@($table.Columns | ForEach-Object { $_.ColumnName }), 'Severity')
            if ($severityIndex -ge 0 -and @($table.Rows | Where-Object { [int]$_[$severityIndex] -le 2 }).Count -gt 0) { throw 'Kusto reported a partial query failure. Results were not accepted.' }
        }
    }
    if ($tables.Count -eq 0) { return ,@() }
    $primary = $tables[0]
    $rows = @(
        foreach ($row in $primary.Rows) {
            $record = @{}
            for ($i = 0; $i -lt $primary.Columns.Count; $i++) { $record[$primary.Columns[$i].ColumnName] = $row[$i] }
            $record
        }
    )
    return ,$rows
}

function ConvertTo-PocKqlLiteral {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace('\', '\\').Replace("'", "\'").Replace("`n", '\n').Replace("`r", '\r') + "'"
}

function New-PocFunctions {
    param([hashtable]$Config, [array]$Sources, [int]$ConfiguredSourceCount)
    $references = @(
        foreach ($source in $Sources) {
            Assert-PocEndpoint $source.endpoint
            'cluster(' + (ConvertTo-PocKqlLiteral $source.endpoint.TrimEnd('/')) + ').database(' + (ConvertTo-PocKqlLiteral $source.database) + ').SemanticModelLogs'
        }
    ) | Sort-Object -Unique
    $logs = if (@($references).Count -gt 0) {
        'union ' + ((@($references) | ForEach-Object { '(' + $_ + ')' }) -join ",`n    ")
    } else {
        'datatable(Timestamp:datetime,OperationName:string,ItemId:string,ItemName:string,WorkspaceId:string,WorkspaceName:string,CapacityId:string,OperationId:string,CorrelationId:string,ApplicationName:string,ApplicationContext:dynamic,ExecutingUser:string,Identity:dynamic,User:string,DurationMs:long,CpuTimeMs:long,Status:string,EventText:string,ReplicaId:string) []'
    }
    $seen = @{}
    $map = @(
        foreach ($mapping in @($Config.identityMappings)) {
            $key = ($mapping.type + '|' + $mapping.value).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { throw 'Duplicate identity mapping.' }
            $seen[$key] = $true
            (ConvertTo-PocKqlLiteral $key) + ', ' + (ConvertTo-PocKqlLiteral $mapping.label)
        }
    ) -join ",`n    "
    $template = Get-Content -LiteralPath (Join-Path $script:Root 'src\kql\observability.template.kql') -Raw
    $template = $template.Replace('__CAPACITY_ID__', (ConvertTo-PocKqlLiteral $Config.capacityId.ToLowerInvariant())).Replace('__LOOKBACK_DAYS__', [string]$Config.lookbackDays).Replace('__SOURCE_COUNT__', [string]$ConfiguredSourceCount).Replace('__LOG_SOURCES__', $logs).Replace('__IDENTITY_MAPPINGS__', $map)
    if ($template -match '__[A-Z_]+__') { throw 'KQL template still contains unresolved parameters.' }
    return $template
}

function Set-PocFunctions {
    param($Context, [hashtable]$State)
    $text = New-PocFunctions $Context.config @($State.sources) @($State.sourceInventory).Count
    $hash = Get-PocHash $text
    if ($State['functionHash'] -eq $hash) { return }
    foreach ($block in [regex]::Split($text, '\r?\n\s*\r?\n(?=\.create-or-alter function)')) {
        if ($block.Trim()) { Invoke-PocKusto $State.endpoint $State.database $block.Trim() -Management | Out-Null }
    }
    $State.functionHash = $hash
    Save-PocState $State $Context.statePath
}

function Update-PocSources {
    param($Context, [hashtable]$State)
    $desired = @($Context.config.monitoring.sources)
    if ($State.resources.ContainsKey('monitoring')) {
        $items = @(Get-PocCollection "$script:Fabric/workspaces/$($State.workspaceId)/items")
        $monitoringName = $State.resources.monitoring.name
        $houses = @($items | Where-Object { $_.type -eq 'Eventhouse' -and $_.displayName -eq "${monitoringName}_Eventhouse" })
        if ($houses.Count -ne 1) { throw 'The owned Monitoring Item backing Eventhouse is not unambiguously discoverable. Wait for provisioning or specify an existing source explicitly; no database was guessed.' }
        $databaseItems = @($items | Where-Object { $_.type -eq 'KQLDatabase' -and $_.id -ne $State.resources.database.id })
        foreach ($item in $databaseItems) {
            $database = (Invoke-PocRequest GET "$script:Fabric/workspaces/$($State.workspaceId)/kqlDatabases/$($item.id)").data
            if ($database.properties.parentEventhouseItemId -eq $houses[0].id) {
                $desired += @{ endpoint = $database.properties.queryServiceUri; database = $database.id; workspaceId = $State.workspaceId }
            }
        }
    }
    $ready = @()
    $inventory = @()
    $seen = @{}
    foreach ($source in $desired) {
        $key = $source.endpoint.TrimEnd('/').ToLowerInvariant() + '|' + $source.database.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $tables = Invoke-PocKusto $source.endpoint $source.database ".show tables | where TableName == 'SemanticModelLogs' | project TableName" -Management
        if ($tables.Count -eq 0) {
            $inventory += @{ endpoint = $source.endpoint; database = $source.database; status = 'WaitingForSemanticModelLogs'; checkedUtc = [DateTimeOffset]::UtcNow.ToString('o') }
            Write-Warning 'A configured monitoring database is reachable but has no SemanticModelLogs table yet. No AI coverage is claimed for it.'
            continue
        }
        $schema = Invoke-PocKusto $source.endpoint $source.database '.show table SemanticModelLogs schema as json' -Management
        $schemaJson = [string]$schema[0]['Schema']
        if (-not $schemaJson) { throw 'Monitoring schema response did not contain Schema. This monitoring version needs investigation.' }
        $parsed = $schemaJson | ConvertFrom-Json -AsHashtable
        $columns = @($parsed.OrderedColumns | ForEach-Object { $_.Name })
        foreach ($column in @('Timestamp', 'OperationName', 'ItemId', 'ItemName', 'WorkspaceId', 'WorkspaceName', 'CapacityId', 'OperationId', 'CorrelationId')) {
            if ($column -notin $columns) { throw "Incompatible monitoring schema: missing $column. No source was silently ignored." }
        }
        Invoke-PocKusto $source.endpoint $source.database 'SemanticModelLogs | take 1 | project Timestamp' | Out-Null
        $ready += $source
        $inventory += @{ endpoint = $source.endpoint; database = $source.database; status = 'Ready'; columns = $columns; checkedUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    }
    $State.sources = $ready
    $State.sourceInventory = $inventory
    Save-PocState $State $Context.statePath
}

function Set-PocModelDefinition {
    param($Context, [hashtable]$State)
    $replacements = @{
        'https://example.kusto.fabric.microsoft.com' = $State.endpoint
        '00000000-0000-0000-0000-000000000000' = $State.database
    }
    $definition = Get-PocDefinition (Join-Path $script:Root 'src\model') $replacements 'TMDL'
    $hash = Get-PocHash $definition
    $model = Ensure-PocItem $Context $State 'model' 'semanticModels' 'SemanticModel' "$($State.prefix)_Model" @{ definition = $definition }
    if ($State['modelDefinitionApplied'] -and $State['modelDefinitionHash'] -ne $hash) {
        Wait-PocOperation (Invoke-PocRequest POST "$script:Fabric/workspaces/$($State.workspaceId)/semanticModels/$($model.id)/updateDefinition" @{ definition = $definition } -Idempotent) $Context.config.operationTimeoutSeconds -NoResult
    }
    $State.modelDefinitionApplied = $true
    $State.modelDefinitionHash = $hash
    Save-PocState $State $Context.statePath
}

function Ensure-PocConnection {
    param($Context, [hashtable]$State)
    if ($State.resources.ContainsKey('connection')) {
        $connection = (Invoke-PocRequest GET "$script:Fabric/connections/$($State.resources.connection.id)").data
    } elseif ($Context.config['existingConnectionId']) {
        $connection = (Invoke-PocRequest GET "$script:Fabric/connections/$($Context.config.existingConnectionId)").data
        $State.resources.connection = @{ id = $connection.id; name = $connection.displayName; owned = $false; type = 'Connection'; collection = 'connections' }
        Save-PocState $State $Context.statePath
    } else {
        $types = @(Get-PocCollection "$script:Fabric/connections/supportedConnectionTypes?showAllCreationMethods=true")
        $connector = @($types | Where-Object { $_.type -eq 'AzureDataExplorer' })
        if ($connector.Count -ne 1 -or 'WorkspaceIdentity' -notin $connector[0].supportedCredentialTypes) { throw 'AzureDataExplorer does not advertise WorkspaceIdentity support. Create a suitable cloud connection explicitly; no personal credential fallback was used.' }
        $method = @($connector[0].creationMethods | Where-Object { $_.name -eq 'AzureDataExplorer.Contents' })
        if ($method.Count -ne 1) { throw 'Expected AzureDataExplorer.Contents connection creation metadata was not found.' }
        $required = @($method[0].parameters | Where-Object { $_.required } | ForEach-Object { $_.name })
        if (@($required | Where-Object { $_ -notin @('cluster', 'database') }).Count -gt 0) { throw 'The connector now requires unsupported connection parameters. Update this PoC rather than guessing.' }
        $name = "$($State.prefix)_$($State.deploymentId.Substring(0,8))_Connection"
        $connections = @(Get-PocCollection "$script:Fabric/connections")
        $matches = @($connections | Where-Object { $_.displayName -eq $name })
        if ($matches.Count -gt 1) { throw 'Connection name is ambiguous.' }
        if ($matches.Count -eq 1) { $connection = $matches[0] }
        else {
            $body = @{
                connectivityType = 'ShareableCloud'; displayName = $name; privacyLevel = 'Organizational'
                connectionDetails = @{
                    type = 'AzureDataExplorer'; creationMethod = 'AzureDataExplorer.Contents'
                    parameters = @(
                        @{ dataType = 'Text'; name = 'cluster'; value = $State.endpoint },
                        @{ dataType = 'Text'; name = 'database'; value = $State.database }
                    )
                }
                credentialDetails = @{
                    singleSignOnType = 'None'; connectionEncryption = 'NotEncrypted'; skipTestConnection = $false
                    credentials = @{ credentialType = 'WorkspaceIdentity' }
                }
            }
            $connection = (Invoke-PocRequest POST "$script:Fabric/connections" $body).data
        }
        $State.resources.connection = @{ id = $connection.id; name = $connection.displayName; owned = $true; type = 'Connection'; collection = 'connections' }
        Save-PocState $State $Context.statePath
    }
    if ($connection.connectionDetails.type -ne 'AzureDataExplorer') { throw 'Connection type is not AzureDataExplorer.' }
    if ($connection.connectionDetails.path.TrimEnd('/') -ne $State.endpoint.TrimEnd('/')) { throw 'Cloud connection points at another endpoint. Nothing was rebound.' }
    $sourceResponse = Invoke-PocRequest GET "$script:PowerBI/groups/$($State.workspaceId)/datasets/$($State.resources.model.id)/datasources" -Audience 'https://analysis.windows.net/powerbi/api'
    $references = @($sourceResponse.data['value'])
    if ($references.Count -eq 0) { throw 'Semantic model returned no data-source references to bind.' }
    foreach ($reference in $references) {
        $source = $reference['connectionDetails']
        if (-not $source -or $source['kind'] -ne 'AzureDataExplorer' -or -not $source['path']) { throw 'Unexpected model data-source reference. Binding was not guessed.' }
        if ($source.path.TrimEnd('/') -ne $State.endpoint.TrimEnd('/')) { throw 'Model source does not match the observability endpoint.' }
        $details = @{ type = $source.kind; path = $source.path }
        Invoke-PocRequest POST "$script:Fabric/workspaces/$($State.workspaceId)/semanticModels/$($State.resources.model.id)/bindConnection" @{
            connectionBinding = @{ id = $connection.id; connectivityType = 'ShareableCloud'; connectionDetails = $details }
        } -Idempotent | Out-Null
    }
}

function Invoke-PocRefresh {
    param($Context, [hashtable]$State)
    $base = "$script:PowerBI/groups/$($State.workspaceId)/datasets/$($State.resources.model.id)"
    if (-not $State['pendingRefresh']) {
        $requestedAt = [DateTimeOffset]::UtcNow
        $request = Invoke-PocRequest POST "$base/refreshes" @{ type = 'Full'; notifyOption = 'NoNotification' } -Audience 'https://analysis.windows.net/powerbi/api'
        $location = [string]@($request.headers['Location'])[0]
        $State.pendingRefresh = @{ requestedUtc = $requestedAt.ToString('o'); location = $location }
        Save-PocState $State $Context.statePath
    } else {
        $requestedAt = [DateTimeOffset]::Parse($State.pendingRefresh.requestedUtc)
        $location = $State.pendingRefresh.location
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Context.config.operationTimeoutSeconds)
    do {
        Start-Sleep 5
        $history = (Invoke-PocRequest GET "$base/refreshes?`$top=1" -Audience 'https://analysis.windows.net/powerbi/api').data
        $runs = @($history['value'])
        if ($runs.Count -eq 0) { continue }
        $latest = $runs[0]
        if (-not $latest['startTime'] -or [DateTimeOffset]$latest.startTime -lt $requestedAt.AddSeconds(-5)) { continue }
        if ($latest.status -eq 'Completed') {
            $State.lastRefreshUtc = $latest.endTime
            $State.Remove('pendingRefresh')
            Save-PocState $State $Context.statePath
            return
        }
        if ($latest.status -in @('Failed', 'Disabled', 'Cancelled')) {
            $State.lastFailedRefresh = $latest
            $State.Remove('pendingRefresh')
            Save-PocState $State $Context.statePath
            throw "Import refresh failed: $($latest | ConvertTo-Json -Depth 8 -Compress)"
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Import refresh did not finish within the configured budget. Refresh location: $location"
}

function Invoke-PocDax {
    param([hashtable]$State, [string]$Query)
    $response = Invoke-PocRequest POST "$script:PowerBI/groups/$($State.workspaceId)/datasets/$($State.resources.model.id)/executeQueries" @{
        queries = @(@{ query = $Query }); serializerSettings = @{ includeNulls = $true }
    } -Audience 'https://analysis.windows.net/powerbi/api' -Idempotent
    if ($response.data['error']) { throw ($response.data.error | ConvertTo-Json -Depth 10) }
    $results = @($response.data.results)
    foreach ($result in $results) { if ($result['error']) { throw ($result.error | ConvertTo-Json -Depth 10) } }
    if ($results.Count -eq 0 -or @($results[0]['tables']).Count -eq 0) { throw 'DAX returned no result table.' }
    return ,@($results[0].tables[0].rows)
}

function Ensure-PocReport {
    param($Context, [hashtable]$State)
    $definition = Get-PocDefinition (Join-Path $script:Root 'src\report') @{ '00000000-0000-0000-0000-000000000000' = $State.resources.model.id } 'PBIR'
    $hash = Get-PocHash $definition
    $report = Ensure-PocItem $Context $State 'report' 'reports' 'Report' "$($State.prefix)_Report_PoC" @{ definition = $definition }
    if ($State['reportDefinitionApplied'] -and $State['reportDefinitionHash'] -ne $hash) {
        Wait-PocOperation (Invoke-PocRequest POST "$script:Fabric/workspaces/$($State.workspaceId)/reports/$($report.id)/updateDefinition" @{ definition = $definition } -Idempotent) $Context.config.operationTimeoutSeconds -NoResult
    }
    $State.reportDefinitionApplied = $true
    $State.reportDefinitionHash = $hash
    $State.reportUrl = "https://app.powerbi.com/groups/$($State.workspaceId)/reports/$($report.id)"
    Save-PocState $State $Context.statePath
}

function Start-PocDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Config)
    $context = Read-PocConfig $Config
    $capacity = Assert-PocAccount $context.config
    $plan = @(
        'Experimental AI-assisted PoC. Uses capacity and storage. No accuracy or production-support commitment.',
        "Target capacity: $($capacity.displayName) ($($capacity.sku)), region $($capacity.region). No new capacity will be created.",
        "Workspace mode: $($context.config.createWorkspace); monitoring mode: $($context.config.monitoring.mode). Tenant switches will not be changed.",
        "Destination folder: name '$($context.config['folderName'])', existing ID '$($context.config['folderId'])'. Empty selections retain workspace-root deployment.",
        "Creates owned Eventhouse, capacity Eventstream, Import model, report and workspace-identity cloud connection.",
        "Raw retention: $($context.config.retentionDays) days; hot cache: $($context.config.cacheDays) days. Monitoring may contain identities and query text.",
        'Scheduled refresh is not enabled. Existing source-workspace permissions are not changed.',
        "Private deployment state: $($context.statePath)"
    )
    $plan | ForEach-Object { Write-Host $_ }
    if (-not $PSCmdlet.ShouldProcess($context.config.workspaceName, 'Deploy Fabric IQ monitoring PoC')) { return }
    $state = Get-PocState $context
    $state.status = 'Deploying'
    Save-PocState $state $context.statePath
    $workspace = Ensure-PocWorkspace $context $state
    $state.workspaceName = $workspace.displayName
    Ensure-PocFolder $context $state | Out-Null
    $identity = $workspace['workspaceIdentity']
    if (-not $identity -and $state['identity']) { $identity = $state.identity }
    if (-not $identity) {
        $identity = Wait-PocOperation (Invoke-PocRequest POST "$script:Fabric/workspaces/$($state.workspaceId)/provisionIdentity") $context.config.operationTimeoutSeconds
        if (-not $identity -or -not $identity['servicePrincipalId']) {
            $workspace = (Invoke-PocRequest GET "$script:Fabric/workspaces/$($state.workspaceId)").data
            $identity = $workspace['workspaceIdentity']
        }
        $state.identityCreated = $true
    }
    if (-not $identity -or -not $identity['servicePrincipalId']) { throw 'Workspace identity has not finished provisioning. Rerun after it is available.' }
    $state.identity = $identity
    $roles = @(Get-PocCollection "$script:Fabric/workspaces/$($state.workspaceId)/roleAssignments")
    if (@($roles | Where-Object { $_.principal.id -eq $identity.servicePrincipalId -and $_.role -in @('Admin','Member','Contributor') }).Count -eq 0) {
        Invoke-PocRequest POST "$script:Fabric/workspaces/$($state.workspaceId)/roleAssignments" @{
            principal = @{ id = $identity.servicePrincipalId; type = 'ServicePrincipal' }; role = 'Contributor'
        } | Out-Null
        $state['identityRoleCreated'] = $true
    }
    Save-PocState $state $context.statePath
    $house = Ensure-PocItem $context $state 'eventhouse' 'eventhouses' 'Eventhouse' "$($state.prefix)_Observability"
    $database = Ensure-PocItem $context $state 'database' 'kqlDatabases' 'KQLDatabase' "$($state.prefix)_ObservabilityDB" @{
        creationPayload = @{ databaseType = 'ReadWrite'; parentEventhouseItemId = $house.id }
    }
    $database = (Invoke-PocRequest GET "$script:Fabric/workspaces/$($state.workspaceId)/kqlDatabases/$($database.id)").data
    $state.endpoint = $database.properties.queryServiceUri.TrimEnd('/')
    $state.database = $database.id
    Save-PocState $state $context.statePath
    $schema = Get-Content -LiteralPath (Join-Path $script:Root 'src\kql\schema.kql') -Raw
    foreach ($block in [regex]::Split($schema, '\r?\n\s*\r?\n(?=\.)')) {
        if ($block.Trim()) { Invoke-PocKusto $state.endpoint $state.database $block.Trim() -Management | Out-Null }
    }
    Invoke-PocKusto $state.endpoint $state.database ".alter-merge table CapacityOperationEventsRaw policy retention softdelete = $($context.config.retentionDays)d recoverability = enabled" -Management | Out-Null
    Invoke-PocKusto $state.endpoint $state.database ".alter table CapacityOperationEventsRaw policy caching hot = $($context.config.cacheDays)d" -Management | Out-Null
    if ($context.config.monitoring.mode -eq 'Create') {
        $monitoringDefinition = @{ format = 'MonitoringV1'; parts = @(
            Get-PocDefinitionPart 'MonitoringProperties.json' (Get-Content -LiteralPath (Join-Path $script:Root 'src\monitoring.json') -Raw)
        ) }
        $monitor = Ensure-PocItem $context $state 'monitoring' 'monitoringItems' 'Monitoring' "$($state.prefix)_Monitoring" @{ definition = $monitoringDefinition }
        Invoke-PocRequest POST "$script:Fabric/workspaces/$($state.workspaceId)/monitoringItems/$($monitor.id)/enableDataCollection" -Idempotent | Out-Null
        $check = (Invoke-PocRequest GET "$script:Fabric/workspaces/$($state.workspaceId)/monitoringItems/$($monitor.id)").data
        if ($check.properties.dataCollectionState -ne 'Enabled') { throw 'Monitoring collection is not enabled. Definition creation alone is not success.' }
    }
    $topology = @{
        compatibilityLevel = '1.1'
        sources = @(@{ name = 'CapacityOperations'; type = 'FabricCapacityOperationEvents'; properties = @{
            eventScope = 'Capacity'; capacityId = $context.config.capacityId
            includedEventTypes = @('Microsoft.Fabric.CapacityOperationEvents.Operation'); filters = @()
        } })
        streams = @(@{ name = 'CapacityOperationStream'; type = 'DefaultStream'; properties = @{}; inputNodes = @(@{ name = 'CapacityOperations' }) })
        operators = @(@{
            name = 'PreserveCloudEventEnvelope'; type = 'SQL'
            inputNodes = @(@{ name = 'CapacityOperationStream' })
            properties = @{
                query = 'SELECT c AS [Event] INTO [CapacityOperationEnvelopeDestination] FROM [CapacityOperationStream] AS c'
                advancedSettings = @{
                    eventsOutOfOrderPolicy = 'Adjust'; eventsOutOfOrderMaxDelayInSeconds = 0
                    eventsLateArrivalMaxDelayInSeconds = 300
                }
            }
        })
        destinations = @(@{ name = 'CapacityOperationEnvelopeDestination'; type = 'Eventhouse'; properties = @{
            dataIngestionMode = 'ProcessedIngestion'
            workspaceId = $state.workspaceId; itemId = $state.database; databaseName = $state.database
            tableName = 'CapacityOperationEventsRaw'
            inputSerialization = @{ type = 'Json'; properties = @{ encoding = 'UTF8' } }
        }; inputNodes = @(@{ name = 'PreserveCloudEventEnvelope' }) })
    }
    $streamDefinition = @{ format = 'eventstream'; parts = @(
        Get-PocDefinitionPart 'eventstream.json' ($topology | ConvertTo-Json -Depth 40)
        Get-PocDefinitionPart 'eventstreamProperties.json' '{"retentionTimeInDays":1,"eventThroughputLevel":"Low"}'
    ) }
    $streamHash = Get-PocHash $streamDefinition
    $stream = Ensure-PocItem $context $state 'eventstream' 'eventstreams' 'Eventstream' "$($state.prefix)_CapacityFeed" @{ definition = $streamDefinition }
    if ($state['streamDefinitionApplied'] -and $state['streamDefinitionHash'] -ne $streamHash) {
        Wait-PocOperation (Invoke-PocRequest POST "$script:Fabric/workspaces/$($state.workspaceId)/eventstreams/$($stream.id)/updateDefinition" @{ definition = $streamDefinition } -Idempotent) $context.config.operationTimeoutSeconds -NoResult
    }
    $state.streamDefinitionApplied = $true
    $state.streamDefinitionHash = $streamHash
    Save-PocState $state $context.statePath
    Update-PocSources $context $state
    Set-PocFunctions $context $state
    Set-PocModelDefinition $context $state
    Ensure-PocConnection $context $state
    Invoke-PocRefresh $context $state
    Ensure-PocReport $context $state
    Assert-PocFolderPlacement $state
    $state.status = 'DeployedAwaitingEndToEndValidation'
    if ($state.workspaceCreated -and -not $state['workspaceInventory']) {
        $state.workspaceInventory = @(Get-PocCollection "$script:Fabric/workspaces/$($state.workspaceId)/items" | ForEach-Object { $_.id })
    }
    Save-PocState $state $context.statePath
    Write-Host "Deployed: $($state.reportUrl)"
    Write-Host "Run Test.ps1 with the config to check delivery, query logs, refresh and rerun behaviour. State: $($context.statePath)"
}

function Read-PocDeployment {
    param([string]$Config, [switch]$ForRemoval, [switch]$ForFolder)
    $context = Read-PocConfig $Config
    if ($ForRemoval -or $ForFolder) {
        $account = & az account show --only-show-errors --output json
        if ($LASTEXITCODE -ne 0) { throw 'Azure CLI is not signed in. Sign in to the configured tenant before changing deployment resources.' }
        if (($account | ConvertFrom-Json -AsHashtable).tenantId -ne $context.config.tenantId) {
            throw 'Signed into the wrong tenant. No resources were changed.'
        }
    } else {
        Assert-PocAccount $context.config | Out-Null
    }
    if (-not (Test-Path -LiteralPath $context.statePath)) { throw 'No deployment state exists. Run Deploy.ps1 first.' }
    $state = Get-PocState $context
    if (-not $state.workspaceId) { throw 'The saved deployment has not created or selected a workspace.' }
    return @{ context = $context; state = $state }
}

function Test-PocDeployment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Config, [switch]$GenerateActivity)
    $deployment = Read-PocDeployment $Config
    $context, $state = $deployment.context, $deployment.state
    foreach ($key in @('eventstream', 'model', 'report', 'database', 'connection')) {
        if (-not $state.resources.ContainsKey($key)) { throw "Incomplete installation: $key has not been deployed. Resume Deploy.ps1 using the same state." }
    }
    $checks = [Collections.Generic.List[object]]::new()
    $streamUri = "$script:Fabric/workspaces/$($state.workspaceId)/eventstreams/$($state.resources.eventstream.id)/topology"
    $topology = (Invoke-PocRequest GET $streamUri).data
    foreach ($node in @($topology.sources) + @($topology.destinations)) {
        if ($node['error']) { throw "Eventstream node $($node.name) reports an error: $($node.error | ConvertTo-Json -Depth 8)" }
        if ($node.status -in @('Failed', 'Warning', 'Paused')) { throw "Eventstream node $($node.name) is $($node.status). Running alone would still not prove delivery." }
    }
    $checks.Add(@{ name = 'EventstreamTopology'; status = 'Pass' })
    $expectedItemIds = @($state.resources.Values | Where-Object { $_.type -ne 'Connection' } | ForEach-Object { $_.id })
    $items = @(Get-PocCollection "$script:Fabric/workspaces/$($state.workspaceId)/items")
    foreach ($id in $expectedItemIds) {
        if ($id -notin @($items | ForEach-Object { $_.id })) { throw 'A tracked item is missing from the workspace.' }
    }
    $checks.Add(@{ name = 'TrackedItemsPresent'; status = 'Pass'; count = $expectedItemIds.Count })

    $nonce = if ($GenerateActivity) { 'InstallValidationMarker:' + [Guid]::NewGuid().ToString() } else { $state['validationNonce'] }
    if ($GenerateActivity) {
        $state.validationNonce = $nonce
        $state.validationStartedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Save-PocState $state $context.statePath
        Invoke-PocDax $state ('EVALUATE ROW("Validation", "' + $nonce + '", "Observed operations", [Request count])') | Out-Null
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($context.config.operationTimeoutSeconds)
    $queryOperationId = $null
    $matched = @()
    do {
        Update-PocSources $context $state
        if ($nonce) {
            foreach ($source in @($state.sources)) {
                $query = "SemanticModelLogs | where OperationName == 'QueryEnd' and ItemId =~ " + (ConvertTo-PocKqlLiteral $state.resources.model.id) + " and EventText contains " + (ConvertTo-PocKqlLiteral $nonce) + ' | top 1 by Timestamp desc | project OperationId,Timestamp'
                $logs = Invoke-PocKusto $source.endpoint $source.database $query
                if ($logs.Count -gt 0) { $queryOperationId = $logs[0].OperationId; break }
            }
            if ($queryOperationId) {
                $query = 'CapacityOperationEventsRaw | extend D=Event.data | where tostring(D.itemId) =~ ' + (ConvertTo-PocKqlLiteral $state.resources.model.id) +
                    ' and tostring(D.operationId) =~ ' + (ConvertTo-PocKqlLiteral $queryOperationId) +
                    ' | summarize Records=count(),CUSeconds=sum(todouble(D.capacityUnitMs)/1000.0),Latest=max(todatetime(Event["time"]))'
                $matched = Invoke-PocKusto $state.endpoint $state.database $query
                if ($matched.Count -gt 0 -and $matched[0].Records -gt 0) { break }
            }
        } else { break }
        if (-not $GenerateActivity) { break }
        Write-Host 'Waiting for the identifiable semantic query and its capacity event. No synthetic AI operation was injected.'
        Start-Sleep 15
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $feed = Invoke-PocKusto $state.endpoint $state.database 'CapacityOperationEventsRaw | summarize Rows=count(),Latest=max(todatetime(Event["time"])),LatestIngestion=max(ingestion_time())'
    $fresh = $feed.Count -gt 0 -and $feed[0].Rows -gt 0 -and $feed[0].Latest -and ([DateTimeOffset]$feed[0].Latest -gt [DateTimeOffset]::UtcNow.AddMinutes(-15))
    $checks.Add(@{ name = 'FreshCapacityDelivery'; status = $(if ($fresh) { 'Pass' } else { 'Pending' }) })
    $queryMatch = $matched.Count -gt 0 -and $matched[0].Records -gt 0
    $checks.Add(@{ name = 'RealSemanticQueryCorrelatedToCapacity'; status = $(if ($queryMatch) { 'Pass' } else { 'Pending' }) })
    $sourceReady = @($state.sources).Count -gt 0 -and @($state.sourceInventory | Where-Object { $_.status -ne 'Ready' }).Count -eq 0
    $checks.Add(@{ name = 'MonitoringSchemaAndSources'; status = $(if ($sourceReady) { 'Pass' } else { 'Pending' }) })
    if ($GenerateActivity) {
        Set-PocFunctions $context $state
        Invoke-PocRefresh $context $state
    }
    $numbers = Invoke-PocDax $state 'EVALUATE ROW("Operations",[Request count],"BillableCU",[Billable CU (s)],"AI",[AI operations observed],"QueryLogCoverage",[Query-log coverage],"WorkspaceCoverage",[Query-log workspaces],"Snapshot",[Data as of label])'
    $checks.Add(@{ name = $(if ($GenerateActivity) { 'ImportRefreshAndDax' } else { 'DaxSnapshotReadable' }); status = 'Pass' })
    $scope = Invoke-PocDax $state 'EVALUATE UNION(ROW("Scope","All","Count",[Request count]),CALCULATETABLE(ROW("Scope","AI","Count",[Request count]),Requests[Usage type]="AI queries"),CALCULATETABLE(ROW("Scope","Other","Count",[Request count]),Requests[Usage type]="Other workloads"))'
    $all = @($scope | Where-Object { $_['[Scope]'] -eq 'All' })[0]['[Count]']
    $ai = @($scope | Where-Object { $_['[Scope]'] -eq 'AI' })[0]['[Count]']
    $other = @($scope | Where-Object { $_['[Scope]'] -eq 'Other' })[0]['[Count]']
    if ($all -ne ($ai + $other)) { throw 'AI and Other filters do not partition the observed operations.' }
    $checks.Add(@{ name = 'AiFilterPartition'; status = 'Pass' })
    $reconcile = Invoke-PocKusto $state.endpoint $state.database 'let a=ObservabilityCharges() | summarize ChargeCU=sumif(CUSeconds,CostValid and BillingType=="Billable"); let b=ObservabilityRequests() | summarize RequestCU=sum(BillableCU); a | extend K=1 | join kind=inner (b | extend K=1) on K | project ChargeCU,RequestCU'
    if ($reconcile.Count -ne 1 -or [Math]::Abs($reconcile[0].ChargeCU - $reconcile[0].RequestCU) -gt 0.001) { throw 'Request and charge CU totals do not reconcile.' }
    $checks.Add(@{ name = 'CuReconciliation'; status = 'Pass' })
    $fixture = Get-Content -LiteralPath (Join-Path $script:Root 'tests\classification.kql') -Raw
    $classification = Invoke-PocKusto $state.endpoint $state.database $fixture
    if ($classification.Count -ne 1 -or $classification[0].Failures -ne 0) { throw 'AI prefix classification fixtures failed.' }
    $checks.Add(@{ name = 'SyntheticPrefixFixturesOnly'; status = 'Pass' })
    $schedule = (Invoke-PocRequest GET "$script:PowerBI/groups/$($state.workspaceId)/datasets/$($state.resources.model.id)/refreshSchedule" -Audience 'https://analysis.windows.net/powerbi/api').data
    if ($schedule['enabled']) { throw 'Scheduled refresh is enabled unexpectedly.' }
    $checks.Add(@{ name = 'ScheduleRemainsOff'; status = 'Pass' })
    $checks.Add(@{ name = 'GenuineFabricIqConversation'; status = 'NotTested'; reason = 'An ordinary executeQueries request is not a real Fabric IQ conversation. Prefix fixtures are not a substitute.' })
    $state.validation = @{ checkedUtc = [DateTimeOffset]::UtcNow.ToString('o'); checks = $checks.ToArray(); aggregate = $numbers }
    $pending = @($checks | Where-Object { $_.status -eq 'Pending' }).Count
    $state.status = if ($pending -eq 0) { 'PlatformSmokePassedAiConversationNotTested' } else { 'DeployedWithPendingValidation' }
    Save-PocState $state $context.statePath
    $checks | ForEach-Object { [pscustomobject]$_ } | Format-Table name, status -AutoSize | Out-Host
    Write-Host "Status: $($state.status). This does not certify production readiness. Detailed results stay in the ignored state file."
    if ($pending -gt 0) { throw 'Some delivery/source checks remain pending. The deployment has not been declared end-to-end ready.' }
}

function Remove-PocDeployment {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$Config, [switch]$DeleteWorkspace, [string]$ConfirmWorkspaceName, [switch]$DeleteConnection)
    $deployment = Read-PocDeployment $Config -ForRemoval
    $context, $state = $deployment.context, $deployment.state
    if (-not $ConfirmWorkspaceName -or $ConfirmWorkspaceName -cne $state.workspaceName) { throw 'Supply the exact saved workspace name using -ConfirmWorkspaceName.' }
    if ($DeleteConnection -and $state.resources.ContainsKey('connection') -and -not $state.resources.connection.owned) {
        throw 'The reused connection is not owned by this deployment and will never be deleted. No resources were removed.'
    }
    $workspaceResponse = Invoke-PocRequest GET "$script:Fabric/workspaces/$($state.workspaceId)" -AllowNotFound
    if ($workspaceResponse.status -eq 404) {
        Write-Host 'Workspace is already absent. No workspace delete was sent.'
    } elseif ($DeleteWorkspace) {
        if (-not $state.workspaceCreated -or $workspaceResponse.data['description'] -ne (Get-PocMarker $state)) { throw 'Refusing to delete a workspace not created and marked by this deployment.' }
        if (-not $state['workspaceInventory']) { throw 'The installer has not recorded a final workspace inventory. Inspect a partial deployment and remove its owned items individually instead.' }
        $items = @(Get-PocCollection "$script:Fabric/workspaces/$($state.workspaceId)/items")
        $foreign = @($items | Where-Object { $_.id -notin @($state.workspaceInventory) })
        if ($foreign.Count -gt 0) { throw 'Untracked items were added after deployment. Whole-workspace deletion is refused to protect them.' }
        if ($PSCmdlet.ShouldProcess($state.workspaceName, 'Delete this entire installer-owned test workspace and its data')) {
            Invoke-PocRequest DELETE "$script:Fabric/workspaces/$($state.workspaceId)" -Idempotent | Out-Null
            $state.status = 'WorkspaceDeletionRequested'
            Save-PocState $state $context.statePath
        }
    } else {
        $removalKeys = @('report', 'model', 'eventstream', 'monitoring', 'database', 'eventhouse')
        $foundItems = @{}
        foreach ($key in $removalKeys) {
            if (-not $state.resources.ContainsKey($key) -or -not $state.resources[$key].owned) { continue }
            $resource = $state.resources[$key]
            $uri = "$script:Fabric/workspaces/$($state.workspaceId)/$($resource.collection)/$($resource.id)"
            $found = Invoke-PocRequest GET $uri -AllowNotFound
            if ($found.status -eq 404) { continue }
            if ($found.data['description'] -ne (Get-PocMarker $state)) { throw "Ownership marker changed on $key; no resources were removed." }
            $foundItems[$key] = $found
        }
        if ($foundItems.ContainsKey('monitoring') -or $foundItems.ContainsKey('eventhouse')) {
            if (-not $state['workspaceInventory']) {
                throw 'Parent-item deletion can cascade to generated resources. No saved inventory exists for this partial installation; inspect its dependent items before removing the parent manually. No resources were removed.'
            }
            $items = @(Get-PocCollection "$script:Fabric/workspaces/$($state.workspaceId)/items")
            $foreign = @($items | Where-Object { $_.id -notin @($state.workspaceInventory) })
            if ($foreign.Count -gt 0) {
                throw 'Untracked items were added after deployment. Parent-item removal is refused because it can cascade to their data. No resources were removed.'
            }
        }
        foreach ($key in $removalKeys) {
            if (-not $state.resources.ContainsKey($key) -or -not $state.resources[$key].owned) { continue }
            $resource = $state.resources[$key]
            $uri = "$script:Fabric/workspaces/$($state.workspaceId)/$($resource.collection)/$($resource.id)"
            if (-not $foundItems.ContainsKey($key)) { Write-Host "$key is already absent."; continue }
            if ($PSCmdlet.ShouldProcess($resource.name, 'Delete owned item and its data')) {
                Wait-PocOperation (Invoke-PocRequest DELETE $uri -Idempotent) $context.config.operationTimeoutSeconds -NoResult
                $state.resources[$key]['removed'] = $true
                Save-PocState $state $context.statePath
            }
        }
        $state.status = 'OwnedItemRemovalRequested'
        Save-PocState $state $context.statePath
    }
    if ($state.resources.ContainsKey('connection') -and $DeleteConnection) {
        $connection = $state.resources.connection
        if (-not $connection.owned) { throw 'The reused connection is not owned by this deployment and will never be deleted.' }
        Write-Warning 'Only delete the cloud connection after confirming no other model now uses it.'
        if ($PSCmdlet.ShouldProcess($connection.name, 'Delete the owned cloud connection')) {
            Invoke-PocRequest DELETE "$script:Fabric/connections/$($connection.id)" -Idempotent -AllowNotFound | Out-Null
        }
    } elseif ($state.resources.ContainsKey('connection')) {
        Write-Host 'Cloud connection retained. Use -DeleteConnection only after confirming it has no other consumers.'
    }
    if ($state['folder'] -and -not $DeleteWorkspace) { Write-Host 'Destination folder retained. Remove it manually only when empty and no longer needed.' }
}

Export-ModuleMember -Function *
