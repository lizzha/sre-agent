<#
.SYNOPSIS
    Export full SRE Agent configuration into deploy-ready files.

.DESCRIPTION
    Reads ARM child resources and data-plane configuration and emits JSON, YAML,
    and markdown files for Deploy-Agent.ps1 / Apply-Extras.ps1.
    JSON is processed with PowerShell's ConvertFrom-Json and ConvertTo-Json;
    The powershell-yaml module is required for YAML serialization.

    Layout:
      <output>/
        agent.json               - Agent identity + settings
        connectors.json          - Connector toggles + entries (secrets -> env var refs)
        connectors.secrets.env   - Extracted secrets (.gitignored)
        expected-config.json     - Verification spec
        .gitignore
        config/                  - Skills, subagents, tools, hooks, prompts, repos
        automations/             - Scheduled tasks, incident filters, HTTP triggers, platforms
        data/                    - Knowledge, memories, repo instructions, session insights

.PARAMETER Subscription
    Azure subscription ID.

.PARAMETER ResourceGroup
    Resource group containing the agent.

.PARAMETER AgentName
    Agent resource name.

.PARAMETER Output
    Output directory (default: <AgentName>-export).

.PARAMETER Set
    Override identity fields for cloning. Accepts:
      -Set @{ agentName='my-clone'; location='uksouth' }
    Or an array of 'key=value' strings:
      -Set 'agentName=my-clone','location=uksouth'

.PARAMETER IncludeRepoInstructions
    Export repo instruction files (large, off by default).

.PARAMETER IncludeAll
    Enable all include flags.

.PARAMETER NoKnowledge
    Skip knowledge documents.

.PARAMETER NoMemories
    Skip synthesized knowledge and workspace memories.

.PARAMETER NoDownload
    Skip downloading file content (metadata only).

.PARAMETER NoInstallDependencies
    Do not automatically install powershell-yaml when it is missing.

.PARAMETER DryRun
    Show the export summary without writing configuration files.
    Discovery and content downloads still run before the summary.

.EXAMPLE
    .\Export-Agent.ps1 -Subscription <sub> -ResourceGroup <rg> -AgentName <name>
    .\Export-Agent.ps1 -s <sub> -g <rg> -n <name> -Output .\clone -Set @{agentName='clone1';location='uksouth'}
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('s', 'SubscriptionId')]
    [string]$Subscription,

    [Parameter(Mandatory)]
    [Alias('g')]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [Alias('n')]
    [string]$AgentName,

    [Alias('o')]
    [string]$Output,

    [object]$Set,

    [switch]$IncludeRepoInstructions,
    [switch]$IncludeAll,
    [switch]$NoKnowledge,
    [switch]$NoMemories,
    [switch]$NoDownload,
    [switch]$DownloadFiles,
    [switch]$NoInstallDependencies,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Output) { $Output = "${AgentName}-export" }

$INCLUDE_KNOWLEDGE = -not $NoKnowledge
$INCLUDE_KNOWLEDGE_ITEMS = -not $NoKnowledge
$INCLUDE_REPO_INSTRUCTIONS = [bool]$IncludeRepoInstructions
$INCLUDE_MEMORIES = -not $NoMemories
$DOWNLOAD_FILES = -not $NoDownload

if ($IncludeAll) {
    $INCLUDE_KNOWLEDGE = $true
    $INCLUDE_KNOWLEDGE_ITEMS = $true
    $INCLUDE_REPO_INSTRUCTIONS = $true
    $INCLUDE_MEMORIES = $true
}

$SetOverrides = @{}
if ($null -ne $Set) {
    if ($Set -is [System.Collections.IDictionary]) {
        foreach ($k in $Set.Keys) { $SetOverrides[$k] = $Set[$k] }
    } elseif ($Set -is [array] -or $Set -is [string]) {
        foreach ($item in @($Set)) {
            $eqIdx = $item.IndexOf('=')
            if ($eqIdx -gt 0) {
                $SetOverrides[$item.Substring(0, $eqIdx)] = $item.Substring($eqIdx + 1)
            }
        }
    }
}

$API_VERSION = '2025-05-01-preview'
$ARM_BASE = "https://management.azure.com/subscriptions/${Subscription}/resourceGroups/${ResourceGroup}/providers/Microsoft.App/agents/${AgentName}"

# Prerequisites

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host 'Error: PowerShell 7+ is required. Install: https://aka.ms/powershell' -ForegroundColor Red
    exit 1
}

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    if ($NoInstallDependencies) {
        Write-Host 'Error: powershell-yaml is required to write exported YAML files.' -ForegroundColor Red
        Write-Host 'Install it with: Install-Module -Name powershell-yaml -Scope CurrentUser -Repository PSGallery' -ForegroundColor Yellow
        exit 1
    }
    Write-Host 'powershell-yaml is not available; installing it for the current user...'
    try {
        Install-Module -Name powershell-yaml -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
    } catch {
        Write-Host "Error: Could not install powershell-yaml: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Install it with: Install-Module -Name powershell-yaml -Scope CurrentUser -Repository PSGallery' -ForegroundColor Yellow
        Write-Host 'Use -NoInstallDependencies to disable automatic installation.' -ForegroundColor Yellow
        exit 1
    }
}
try {
    Import-Module -Name powershell-yaml -Scope Local -ErrorAction Stop
} catch {
    Write-Host "Error: Could not import powershell-yaml: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host 'Error: az CLI is required. Install: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli' -ForegroundColor Red
    exit 1
}

# Helpers

function _log  { param([string]$Msg) Write-Host "  $Msg" }
function _info { param([string]$Msg) Write-Host "-- $Msg --" -ForegroundColor Cyan }
function _warn { param([string]$Msg) Write-Host "  WARN: $Msg" -ForegroundColor Yellow }
function _fail { param([string]$Msg) Write-Host "  ERROR: $Msg" -ForegroundColor Red; exit 1 }

function Get-ConfigValue {
    param([object]$Object, [string[]]$Paths, [object]$Default = $null)
    foreach ($path in $Paths) {
        $value = $Object
        foreach ($part in $path.Split('.')) {
            if ($null -eq $value) { break }
            if ($value -is [System.Collections.IDictionary]) {
                $value = $value[$part]
            } else {
                $property = $value.PSObject.Properties[$part]
                if ($null -ne $property) {
                    $value = $property.Value
                } else {
                    $value = $null
                }
            }
        }
        if ($null -ne $value) { return ,$value }
    }
    return ,$Default
}

function Set-ConfigValue {
    param([object]$Object, [string]$Name, [AllowNull()][object]$Value)
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Get-ResponseItems {
    param([object]$Response, [string[]]$Paths = @('value'))
    $items = Get-ConfigValue $Response $Paths $Response
    if ($null -eq $items) { return }
    if ($items -is [array]) {
        $items
    } elseif ($items -is [System.Collections.IDictionary]) {
        $items.Values
    } elseif ($items -is [pscustomobject]) {
        $items.PSObject.Properties | ForEach-Object { $_.Value }
    } else {
        $items
    }
}

function Write-Json {
    param([string]$Dest, [AllowNull()][object]$Value)
    ConvertTo-Json -InputObject $Value -Depth 100 |
        Set-Content -LiteralPath $Dest -Encoding utf8
}

function ConvertTo-ExportYamlValue {
    param([AllowNull()][object]$Value)
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        # Preserve the timestamp strings previously passed through JSON to YAML.
        $json = ConvertTo-Json -InputObject $Value -Compress
        $Value = $json.Substring(1, $json.Length - 2)
    }
    if ($Value -is [string]) {
        # YAML 1.1 readers otherwise interpret date-like strings as timestamps.
        if ($Value -match '^\d{4}-\d{1,2}-\d{1,2}(?:$|[Tt \t])') {
            $scalar = [YamlDotNet.RepresentationModel.YamlScalarNode]::new($Value)
            $scalar.Style = 'DoubleQuoted'
            return $scalar
        }
        return $Value
    }
    if ($Value -is [array]) {
        $items = @(foreach ($item in $Value) {
            if ($null -ne $item) { ConvertTo-ExportYamlValue $item }
        })
        return ,$items
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            if ($null -ne $Value[$key]) {
                $yamlKey = ConvertTo-ExportYamlValue $key
                $copy[$yamlKey] = ConvertTo-ExportYamlValue $Value[$key]
            }
        }
        return $copy
    }
    if ($Value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($null -ne $property.Value) {
                $yamlKey = ConvertTo-ExportYamlValue $property.Name
                $copy[$yamlKey] = ConvertTo-ExportYamlValue $property.Value
            }
        }
        return $copy
    }
    return ,$Value
}

