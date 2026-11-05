#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot

function Assert-Local {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$scripts = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notlike '*\.state\*' })
foreach ($file in $scripts) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-Local ($errors.Count -eq 0) "PowerShell parse error in $($file.Name): $errors"
}
Import-Module (Join-Path $root 'scripts\FabricIqMonitor.psm1') -Force -DisableNameChecking
$config = Get-Content -LiteralPath (Join-Path $root 'config.example.json') -Raw | ConvertFrom-Json -AsHashtable
$functions = New-PocFunctions $config @() 0
Assert-Local (([regex]::Matches($functions, '\.create-or-alter function')).Count -eq 7) 'Expected seven KQL functions.'
Assert-Local ($functions -notmatch '__[A-Z_]+__') 'Unresolved KQL parameter.'
Assert-Local ($functions.Contains('datatable(Timestamp:datetime')) 'Capacity-only bootstrap must have an explicit typed empty log source.'
Assert-Local ($functions.Contains("let AiSourcePrefix='fabricaihub_mcp_server'")) 'Stable AI prefix is missing.'
Assert-Local (-not $functions.Contains('Sydney')) 'Caller suffix must not control AI classification.'
$sources = @(
    @{ endpoint = 'https://first.kusto.fabric.microsoft.com'; database = 'first' },
    @{ endpoint = 'https://second.kusto.fabric.microsoft.com'; database = "second'quoted" }
)
$functions = New-PocFunctions $config $sources 2
Assert-Local ($functions.Contains("MonitoringSourceCount=long(2)")) 'Source count not rendered.'
Assert-Local ($functions.Contains("second\'quoted")) 'KQL string escaping is not safe.'
$blocked = $false
try { Assert-PocEndpoint 'https://example.invalid' } catch { $blocked = $true }
Assert-Local $blocked 'A non-Kusto credential target was accepted.'

$model = Get-PocDefinition (Join-Path $root 'src\model') @{} 'TMDL'
Assert-Local ($model.parts.Count -ge 12) 'Incomplete semantic model package.'
Assert-Local (@($model.parts | Where-Object { $_.path -eq '.platform' }).Count -eq 0) 'Private platform metadata was packaged.'

$pages = Join-Path $root 'src\report\definition\pages'
$pageDefinitions = @(Get-ChildItem -LiteralPath $pages -Recurse -File -Filter page.json)
Assert-Local ($pageDefinitions.Count -eq 4) 'Report must have four pages.'

function Assert-FilterTuple {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            if ($entry.Key -eq 'In' -and $entry.Value -is [Collections.IDictionary] -and $entry.Value.Contains('Values')) {
                foreach ($row in $entry.Value['Values']) {
                    Assert-Local ($row.Count -eq $entry.Value['Expressions'].Count) 'Categorical filter value tuple does not match the field count.'
                }
            }
            Assert-FilterTuple $entry.Value
        }
    } elseif ($Value -is [array]) { foreach ($item in $Value) { Assert-FilterTuple $item } }
}

$detailSlicers = @()
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'src\report') -Recurse -File -Filter *.json) {
    $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    Assert-FilterTuple $json
    if ($file.Name -ne 'visual.json') { continue }
    $position = $json.position
    Assert-Local ($position.x -ge 0 -and $position.y -ge 0 -and $position.x + $position.width -le 1920 -and $position.y + $position.height -le 1080) 'Report visual is outside the canvas.'
    if ($file.FullName -like '*75da004f0b0357cd2a7e*' -and $json.visual.visualType -eq 'slicer') { $detailSlicers += $json }
}
Assert-Local ($detailSlicers.Count -eq 8) 'Operation details must expose eight filters.'
$fields = @($detailSlicers | ForEach-Object { $_.visual.query.queryState.Values.projections[0].queryRef })
Assert-Local ('Requests.Usage type' -in $fields) 'AI-only activity filter is missing.'

$deniedPatterns = @(
    '(?i)C:\\Users\\', 'https://trd-[a-zA-Z0-9-]+\.kusto\.fabric\.microsoft\.com',
    'gh[opusr]_[A-Za-z0-9]{20,}', '-----BEGIN .*PRIVATE KEY-----',
    '(?i)Bearer\s+[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'
)
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $_.FullName -notlike '*\.git\*' -and $_.FullName -notlike '*\.state\*' -and $_.Name -notlike '*.local.json' -and $_.Name -notlike '*.runtime.json' -and $_.Extension -notin @('.png', '.jpg', '.jpeg')
}) {
    if ($file.FullName -eq $PSCommandPath) { continue }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in $deniedPatterns) { Assert-Local (-not ($text -match $pattern)) "Private identifier or credential pattern found in $($file.Name)." }
    $guids = [regex]::Matches($text, '(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b')
    foreach ($guid in $guids) { Assert-Local ($guid.Value -eq '00000000-0000-0000-0000-000000000000') "Non-example GUID found in public asset $($file.Name)." }
}

& (Join-Path $PSScriptRoot 'Test-Lifecycle.ps1')
& (Join-Path $PSScriptRoot 'Test-Folders.ps1')
Write-Host "Local checks passed: $($scripts.Count) PowerShell files, four report pages, eight detail filters, KQL templates and private-data exclusions."