function ConvertTo-ExportYaml {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "null`n" }
    $clean = ConvertTo-ExportYamlValue $Value
    $result = powershell-yaml\ConvertTo-Yaml -Data $clean -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($result)) { throw 'powershell-yaml returned empty YAML.' }
    return $result
}

function Write-Yaml {
    param([string]$Dest, [object]$Value)
    ConvertTo-ExportYaml $Value | Set-Content -LiteralPath $Dest -NoNewline -Encoding utf8
}

function Invoke-ArmGet {
    param([string]$Url)
    try {
        $result = (az rest -m GET --url "${Url}?api-version=${API_VERSION}" -o json 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $result) {
            _warn "Could not read ARM resource ${Url}"
            return $null
        }
    } catch {
        _warn "Could not read ARM resource ${Url}: $($_.Exception.Message)"
        return $null
    }
    return ,(ConvertFrom-Json -InputObject $result -NoEnumerate)
}

function Invoke-ArmList {
    param([string]$ChildType)
    $response = Invoke-ArmGet "${ARM_BASE}/${ChildType}"
    $items = Get-ConfigValue $response @('value') @()
    return ,$items
}

$script:DpTokenCache = ''
function Get-DpToken {
    if (-not $script:DpTokenCache) {
        try {
            $script:DpTokenCache = az account get-access-token --resource 'https://azuresre.dev' --query accessToken -o tsv 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $script:DpTokenCache) {
                _fail 'Could not get data-plane token (audience https://azuresre.dev)'
            }
        } catch {
            _fail 'Could not get data-plane token (audience https://azuresre.dev)'
        }
    }
    return $script:DpTokenCache
}

function Invoke-DpGet {
    param([string]$Path)
    $token = Get-DpToken
    try {
        $response = Invoke-WebRequest -Uri "${AGENT_ENDPOINT}${Path}" -Headers @{ Authorization = "Bearer $token" } `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    } catch {
        _warn "Could not read ${Path}: $($_.Exception.Message)"
        return $null
    }
    if (-not $response.Content) { return $null }
    return ,(ConvertFrom-Json -InputObject $response.Content -NoEnumerate)
}

function Invoke-DpDownload {
    param([string]$Path, [string]$Dest)
    $token = Get-DpToken
    $dir = Split-Path -Parent $Dest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try {
        Invoke-WebRequest -Uri "${AGENT_ENDPOINT}${Path}" -Headers @{ Authorization = "Bearer $token" } `
            -UseBasicParsing -OutFile $Dest -ErrorAction Stop
        return $true
    } catch {
        _warn "Could not download ${Path}: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-DpDownloadTarball {
    param([string]$Path, [string]$DestDir, [string]$Label, [int]$Retries = 3)
    $ok = $false
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $token = Get-DpToken
        $tmpfile = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest -Uri "${AGENT_ENDPOINT}${Path}" -Headers @{ Authorization = "Bearer $token" } `
                -UseBasicParsing -OutFile $tmpfile -ErrorAction Stop
            if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
            tar -xzf $tmpfile -C $DestDir 2>$null
            if ($LASTEXITCODE -ne 0) { throw "tar extraction failed (exit code: $LASTEXITCODE)" }
            $count = (Get-ChildItem -Path $DestDir -File -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count
            _log "    Downloaded ${Label}: ${count} file(s) -> ${DestDir}"
            $ok = $true
            break
        } catch {
            _warn "Could not download ${Label} (attempt ${attempt}/${Retries}): $($_.Exception.Message)"
        } finally {
            Remove-Item $tmpfile -Force -ErrorAction SilentlyContinue
        }
        if ($attempt -lt $Retries) {
            _log "    Retry ${attempt}/${Retries} for ${Label} download..."
            Start-Sleep -Seconds (5 * $attempt)
            $script:DpTokenCache = ''
        }
    }
    if (-not $ok) { _warn "Could not download ${Label} after ${Retries} attempts" }
    return $ok
}

function ConvertFrom-OpaqueArm {
    param([object[]]$Resources)
    foreach ($resource in $Resources) {
        $encoded = Get-ConfigValue $resource @('properties.value') ''
        $spec = if ($encoded -eq '') { [pscustomobject]@{} } else {
            $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
            ConvertFrom-Json -InputObject $decoded -NoEnumerate
        }
        [pscustomobject]@{
            metadata = [pscustomobject]@{ name = ($resource.name -split '/')[-1] }
            spec = $spec
        }
    }
}

function ConvertTo-SkillConfig {
    param([string]$Name, [object]$Properties)
    [pscustomobject]@{
        metadata = [pscustomobject]@{
            name = $Name
            description = Get-ConfigValue $Properties @('description') ''
            spec = [pscustomobject]@{ tools = Get-ConfigValue $Properties @('tools') @() }
        }
        skillContent = Get-ConfigValue $Properties @('skillContent') ''
        additionalFiles = Get-ConfigValue $Properties @('additionalFiles') @()
    }
}

function ConvertFrom-SkillsArm {
    param([object[]]$Resources)
    foreach ($resource in $Resources) {
        $decoded = @(ConvertFrom-OpaqueArm @($resource))[0]
        ConvertTo-SkillConfig $decoded.metadata.name $decoded.spec
    }
}

function ConvertTo-ResourceConfig {
    param([object]$Response, [switch]$PreserveProperties, [string]$DefaultType = '')
    foreach ($item in @(Get-ResponseItems $Response)) {
        if ($PreserveProperties) {
            [pscustomobject]@{
                name = Get-ConfigValue $item @('name')
                type = Get-ConfigValue $item @('type') $DefaultType
                tags = Get-ConfigValue $item @('tags') @()
                properties = Get-ConfigValue $item @('properties') ([pscustomobject]@{})
            }
        } else {
            [pscustomobject]@{
                metadata = [pscustomobject]@{ name = Get-ConfigValue $item @('name') }
                spec = Get-ConfigValue $item @('properties') ([pscustomobject]@{})
            }
        }
    }
}

function Invoke-Sanitize {
    param([AllowNull()][object]$Value)
    if ($Value -is [string]) {
        if ($Value -cmatch '^ghp_[A-Za-z0-9_]+$') { return 'EDIT_ME_GITHUB_PAT' }
        if ($Value -cmatch '^Bearer ') { return 'EDIT_ME_BEARER_TOKEN' }
        if ($Value -cmatch '^[A-Za-z0-9+/=]{40,}$' -and $Value -cnotmatch '^/subscriptions/') {
            return 'EDIT_ME_SECRET'
        }
        if ($Value -cmatch 'BearerToken=[^;]+') {
            return [regex]::Replace($Value, 'BearerToken=[^;]+', 'BearerToken=EDIT_ME_TOKEN')
        }
        if ($Value -cmatch 'accessToken') { return 'EDIT_ME_ACCESS_TOKEN' }
        return $Value
    }
    if ($Value -is [array]) {
        $items = @(foreach ($item in $Value) { Invoke-Sanitize $item })
        return ,$items
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[$key] = Invoke-Sanitize $Value[$key] }
        return $copy
    }
    if ($Value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy[$property.Name] = Invoke-Sanitize $property.Value
        }
        return [pscustomobject]$copy
    }
    return ,$Value
}

function Write-ConfigItems {
    param([string]$Dir, [object[]]$Items, [string]$Base = 'config')
    if ($Items.Count -eq 0) { return }
    $targetDir = Join-Path $EXPORT_DIR "$Base/$Dir"
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    foreach ($item in $Items) {
        $name = Get-ConfigValue $item @('metadata.name', 'name')
        Write-Yaml -Dest (Join-Path $targetDir "${name}.yaml") -Value $item
    }
    _log "  ${Dir}: $($Items.Count) file(s)"
}

# Phase 1: ARM - agent core

_info "Connecting to agent ${AgentName} in ${ResourceGroup}"
$AGENT = Invoke-ArmGet $ARM_BASE
if ($null -eq $AGENT) {
    _fail "Agent ${AgentName} not found in ${ResourceGroup} (subscription: ${Subscription})"
}
$AGENT_ENDPOINT = Get-ConfigValue $AGENT @('properties.agentEndpoint')
if (-not $AGENT_ENDPOINT) { _fail 'Agent has no endpoint - may still be provisioning' }

$LOCATION = Get-ConfigValue $AGENT @('location') 'eastus2'
$ACCESS_LEVEL = Get-ConfigValue $AGENT @('properties.actionConfiguration.accessLevel', 'properties.accessLevel') 'Low'
$ACTION_MODE = Get-ConfigValue $AGENT @('properties.actionConfiguration.mode', 'properties.actionMode') 'Review'
$UPGRADE_CHANNEL = Get-ConfigValue $AGENT @('properties.upgradeChannel') 'Preview'
$DEFAULT_MODEL_PROVIDER = Get-ConfigValue $AGENT @('properties.defaultModelProvider') 'Anthropic'
$identities = Get-ConfigValue $AGENT @('identity.userAssignedIdentities') ([pscustomobject]@{})
$identityNames = @($identities.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object -CaseSensitive)
$AGENT_UAMI = if ($identityNames.Count -gt 0) { $identityNames[0] } else { '' }

_log "Location:       ${LOCATION}"
_log "Access level:   ${ACCESS_LEVEL}"
_log "Action mode:    ${ACTION_MODE}"
_log "Endpoint:       ${AGENT_ENDPOINT}"
if ($AGENT_UAMI) { _log "UAMI:           $($AGENT_UAMI.Split('/')[-1])" }

$TARGET_RGS = @(
    foreach ($id in (Get-ConfigValue $AGENT @('properties.knowledgeGraphConfiguration.managedResources') @())) {
        if ($id -cmatch '/resourceGroups/(?<rg>[^/]+)') { $Matches.rg }
    }
) | Sort-Object -Unique -CaseSensitive
$TARGET_RGS = @($TARGET_RGS)
if ($TARGET_RGS.Count -eq 0) {
    $TARGET_RGS = @(
        foreach ($resource in (Get-ConfigValue $AGENT @('properties.managedResources') @())) {
            $type = Get-ConfigValue $resource @('type')
            $scope = Get-ConfigValue $resource @('scope') ''
            if ($type -ceq 'Microsoft.Authorization/roleAssignments' -and $scope -cmatch '/resourceGroups/(?<rg>[^/]+)') {
                $Matches.rg
            }
        }
    ) | Sort-Object -Unique -CaseSensitive
    $TARGET_RGS = @($TARGET_RGS)
}
_log "Target RGs:     $($TARGET_RGS -join ', ')"
Write-Host ''

# Phase 2: ARM - child resources

_info 'Exporting ARM child resources'
_log 'Reading connectors...'
$RAW_CONNECTORS = Invoke-ArmList 'connectors'
_log "  Found $($RAW_CONNECTORS.Count) connector(s) from ARM"
$DP_RESPONSE = Invoke-DpGet '/api/v2/extendedAgent/connectors'
$DP_CONNECTORS = Get-ConfigValue $DP_RESPONSE @('value') @()
_log "  Found $($DP_CONNECTORS.Count) connector(s) from data-plane"

$CONNECTORS = @(
    foreach ($arm in $RAW_CONNECTORS) {
        $name = ($arm.name -split '/')[-1]
        $dp = $DP_CONNECTORS | Where-Object { $_.name -ceq $name } | Select-Object -First 1
        [pscustomobject]@{
            name = $name
            properties = [pscustomobject]@{
                dataConnectorType = Get-ConfigValue $dp @('properties.dataConnectorType') (Get-ConfigValue $arm @('properties.dataConnectorType'))
                dataSource = Get-ConfigValue $dp @('properties.dataSource') (Get-ConfigValue $arm @('properties.dataSource') '')
                extendedProperties = Get-ConfigValue $dp @('properties.extendedProperties') (Get-ConfigValue $arm @('properties.extendedProperties') ([pscustomobject]@{}))
                identity = Get-ConfigValue $dp @('properties.identity') (Get-ConfigValue $arm @('properties.identity') 'system')
            }
        }
    }
)
$CONNECTORS = Invoke-Sanitize $CONNECTORS
$CONNECTOR_COUNT = $CONNECTORS.Count

_log 'Reading tools (ARM)...'
$RAW_TOOLS = Invoke-ArmList 'tools'
$TOOLS = @(
    if ($RAW_TOOLS.Count -gt 0) {
        ConvertFrom-OpaqueArm $RAW_TOOLS
    } else {
        ConvertTo-ResourceConfig (Invoke-DpGet '/api/v2/extendedAgent/tools')
    }
)
$TOOL_COUNT = $TOOLS.Count
_log "  Found ${TOOL_COUNT} tool(s)"

_log 'Reading skills (ARM)...'
$RAW_SKILLS = Invoke-ArmList 'skills'
$SKILLS = @(
    if ($RAW_SKILLS.Count -gt 0) {
        ConvertFrom-SkillsArm $RAW_SKILLS
    } else {
        foreach ($item in @(Get-ResponseItems (Invoke-DpGet '/api/v2/extendedAgent/skills'))) {
            ConvertTo-SkillConfig $item.name (Get-ConfigValue $item @('properties') ([pscustomobject]@{}))
        }
    }
)
$SKILL_COUNT = $SKILLS.Count
_log "  Found ${SKILL_COUNT} skill(s)"

_log 'Reading scheduled tasks (ARM)...'
$RAW_TASKS = Invoke-ArmList 'scheduledTasks'
$SCHEDULED_TASKS = @(
    if ($RAW_TASKS.Count -gt 0) {
        ConvertFrom-OpaqueArm $RAW_TASKS
    } else {
        ConvertTo-ResourceConfig (Invoke-DpGet '/api/v2/extendedAgent/scheduledtasks')
    }
)
$TASK_COUNT = $SCHEDULED_TASKS.Count
_log "  Found ${TASK_COUNT} scheduled task(s)"

_log 'Reading incident filters (ARM)...'
$RAW_FILTERS = Invoke-ArmList 'incidentFilters'
$INCIDENT_FILTERS = @(
    if ($RAW_FILTERS.Count -gt 0) {
        ConvertFrom-OpaqueArm $RAW_FILTERS
    } else {
        ConvertTo-ResourceConfig (Invoke-DpGet '/api/v2/extendedAgent/incidentFilters')
    }
)
$FILTER_COUNT = $INCIDENT_FILTERS.Count
_log "  Found ${FILTER_COUNT} incident filter(s)"

_log 'Reading incident handlers (data-plane)...'
$DP_HANDLERS = @(Get-ResponseItems (Invoke-DpGet '/api/v1/incidentPlayground/handlers'))
_log "  Found $($DP_HANDLERS.Count) incident handler(s)"
foreach ($filter in $INCIDENT_FILTERS) {
    $handler = $DP_HANDLERS | Where-Object {
        (Get-ConfigValue $_ @('incidentFilterId')) -ceq $filter.metadata.name
    } | Select-Object -First 1
    $instructions = Get-ConfigValue $handler @('customInstructions') ''
    if ($instructions -ne '') { Set-ConfigValue $filter.spec 'customInstructions' $instructions }
}

_log 'Reading subagents (ARM)...'
$RAW_SUBAGENTS = Invoke-ArmList 'subagents'
$SUBAGENTS = @(
    if ($RAW_SUBAGENTS.Count -gt 0) {
        ConvertFrom-OpaqueArm $RAW_SUBAGENTS
    } else {
        ConvertTo-ResourceConfig (Invoke-DpGet '/api/v2/extendedAgent/agents')
    }
)
$SUBAGENT_COUNT = $SUBAGENTS.Count
_log "  Found ${SUBAGENT_COUNT} subagent(s)"

_log 'Reading hooks (ARM)...'
$HOOKS_ARM = @(ConvertFrom-OpaqueArm (Invoke-ArmList 'hooks'))
_log 'Reading common prompts (ARM)...'
$PROMPTS_ARM = @(ConvertFrom-OpaqueArm (Invoke-ArmList 'commonPrompts'))
_log 'Reading plugin configs (ARM)...'
$PLUGINS_ARM = @(ConvertFrom-OpaqueArm (Invoke-ArmList 'pluginConfigs'))

# Phase 3: Data plane - extended config

_info 'Exporting data-plane configuration'

$HOOKS_DP = @(ConvertTo-ResourceConfig (Invoke-DpGet '/api/v2/extendedAgent/hooks') -PreserveProperties)
$HOOKS_FOR_PARAMS = $HOOKS_ARM
$HOOKS_FOR_EXTRAS = @()
if ($HOOKS_ARM.Count -eq 0) { $HOOKS_FOR_EXTRAS = $HOOKS_DP }
$ALL_HOOKS = @($HOOKS_FOR_PARAMS) + @($HOOKS_FOR_EXTRAS)
$HOOK_COUNT = $ALL_HOOKS.Count
_log "  Found ${HOOK_COUNT} hook(s) total"

$PROMPTS_DP = @(ConvertTo-ResourceConfig (Invoke-DpGet '/api/v2/extendedAgent/commonprompts') -PreserveProperties)
$PROMPTS_FOR_PARAMS = $PROMPTS_ARM
$PROMPTS_FOR_EXTRAS = @()
if ($PROMPTS_ARM.Count -eq 0) { $PROMPTS_FOR_EXTRAS = $PROMPTS_DP }
$ALL_PROMPTS = @($PROMPTS_FOR_PARAMS) + @($PROMPTS_FOR_EXTRAS)
$PROMPT_COUNT = $ALL_PROMPTS.Count
_log "  Found ${PROMPT_COUNT} common prompt(s) total"

$PLUGINS_DP = @(ConvertTo-ResourceConfig (Invoke-DpGet '/api/v2/extendedAgent/plugins') -PreserveProperties -DefaultType 'plugin')
$PLUGINS_FOR_PARAMS = $PLUGINS_ARM
$PLUGINS_FOR_EXTRAS = @()
if ($PLUGINS_ARM.Count -eq 0) { $PLUGINS_FOR_EXTRAS = $PLUGINS_DP }
$ALL_PLUGINS = @($PLUGINS_FOR_PARAMS) + @($PLUGINS_FOR_EXTRAS)
_log "  Found $($ALL_PLUGINS.Count) plugin config(s) total"

_log 'Reading repos...'
$REPOS = @(
    foreach ($item in @(Get-ResponseItems (Invoke-DpGet '/api/v2/repos/'))) {
        [pscustomobject]@{
            name = Get-ConfigValue $item @('name')
            spec = [pscustomobject]@{
                url = Get-ConfigValue $item @('properties.url') ''
                type = (Get-ConfigValue $item @('properties.type') 'GitHub').ToLowerInvariant()
                branch = Get-ConfigValue $item @('properties.branch') 'main'
            }
        }
    }
)
$REPO_COUNT = $REPOS.Count
_log "  Found ${REPO_COUNT} repo(s)"

_log 'Reading incident platforms...'
$INCIDENT_PLATFORMS = @()
$IM_TYPE = Get-ConfigValue $AGENT @('properties.incidentManagementConfiguration.type') 'None'
if ($IM_TYPE -and $IM_TYPE -ne 'None' -and $IM_TYPE -ne 'null') {
    $INCIDENT_PLATFORMS += [pscustomobject]@{
        name = $IM_TYPE.ToLowerInvariant()
        spec = [pscustomobject]@{ platformType = $IM_TYPE }
    }
}
foreach ($platformType in @('azmonitor', 'pagerduty', 'servicenow')) {
    $result = Invoke-DpGet "/api/v2/incidents/indexing/${platformType}/configuration"
    if ($null -ne $result) {
        $INCIDENT_PLATFORMS += [pscustomobject]@{
            name = $platformType
            spec = Get-ConfigValue $result @('spec', 'properties') $result
        }
    }
}
$INCIDENT_PLATFORM_COUNT = $INCIDENT_PLATFORMS.Count
_log "  Found ${INCIDENT_PLATFORM_COUNT} incident platform(s)"

_log 'Reading plugin marketplaces...'
$PLUGIN_MARKETPLACES = @(
    foreach ($item in @(Get-ResponseItems (Invoke-DpGet '/api/v2/plugins/marketplaces'))) {
        [pscustomobject]@{
            name = Get-ConfigValue $item @('metadata.name', 'name')
            spec = Get-ConfigValue $item @('spec', 'properties') ([pscustomobject]@{})
        }
    }
)
_log "  Found $($PLUGIN_MARKETPLACES.Count) marketplace(s)"

_log 'Reading plugin installations...'
$PLUGIN_INSTALLATIONS = @(
    foreach ($item in @(Get-ResponseItems (Invoke-DpGet '/api/v2/plugins/installations'))) {
        [pscustomobject]@{
            name = Get-ConfigValue $item @('metadata.name', 'name')
            spec = Get-ConfigValue $item @('spec', 'properties') ([pscustomobject]@{})
        }
    }
)
_log "  Found $($PLUGIN_INSTALLATIONS.Count) installation(s)"

_log 'Reading HTTP triggers...'
$triggerResponse = Invoke-DpGet '/api/v1/httpTriggers'
$triggerItems = Get-ConfigValue $triggerResponse @('value') @()
if ($triggerResponse -is [array]) { $triggerItems = $triggerResponse }
$HTTP_TRIGGERS = @(
    foreach ($item in $triggerItems) {
        [pscustomobject]@{
            name = Get-ConfigValue $item @('name') ''
            spec = [pscustomobject]@{
                description = Get-ConfigValue $item @('description') ''
                prompt = Get-ConfigValue $item @('agentPrompt', 'prompt') ''
                handlingAgent = Get-ConfigValue $item @('agent', 'handlingAgent') ''
                agentMode = Get-ConfigValue $item @('agentMode') 'Review'
            }
        }
    }
)
$HTTP_TRIGGER_COUNT = $HTTP_TRIGGERS.Count
_log "  Found ${HTTP_TRIGGER_COUNT} HTTP trigger(s)"

_log 'Checking for webhook bridge (Logic App)...'
$BRIDGE_EXISTS = $false
$bridgeId = "/subscriptions/${Subscription}/resourceGroups/${ResourceGroup}/providers/Microsoft.Logic/workflows/${AgentName}-webhook-bridge"
try {
    $BRIDGE_JSON = (az resource show --ids $bridgeId -o json 2>$null) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $BRIDGE_JSON -and $BRIDGE_JSON -ne 'null') {
        $BRIDGE_EXISTS = $true
        _log "  Found webhook bridge: ${AgentName}-webhook-bridge"
    } else {
        _log '  No webhook bridge found'
    }
} catch {
    _log '  No webhook bridge found'
}

$KNOWLEDGE = @()
$KNOWLEDGE_ITEMS = @()
$FILES_DIR = "${Output}-files"

if ($INCLUDE_KNOWLEDGE) {
    _log 'Reading AgentMemory documents...'
    $KNOWLEDGE = @(
        foreach ($item in @(Get-ResponseItems (Invoke-DpGet '/api/v1/AgentMemory/files') @('files', 'value'))) {
            $isIndexed = Get-ConfigValue $item @('isIndexed')
            $indexStatus = if ($isIndexed -is [bool]) {
                if ($isIndexed) { 'indexed' } else { 'pending' }
            } else {
                Get-ConfigValue $item @('indexStatus') 'unknown'
            }
            [pscustomobject]@{
                filename = Get-ConfigValue $item @('filename', 'name') ''
                mimeType = Get-ConfigValue $item @('mimeType', 'contentType') 'application/octet-stream'
                fileSize = Get-ConfigValue $item @('fileSize', 'size') 0
                indexStatus = $indexStatus
                triggerIndexing = $true
            }
        }
    )
    _log "  Found $($KNOWLEDGE.Count) uploaded document(s)"
    if ($DOWNLOAD_FILES -and $KNOWLEDGE.Count -gt 0) {
        $DOCS_DIR = Join-Path $Output 'data/knowledge'
        if (-not (Test-Path $DOCS_DIR)) { New-Item -ItemType Directory -Path $DOCS_DIR -Force | Out-Null }
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $missing = 0
        foreach ($document in $KNOWLEDGE) {
            $fname = $document.filename
            $candidates = @(
                Get-ChildItem -Path (Join-Path $RepoRoot 'recipes') -Filter $fname -Recurse -File -ErrorAction SilentlyContinue
                Get-ChildItem -Path $RepoRoot -Filter $fname -Depth 3 -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -like '*data*' }
            )
            if ($candidates.Count -gt 0) {
                Copy-Item $candidates[0].FullName (Join-Path $DOCS_DIR $fname) -Force
                _log "    + ${fname} (from $($candidates[0].FullName))"
            } else {
                _warn "${fname}: no download API; place the file in ${DOCS_DIR} before deploy."
                $missing++
            }
            Set-ConfigValue $document 'localPath' "$DOCS_DIR/$fname"
        }
        if ($missing -gt 0) { _warn "${missing} knowledge file(s) not found locally." }
    }
} else {
    _log 'Skipping AgentMemory documents (use -IncludeAll to include)'
}

if ($INCLUDE_KNOWLEDGE_ITEMS) {
    _log 'Reading knowledge items from connectors API...'
    $KNOWLEDGE_ITEMS = @(
        foreach ($item in @(Get-ResponseItems (Invoke-DpGet '/api/v2/extendedAgent/connectors'))) {
            $type = Get-ConfigValue $item @('properties.dataConnectorType') ''
            if ($type -cnotmatch '^Knowledge') { continue }
            [pscustomobject]@{
                name = Get-ConfigValue $item @('name')
                type = Get-ConfigValue $item @('type') 'KnowledgeItem'
                dataConnectorType = $type
                displayName = Get-ConfigValue $item @('properties.displayName', 'properties.extendedProperties.displayName', 'name')
                sourceUrl = Get-ConfigValue $item @('properties.sourceUrl') ''
                properties = Get-ConfigValue $item @('properties')
            }
        }
    )
    _log "  Found $($KNOWLEDGE_ITEMS.Count) knowledge item(s)"
    if ($DOWNLOAD_FILES -and $KNOWLEDGE_ITEMS.Count -gt 0) {
        $KI_DIR = Join-Path $FILES_DIR 'knowledge-items'
        if (-not (Test-Path $KI_DIR)) { New-Item -ItemType Directory -Path $KI_DIR -Force | Out-Null }
        foreach ($item in $KNOWLEDGE_ITEMS) {
            $name = $item.name
            $encodedName = [System.Uri]::EscapeDataString($name)
            $ext = switch ($item.dataConnectorType) {
                'KnowledgeText' { '.md' }
                'KnowledgeWebPage' { '.html' }
                'KnowledgeFile' { '' }
                default { '.json' }
            }
            if (Invoke-DpDownload "/api/v2/extendedAgent/connectors/${encodedName}/content" (Join-Path $KI_DIR "${name}${ext}")) {
                _log "    + ${name} ($($item.dataConnectorType))"
            }
        }
    }
} else {
    _log 'Skipping knowledge items (use -IncludeAll to include)'
}

$SYNTHESIZED_KNOWLEDGE = @()
if ($INCLUDE_MEMORIES) {
    _log 'Reading synthesized knowledge...'
    $SYNTHESIZED_KNOWLEDGE = @(
        foreach ($item in @(Get-ResponseItems (Invoke-DpGet '/api/v1/WorkspaceMemory/list?type=synthesized-knowledge') @('files', 'value'))) {
            [pscustomobject]@{
                path = Get-ConfigValue $item @('path') ''
                size = Get-ConfigValue $item @('size') 0
                lastModified = Get-ConfigValue $item @('lastModified') ''
            }
        }
    )
    _log "  Found $($SYNTHESIZED_KNOWLEDGE.Count) synthesized knowledge file(s)"
    if ($DOWNLOAD_FILES) {
        Invoke-DpDownloadTarball '/api/v1/WorkspaceMemory/synthesized-knowledge' (Join-Path $FILES_DIR 'synthesized-knowledge') 'synthesized-knowledge' | Out-Null
    }
    $WS_MEMORY = @(Get-ResponseItems (Invoke-DpGet '/api/v1/WorkspaceMemory/list') @('files', 'value'))
    _log "  Found $($WS_MEMORY.Count) total workspace memory file(s)"
} else {
    _log 'Skipping synthesized knowledge/memories (use -IncludeAll to include)'
}

$REPO_INSTRUCTIONS = @()
if ($INCLUDE_REPO_INSTRUCTIONS -and $REPO_COUNT -gt 0) {
    _log 'Reading repo instructions...'
    foreach ($repo in $REPOS) {
        $rname = $repo.name
        $encodedRname = [System.Uri]::EscapeDataString($rname)
        if ($DOWNLOAD_FILES) {
            $RI_DIR = Join-Path $FILES_DIR "repo-instructions/${rname}"
            Invoke-DpDownloadTarball "/api/v1/WorkspaceMemory/repo-instructions?repo=${encodedRname}" $RI_DIR "repo-instructions/${rname}" | Out-Null
            if (Test-Path $RI_DIR) {
                $resolvedDir = (Resolve-Path $RI_DIR).Path
                $files = @(
                    Get-ChildItem -Path $RI_DIR -File -Recurse | ForEach-Object {
                        [pscustomobject]@{
                            path = $_.FullName.Substring($resolvedDir.Length + 1)
                            content = [System.IO.File]::ReadAllText($_.FullName)
                        }
                    }
                )
                $REPO_INSTRUCTIONS += [pscustomobject]@{ repo = $rname; files = $files }
            }
        } else {
            $files = @(
                foreach ($item in @(Get-ResponseItems (Invoke-DpGet "/api/v1/WorkspaceMemory/list?type=repo-instructions&repo=${encodedRname}"))) {
                    [pscustomobject]@{
                        path = Get-ConfigValue $item @('path')
                        size = Get-ConfigValue $item @('size')
                    }
                }
            )
            if ($files.Count -gt 0) {
                $REPO_INSTRUCTIONS += [pscustomobject]@{
                    repo = $rname
                    files = $files
                    _note = 'Content not downloaded - omit -NoDownload to include'
                }
            }
        }
    }
    _log "  Found $($REPO_INSTRUCTIONS.Count) repo instruction set(s)"
} else {
    _log 'Skipping repo instructions (use -IncludeRepoInstructions to include)'
}

_log 'Reading session insights...'
$insightResponse = Invoke-DpGet '/api/v1/threads/insights?skip=0&take=1000'
$SESSION_INSIGHTS = @(
    foreach ($item in (Get-ConfigValue $insightResponse @('insights') @())) {
        [pscustomobject]@{
            id = Get-ConfigValue $item @('id')
            threadId = Get-ConfigValue $item @('threadId')
            title = Get-ConfigValue $item @('title')
            generatedTimestamp = Get-ConfigValue $item @('generatedTimestamp')
            insightMarkdown = Get-ConfigValue $item @('insightMarkdown')
            feedbackCount = Get-ConfigValue $item @('feedbackCount') 0
            positiveFeedbackCount = Get-ConfigValue $item @('positiveFeedbackCount') 0
            negativeFeedbackCount = Get-ConfigValue $item @('negativeFeedbackCount') 0
        }
    }
)
$SESSION_INSIGHT_COUNT = $SESSION_INSIGHTS.Count
_log "  Found ${SESSION_INSIGHT_COUNT} session insight(s)"

# Phase 4: Summary

_info 'Export summary'
Write-Host "  Agent:              ${AgentName}"
Write-Host "  Location:           ${LOCATION}"
Write-Host "  Access level:       ${ACCESS_LEVEL}"
Write-Host "  Action mode:        ${ACTION_MODE}"
Write-Host "  Target RGs:         $($TARGET_RGS -join ', ')"
Write-Host "  Connectors:         ${CONNECTOR_COUNT}"
foreach ($connector in $CONNECTORS) {
    Write-Host "    - $($connector.name) ($($connector.properties.dataConnectorType))"
}
Write-Host "  Skills:             ${SKILL_COUNT}"
foreach ($skill in $SKILLS) { Write-Host "    - $($skill.metadata.name)" }
Write-Host "  Subagents:          ${SUBAGENT_COUNT}"
foreach ($subagent in $SUBAGENTS) { Write-Host "    - $($subagent.metadata.name)" }
Write-Host "  Hooks:              ${HOOK_COUNT}"
foreach ($hook in $HOOKS_FOR_EXTRAS) { Write-Host "    - $($hook.name)" }
Write-Host "  Common prompts:     ${PROMPT_COUNT}"
foreach ($prompt in $PROMPTS_FOR_EXTRAS) { Write-Host "    - $($prompt.name)" }
Write-Host "  HTTP triggers:      ${HTTP_TRIGGER_COUNT}"
foreach ($trigger in $HTTP_TRIGGERS) { Write-Host "    - $($trigger.name)" }
Write-Host "  Repos:              ${REPO_COUNT}"
foreach ($repo in $REPOS) { Write-Host "    - $($repo.name)" }
Write-Host "  Webhook bridge:     $(if ($BRIDGE_EXISTS) { 'yes' } else { 'no' })"
Write-Host "  Incident platforms: ${INCIDENT_PLATFORM_COUNT}"
Write-Host "  Scheduled tasks:    ${TASK_COUNT}"
Write-Host "  Incident filters:   ${FILTER_COUNT}"
Write-Host "  Session insights:   ${SESSION_INSIGHT_COUNT}"

if ($DryRun) {
    Write-Host ''
    Write-Host 'Dry run - configuration files not written.'
    exit 0
}

# Phase 5: Write structured output

$EXPORT_DIR = if ([System.IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path $PWD $Output }
if (-not (Test-Path (Join-Path $EXPORT_DIR 'config'))) {
    New-Item -ItemType Directory -Path (Join-Path $EXPORT_DIR 'config') -Force | Out-Null
}

_info 'Writing agent.json'
$ENABLE_AI = $false; $AI_RESOURCE_ID = ''; $AI_APP_ID = ''
$ENABLE_LAW = $false; $LAW_RESOURCE_ID = ''
$ENABLE_AZMON = $false; $AZMON_LOOKBACK = 7
foreach ($connector in $CONNECTORS) {
    switch ($connector.properties.dataConnectorType) {
        'AppInsights' {
            $ENABLE_AI = $true
            $AI_RESOURCE_ID = Get-ConfigValue $connector @('properties.dataSource', 'properties.extendedProperties.armResourceId') ''
            $AI_APP_ID = Get-ConfigValue $connector @('properties.extendedProperties.appId') ''
        }
        'LogAnalytics' {
            $ENABLE_LAW = $true
            $LAW_RESOURCE_ID = Get-ConfigValue $connector @('properties.dataSource', 'properties.extendedProperties.armResourceId') ''
        }
        'AzureMonitor' {
            $ENABLE_AZMON = $true
            $AZMON_LOOKBACK = [int](Get-ConfigValue $connector @('properties.extendedProperties.lookbackDays') 7)
        }
    }
}

$agentConfig = [ordered]@{
    _description = 'SRE Agent configuration - edit these values to clone to a new environment.'
    _exported_at = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    identity = [ordered]@{
        agentName = $AgentName
        resourceGroup = $ResourceGroup
        subscription = $Subscription
        location = $LOCATION
        targetResourceGroups = $TARGET_RGS
    }
    access = [ordered]@{ accessLevel = $ACCESS_LEVEL; actionMode = $ACTION_MODE }
    upgradeChannel = 'Preview'
    defaultModelProvider = 'Anthropic'
    monthlyAgentUnitLimit = 10000
    tags = @{}
    toggles = [ordered]@{ enableWebhookBridge = $BRIDGE_EXISTS; webhookBridgeTriggerUrl = '' }
}
if ($SetOverrides.Count -gt 0) {
    _log 'Applying -Set overrides:'
    foreach ($key in $SetOverrides.Keys) {
        $val = [string]$SetOverrides[$key]
        switch ($key) {
            { $_ -in 'agentName', 'resourceGroup', 'location' } { $agentConfig.identity[$key] = $val }
            'targetRGs' { $agentConfig.identity.targetResourceGroups = $val }
            { $_ -in 'accessLevel', 'actionMode' } { $agentConfig.access[$key] = $val }
            { $_ -in 'pagerdutyApiKey', 'servicenowApiKey', 'connectionKey' } {
                foreach ($platform in $INCIDENT_PLATFORMS) { Set-ConfigValue $platform.spec 'connectionKey' $val }
                _log '  connectionKey -> (set in incident-platforms/*.yaml)'
                continue
            }
            default { _warn "Unknown -Set key: $key (ignored)"; continue }
        }
        _log "  $key -> $val"
    }
}
Write-Json (Join-Path $EXPORT_DIR 'agent.json') $agentConfig
_log 'Wrote agent.json'

_info 'Writing connectors.json'
$SECRETS_ENV = Join-Path $EXPORT_DIR 'connectors.secrets.env'
$secretLines = @(
    '# SRE Agent connector secrets - DO NOT commit this file.'
    "# Generated $([DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))"
    ''
)
$CONNECTORS_CLEAN = Invoke-Sanitize $CONNECTORS
foreach ($connector in $CONNECTORS_CLEAN) {
    $ENV_PREFIX = ($connector.name -replace '-', '_').ToUpperInvariant()
    $dsrc = Get-ConfigValue $connector @('properties.dataSource') ''
    if ($dsrc -cmatch 'BearerToken=([^;]+)') {
        $secretLines += "${ENV_PREFIX}_BEARER_TOKEN=$($Matches[1])"
        $ref = "`${${ENV_PREFIX}_BEARER_TOKEN}"
        $newSource = [regex]::Replace($dsrc, 'BearerToken=[^;]+', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) "BearerToken=$ref" })
        Set-ConfigValue $connector.properties 'dataSource' $newSource
    }
    $bt = Get-ConfigValue $connector @('properties.extendedProperties.bearerToken')
    if ($bt) {
        $secretLines += "${ENV_PREFIX}_BEARER_TOKEN=${bt}"
        Set-ConfigValue $connector.properties.extendedProperties 'bearerToken' "`${${ENV_PREFIX}_BEARER_TOKEN}"
    }
}
$CONNECTORS_CLEAN = Invoke-Sanitize $CONNECTORS_CLEAN
$CONNECTORS_ARRAY = @($CONNECTORS_CLEAN | Where-Object {
    $_.properties.dataConnectorType -cnotmatch '^(AppInsights|LogAnalytics|AzureMonitor)$'
})
$connectorConfig = [ordered]@{
    toggles = [ordered]@{
        enableAppInsightsConnector = $ENABLE_AI
        appInsightsResourceId = $AI_RESOURCE_ID
        appInsightsAppId = $AI_APP_ID
        enableLogAnalyticsConnector = $ENABLE_LAW
        lawResourceId = $LAW_RESOURCE_ID
        enableAzureMonitorConnector = $ENABLE_AZMON
        azureMonitorLookbackDays = $AZMON_LOOKBACK
    }
    connectors = $CONNECTORS_ARRAY
}
Write-Json (Join-Path $EXPORT_DIR 'connectors.json') $connectorConfig
_log "Wrote connectors.json ($($CONNECTORS_ARRAY.Count) connector(s) + toggles)"
$secretLines | Set-Content -LiteralPath $SECRETS_ENV -Encoding utf8
_log 'Wrote connectors.secrets.env (secrets extracted - DO NOT commit)'

$ADMIN_USERS = Get-ConfigValue $AGENT @('properties.adminUsers') @()
if ($ADMIN_USERS.Count -gt 0) {
    Write-Json (Join-Path $EXPORT_DIR 'admin-settings.json') ([ordered]@{
        _description = 'Cross-tenant admin users for portal access.'
        adminUsers = $ADMIN_USERS
    })
    _log "Wrote admin-settings.json ($($ADMIN_USERS.Count) admin user(s))"
}
@'
# Secrets - never commit
connectors.secrets.env
*.secrets.env

# Downloaded data (can be large)
data/
'@ | Set-Content -LiteralPath (Join-Path $EXPORT_DIR '.gitignore') -Encoding utf8

_log 'Generating expected-config.json'
$EXPECTED_CONNECTORS = @(
    if ($ENABLE_LAW) { [ordered]@{ name = 'log-analytics'; type = 'LogAnalytics' } }
    if ($ENABLE_AI) { [ordered]@{ name = 'app-insights'; type = 'AppInsights' } }
    if ($ENABLE_AZMON) { [ordered]@{ name = 'azure-monitor'; type = 'AzureMonitor' } }
    foreach ($connector in $CONNECTORS_ARRAY) {
        if ($connector.name -and $connector.name -ne 'null') {
            [ordered]@{ name = $connector.name; type = $connector.properties.dataConnectorType }
        }
    }
)
$INC_PLATFORM = 'None'
if ($INCIDENT_PLATFORMS.Count -gt 0) {
    $INC_PLATFORM = Get-ConfigValue $INCIDENT_PLATFORMS[0] @('spec.platformType') 'None'
    if (-not $INC_PLATFORM) { $INC_PLATFORM = 'None' }
}
$expectedConfig = [ordered]@{
    _scenario = 'exported'
    agent = [ordered]@{
        accessLevel = $ACCESS_LEVEL
        actionMode = $ACTION_MODE
        upgradeChannel = $UPGRADE_CHANNEL
        defaultModelProvider = $DEFAULT_MODEL_PROVIDER
        incidentPlatform = $INC_PLATFORM
    }
    connectors = $EXPECTED_CONNECTORS
    skills = @($SKILLS | ForEach-Object { $_.metadata.name })
    subagents = @($SUBAGENTS | ForEach-Object { $_.metadata.name })
    hooks = @($ALL_HOOKS | ForEach-Object { Get-ConfigValue $_ @('name', 'metadata.name') } | Sort-Object -Unique -CaseSensitive)
    commonPrompts = @($ALL_PROMPTS | ForEach-Object { Get-ConfigValue $_ @('name', 'metadata.name') } | Sort-Object -Unique -CaseSensitive)
    scheduledTasks = @($SCHEDULED_TASKS | ForEach-Object { Get-ConfigValue $_ @('metadata.name', 'name') })
    responsePlans = @(
        foreach ($filter in $INCIDENT_FILTERS) {
            [ordered]@{
                name = Get-ConfigValue $filter @('metadata.name', 'name')
                handlingAgent = Get-ConfigValue $filter @('spec.handlingAgent', 'handlingAgent') ''
            }
        }
    )
    repos = @($REPOS | ForEach-Object { $_.name })
}
Write-Json (Join-Path $EXPORT_DIR 'expected-config.json') $expectedConfig
_log 'Wrote expected-config.json'

_info 'Writing config/ files (YAML)'

foreach ($skill in $SKILLS) {
    $sname = $skill.metadata.name
    $skillDir = Join-Path $EXPORT_DIR 'config/skills'
    if (-not (Test-Path $skillDir)) { New-Item -ItemType Directory -Path $skillDir -Force | Out-Null }
    if ($skill.skillContent) {
        [System.IO.File]::WriteAllText((Join-Path $skillDir "${sname}.md"), $skill.skillContent)
    }
    for ($j = 0; $j -lt $skill.additionalFiles.Count; $j++) {
        $file = $skill.additionalFiles[$j]
        $afname = Get-ConfigValue $file @('name', 'path') "file-$j"
        $afDir = Join-Path $skillDir $sname
        if (-not (Test-Path $afDir)) { New-Item -ItemType Directory -Path $afDir -Force | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $afDir $afname), (Get-ConfigValue $file @('content') ''))
        Set-ConfigValue $file 'content' "$sname/$afname"
    }
    $skill.skillContent = "skills/${sname}.md"
    Write-Yaml (Join-Path $skillDir "${sname}.yaml") $skill
}
if ($SKILL_COUNT -gt 0) { _log "  skills: ${SKILL_COUNT} file(s)" }

foreach ($subagent in $SUBAGENTS) {
    $name = $subagent.metadata.name
    $saDir = Join-Path $EXPORT_DIR 'config/subagents'
    if (-not (Test-Path $saDir)) { New-Item -ItemType Directory -Path $saDir -Force | Out-Null }
    $instructions = Get-ConfigValue $subagent @('spec.instructions') ''
    if ($instructions) {
        [System.IO.File]::WriteAllText((Join-Path $saDir "${name}.instructions.md"), $instructions)
        Set-ConfigValue $subagent.spec 'instructions' "subagents/${name}.instructions.md"
    }
    $handoff = Get-ConfigValue $subagent @('spec.handoffDescription') ''
    if ($handoff.Length -gt 200) {
        [System.IO.File]::WriteAllText((Join-Path $saDir "${name}.handoff.md"), $handoff)
        Set-ConfigValue $subagent.spec 'handoffDescription' "${name}.handoff.md"
    }
    Write-Yaml (Join-Path $saDir "${name}.yaml") $subagent
}
if ($SUBAGENT_COUNT -gt 0) { _log "  subagents: ${SUBAGENT_COUNT} file(s)" }

Write-ConfigItems -Dir 'tools' -Items $TOOLS
Write-ConfigItems -Dir 'hooks' -Items $ALL_HOOKS

foreach ($prompt in $ALL_PROMPTS) {
    $name = Get-ConfigValue $prompt @('metadata.name', 'name')
    $promptDir = Join-Path $EXPORT_DIR 'config/common-prompts'
    if (-not (Test-Path $promptDir)) { New-Item -ItemType Directory -Path $promptDir -Force | Out-Null }
    $text = Get-ConfigValue $prompt @('spec.prompt', 'properties.content', 'properties.prompt') ''
    if ($text) { [System.IO.File]::WriteAllText((Join-Path $promptDir "${name}.md"), $text) }
    Write-Yaml (Join-Path $promptDir "${name}.yaml") $prompt
}
if ($PROMPT_COUNT -gt 0) { _log "  common-prompts: ${PROMPT_COUNT} prompt(s)" }

Write-ConfigItems -Dir 'scheduled-tasks' -Items $SCHEDULED_TASKS -Base 'automations'
Write-ConfigItems -Dir 'incident-filters' -Items $INCIDENT_FILTERS -Base 'automations'
Write-ConfigItems -Dir 'http-triggers' -Items $HTTP_TRIGGERS -Base 'automations'
Write-ConfigItems -Dir 'plugin-configs' -Items $ALL_PLUGINS

foreach ($platform in $INCIDENT_PLATFORMS) {
    $ptype = Get-ConfigValue $platform @('spec.platformType', 'spec.incidentPlatform') ''
    if ($ptype -in @('PagerDuty', 'ServiceNow') -and -not (Get-ConfigValue $platform @('spec.connectionKey'))) {
        $envVar = "$($ptype.ToUpperInvariant())_API_KEY"
        Set-ConfigValue $platform.spec 'connectionKey' "`${$envVar}"
        $secretLines += @('', "# ${ptype} API key - required for incident platform", "${envVar}=")
        _warn "${ptype} connectionKey is redacted by API."
        _warn "  Set ${envVar} in ${EXPORT_DIR}/connectors.secrets.env before deploy."
    }
}
Write-ConfigItems -Dir 'incident-platforms' -Items $INCIDENT_PLATFORMS -Base 'automations'
$secretLines | Set-Content -LiteralPath $SECRETS_ENV -Encoding utf8
Write-ConfigItems -Dir 'repos' -Items $REPOS
Write-ConfigItems -Dir 'plugins/marketplaces' -Items $PLUGIN_MARKETPLACES
Write-ConfigItems -Dir 'plugins/installations' -Items $PLUGIN_INSTALLATIONS

_info 'Writing data/ files'
$DATA_DIR = Join-Path $EXPORT_DIR 'data'
foreach ($subDir in @('knowledge', 'synthesized-knowledge')) {
    $p = Join-Path $DATA_DIR $subDir
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    $gitkeep = Join-Path $p '.gitkeep'
    if (-not (Test-Path $gitkeep)) { '' | Set-Content $gitkeep }
}

foreach ($insight in $SESSION_INSIGHTS) {
    $siDir = Join-Path $DATA_DIR 'session-insights'
    if (-not (Test-Path $siDir)) { New-Item -ItemType Directory -Path $siDir -Force | Out-Null }
    $title = [string]$insight.title
    $fname = ($title -replace '[^a-zA-Z0-9]', '-' -replace '-+', '-' -replace '^-|-$', '').ToLowerInvariant()
    if ($fname.Length -gt 80) { $fname = $fname.Substring(0, 80) }
    if (-not $fname) { $fname = $insight.id }
    if ($insight.insightMarkdown) {
        [System.IO.File]::WriteAllText((Join-Path $siDir "${fname}.md"), $insight.insightMarkdown)
    }
    $insight.insightMarkdown = "session-insights/${fname}.md"
    Write-Yaml (Join-Path $siDir "${fname}.yaml") $insight
}
if ($SESSION_INSIGHT_COUNT -gt 0) { _log "  session-insights: ${SESSION_INSIGHT_COUNT} file(s)" }

if ($KNOWLEDGE.Count -gt 0) {
    Write-Json (Join-Path $DATA_DIR 'knowledge.json') $KNOWLEDGE
    _log "  knowledge.json: $($KNOWLEDGE.Count) document(s)"
}
if ($KNOWLEDGE_ITEMS.Count -gt 0) {
    Write-Json (Join-Path $DATA_DIR 'knowledge-items.json') $KNOWLEDGE_ITEMS
    _log "  knowledge-items.json: $($KNOWLEDGE_ITEMS.Count) item(s)"
}
if ($SYNTHESIZED_KNOWLEDGE.Count -gt 0) {
    Write-Json (Join-Path $DATA_DIR 'synthesized-knowledge.json') $SYNTHESIZED_KNOWLEDGE
    _log "  synthesized-knowledge.json: $($SYNTHESIZED_KNOWLEDGE.Count) file(s)"
}
if ($REPO_INSTRUCTIONS.Count -gt 0) {
    Write-Json (Join-Path $DATA_DIR 'repo-instructions.json') $REPO_INSTRUCTIONS
    _log "  repo-instructions.json: $($REPO_INSTRUCTIONS.Count) set(s)"
}

if ($DOWNLOAD_FILES -and (Test-Path $FILES_DIR)) {
    foreach ($subdir in @('knowledge', 'synthesized-knowledge', 'repo-instructions')) {
        $srcDir = Join-Path $FILES_DIR $subdir
        if (Test-Path $srcDir) {
            $destDir = Join-Path $DATA_DIR $subdir
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Copy-Item -Path (Join-Path $srcDir '*') -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $kiSrcDir = Join-Path $FILES_DIR 'knowledge-items'
    if (Test-Path $kiSrcDir) {
        $kiDestDir = Join-Path $DATA_DIR 'knowledge-items'
        if (-not (Test-Path $kiDestDir)) { New-Item -ItemType Directory -Path $kiDestDir -Force | Out-Null }
        foreach ($f in Get-ChildItem -Path $kiSrcDir -File -ErrorAction SilentlyContinue) {
            Copy-Item $f.FullName (Join-Path $kiDestDir $f.Name) -Force
        }
    }
    if ($FILES_DIR -ne $DATA_DIR -and $FILES_DIR -ne (Join-Path $EXPORT_DIR 'data')) {
        Remove-Item $FILES_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}

_info 'Export complete'
Write-Host ''
Write-Host "  ${EXPORT_DIR}/"
Write-Host '    agent.json               <- Agent identity + settings'
Write-Host '    connectors.json          <- Connector toggles + entries (secrets -> env var refs)'
Write-Host '    connectors.secrets.env   <- Extracted secrets (gitignored)'
Write-Host '    config/'
foreach ($d in @('skills', 'subagents', 'tools', 'hooks', 'common-prompts', 'plugin-configs', 'repos')) {
    $dPath = Join-Path $EXPORT_DIR "config/$d"
    if (Test-Path $dPath) {
        $yamlCount = (Get-ChildItem -Path $dPath -Filter '*.yaml' -File -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host ("      {0,-24} <- {1} file(s)" -f "${d}/", $yamlCount)
    }
}
$autoDir = Join-Path $EXPORT_DIR 'automations'
if (Test-Path $autoDir) {
    Write-Host '    automations/'
    foreach ($d in @('scheduled-tasks', 'incident-filters', 'http-triggers', 'incident-platforms')) {
        $dPath = Join-Path $autoDir $d
        if (Test-Path $dPath) {
            $yamlCount = (Get-ChildItem -Path $dPath -Filter '*.yaml' -File -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-Host ("      {0,-24} <- {1} file(s)" -f "${d}/", $yamlCount)
        }
    }
}
Write-Host '    data/                    <- Knowledge, memories, repo instructions'
if (Test-Path (Join-Path $EXPORT_DIR 'admin-settings.json')) {
    Write-Host '    admin-settings.json      <- Cross-tenant admin users'
}
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Review agent.json - change identity.agentName, identity.resourceGroup, identity.location'
Write-Host '  2. Update connectors.json - change resource IDs for target environment'
Write-Host '  3. Fill connectors.secrets.env with real tokens for the target'
Write-Host '  4. Edit config/ YAML files - skills, subagents, tools, hooks as needed'
Write-Host '  Deploy with:'
Write-Host "    .\Deploy-Agent.ps1 -InputPath ${EXPORT_DIR}"
