#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$exporter = Join-Path $PSScriptRoot '..\bin\ps\Export-Agent.ps1'
$source = [IO.File]::ReadAllText((Resolve-Path $exporter).Path)
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Exporter did not parse: $($errors | Out-String)" }
if ($source -match '\b(Invoke-Jq|jq)\b') { throw 'Exporter still references the removed JSON CLI.' }
if ($source -match 'Test-Prerequisites|Invoke-Jq\.ps1') { throw 'Exporter still loads prerequisites for other scripts.' }
if ($source -match '\b(python3?|PyYAML)\b') { throw 'Exporter still depends on Python.' }
if ($source -match '\[pscustomobject\]|YamlDotNet|System\.IO\.|MatchEvaluator') {
    throw 'Exporter still constructs objects or uses APIs blocked in constrained language.'
}
Import-Module powershell-yaml -ErrorAction Stop

foreach ($function in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)) {
    Invoke-Expression $function.Extent.Text
}
$start = $ast.EndBlock.Statements | Where-Object {
    $_.Extent.Text.StartsWith('_info "Connecting to agent')
} | Select-Object -First 1
if (-not $start) { throw 'Exporter entry point was not found.' }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-JsonFile {
    param([string]$RelativePath)
    $value = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $Output $RelativePath) -Raw) -AsHashtable -NoEnumerate
    $value
}

function Read-YamlFile {
    param([string]$RelativePath)
    $path = Join-Path $Output $RelativePath
    $value = powershell-yaml\ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $path -Raw) -ErrorAction Stop
    ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $value -Depth 100) -AsHashtable -NoEnumerate
}

function New-OpaqueResource {
    param([string]$Name, [object]$Spec)
    $json = ConvertTo-Json -InputObject $Spec -Depth 100 -Compress
    @{
        name = "agent/$Name"
        properties = @{ value = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)) }
    }
}

function az {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'account') { return 'test-token' }
    if ($args[0] -eq 'resource') { $global:LASTEXITCODE = 1; return }
    $urlIndex = [array]::IndexOf($args, '--url')
    if ($urlIndex -lt 0) { throw 'Unexpected Azure CLI invocation.' }
    $uri = [uri]$args[$urlIndex + 1]
    $child = $uri.AbsolutePath.Split('/')[-1]
    if ($child -eq $AgentName) {
        return (ConvertTo-Json -InputObject $global:ExportJsonTestState.AgentResponse -Depth 100)
    }
    if (-not $global:ExportJsonTestState.ArmResources.ContainsKey($child)) { throw "Unexpected ARM child: $child" }
    ConvertTo-Json -InputObject @{ value = $global:ExportJsonTestState.ArmResources[$child] } -Depth 100
}

function Invoke-WebRequest {
    param($Uri, $Headers, [switch]$UseBasicParsing, $TimeoutSec, $OutFile, $ErrorAction)
    Assert-True ($Headers.Authorization -eq 'Bearer test-token') 'Authorization header changed.'
    Assert-True ($UseBasicParsing -and $ErrorAction -eq 'Stop') 'Request error handling changed.'
    $path = ([uri]$Uri).PathAndQuery
    $global:ExportJsonTestState.Requests += $path
    if ($path -eq '/http-error') { throw 'Simulated HTTP failure.' }
    if ($path -eq '/invalid-json') { return [pscustomobject]@{ Content = '{invalid' } }
    if ($OutFile) {
        $global:ExportJsonTestState.DownloadPaths += $OutFile
        Set-Content -LiteralPath $OutFile -Value $path -NoNewline
        return
    }
    Assert-True ($TimeoutSec -eq 10) 'GET timeout changed.'
    $response = $null
    if ($global:ExportJsonTestState.DpResponses.ContainsKey($path)) { $response = $global:ExportJsonTestState.DpResponses[$path] }
    [pscustomobject]@{ Content = ConvertTo-Json -InputObject $response -Depth 100 }
}

function tar {
    if ($args[0] -ne '-xzf') { throw 'Unexpected archive invocation.' }
    $archive = Get-Content -LiteralPath $args[1] -Raw
    $dest = $args[3]
    $filename = if ($archive -match 'repo-instructions') { 'instructions.md' } else { 'memory.md' }
    Set-Content -LiteralPath (Join-Path $dest $filename) -Value '# Downloaded memory' -NoNewline
    $global:LASTEXITCODE = 0
}

function Invoke-ConstrainedExport {
    param([string]$Destination, [bool]$Download)
    $ps = [powershell]::Create()
    try {
        # Load the approved module and test doubles before constraining this isolated runspace.
        $setup = "Import-Module powershell-yaml -Global -ErrorAction Stop`n"
        foreach ($name in @('Assert-True', 'az', 'Invoke-WebRequest', 'tar')) {
            $definition = (Get-Command $name -CommandType Function).Definition
            $setup += "function $name {`n$definition`n}`n"
        }
        $null = $ps.AddScript($setup).Invoke()
        if ($ps.HadErrors) { throw (($ps.Streams.Error | ForEach-Object { "$($_.Exception.Message)`n$($_.ScriptStackTrace)" }) -join "`n") }
        $ps.Commands.Clear()
        $ps.Runspace.SessionStateProxy.SetVariable('ExportJsonTestState', $global:ExportJsonTestState)
        $ps.Runspace.SessionStateProxy.LanguageMode = 'ConstrainedLanguage'
        $null = $ps.AddCommand($exporter).
            AddParameter('Subscription', 'test-sub').
            AddParameter('ResourceGroup', 'test-rg').
            AddParameter('AgentName', 'test-agent').
            AddParameter('Output', $Destination).
            AddParameter('Set', $SetOverrides).
            AddParameter('NoInstallDependencies').
            AddParameter('IncludeRepoInstructions')
        if (-not $Download) { $null = $ps.AddParameter('NoDownload') }
        $null = $ps.Invoke()
        if ($ps.HadErrors) {
            $details = @($ps.Streams.Error | ForEach-Object { "$($_.Exception.Message)`n$($_.ScriptStackTrace)" })
            $details += @($ps.Streams.Information | ForEach-Object { [string]$_.MessageData })
            throw ($details -join "`n")
        }
        $messages = ($ps.Streams.Information | ForEach-Object { [string]$_.MessageData }) -join "`n"
        Assert-True ($messages -match '-- Export complete --') "Constrained export did not complete: $messages"
        Assert-True ($ps.Runspace.SessionStateProxy.LanguageMode -eq 'ConstrainedLanguage') 'Exporter changed the language mode.'
    } finally {
        $ps.Dispose()
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "export-json-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$fixtureRoot = Join-Path $tempRoot 'fixture'
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'recipes') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $fixtureRoot 'recipes\doc-0.md') -Value '# Knowledge source' -NoNewline
$exporterRoot = (Join-Path $fixtureRoot 'bin\ps').Replace("'", "''")
$body = [scriptblock]::Create("`$PSScriptRoot = '$exporterRoot'`n" + $source.Substring($start.Extent.StartOffset))

try {
    $yamlInput = [ordered]@{
        removed = $null
        '2026-11-03' = 'date-key'
        timestamp = [datetime]::Parse('2026-11-03T10:50:48Z').ToUniversalTime()
        offsetTimestamp = [datetimeoffset]::Parse('2026-11-03T10:50:48-08:00')
        emptyMap = @{}
        emptyArray = @()
        nested = @{ removed = $null; zero = 0; flag = $false; empty = '' }
        items = @($null, $false, 0, '', @{ removed = $null; kept = 'value' })
        strings = @('true', 'false', 'null', 'on', 'off', 'yes', '123', '1.2', '2026-11-03', '2026-11-03T10:50:48Z', '${TOKEN}', 'a: b', '# heading')
        markdown = "# Heading`n`nLine with `"quotes`" and $([char]0x03BB).`n"
    }
    $yamlText = ConvertTo-ExportYaml $yamlInput
    Assert-True ($yamlText.Contains('"2026-11-03"') -and $yamlText.Contains('"2026-11-03T10:50:48Z"')) 'Timestamp strings must be quoted for YAML 1.1 readers.'
    $yamlValue = powershell-yaml\ConvertFrom-Yaml -Yaml $yamlText
    Assert-True (-not $yamlValue.Contains('removed') -and -not $yamlValue.nested.Contains('removed')) 'Null mapping entries were not removed.'
    Assert-True ($yamlValue['2026-11-03'] -eq 'date-key') 'Date-like mapping key changed.'
    foreach ($name in @('timestamp', 'offsetTimestamp')) {
        $jsonTimestamp = ConvertTo-Json -InputObject $yamlInput[$name] -Compress
        $expectedTimestamp = $jsonTimestamp.Substring(1, $jsonTimestamp.Length - 2)
        Assert-True ($yamlValue[$name] -is [string] -and $yamlValue[$name] -ceq $expectedTimestamp) 'Timestamp serialization changed.'
    }
    Assert-True ($yamlValue.emptyMap.Count -eq 0 -and $yamlValue.emptyArray.Count -eq 0) 'Empty YAML collections changed.'
    Assert-True ($yamlValue.nested.zero -eq 0 -and $yamlValue.nested.flag -eq $false -and $yamlValue.nested.empty -eq '') 'YAML scalar values changed.'
    Assert-True ($yamlValue.items.Count -eq 4 -and $yamlValue.items[0] -eq $false -and $yamlValue.items[1] -eq 0) 'Null list entries were not removed correctly.'
    for ($i = 0; $i -lt $yamlInput.strings.Count; $i++) {
        Assert-True ($yamlValue.strings[$i] -is [string] -and $yamlValue.strings[$i] -ceq $yamlInput.strings[$i]) 'A YAML string changed type or value.'
    }
    Assert-True ($yamlValue.markdown -ceq $yamlInput.markdown) 'Multiline or Unicode YAML content changed.'
    Assert-True ($yamlInput.Contains('removed') -and $yamlInput.items.Count -eq 5) 'YAML conversion mutated the input.'
    foreach ($count in @(0, 1, 2)) {
        $array = @(for ($i = 0; $i -lt $count; $i++) { "item-$i" })
        $yamlArray = ConvertTo-ExportYaml $array
        $value = powershell-yaml\ConvertFrom-Yaml -Yaml $yamlArray
        Assert-True ($value.Count -eq $count) "Root YAML array shape changed for $count items."
    }
    Assert-True ((ConvertTo-ExportYaml $null).Trim() -eq 'null') 'Root YAML null changed.'
    Write-Host 'PASS: native YAML null removal, arrays, scalar types, strings, and multiline content'

    $optional = ConvertFrom-Json -InputObject '{"zero":0,"flag":false,"empty":"","items":[],"missing":null}' -AsHashtable
    Assert-True ((Get-ConfigValue $optional @('zero') 99) -eq 0) 'Zero was replaced by a default.'
    Assert-True ((Get-ConfigValue $optional @('flag') $true) -eq $false) 'False was replaced by a default.'
    Assert-True ((Get-ConfigValue $optional @('empty') 'fallback') -eq '') 'Empty string was replaced by a default.'
    $empty = Get-ConfigValue $optional @('items') @('fallback')
    Assert-True ($empty -is [array] -and $empty.Count -eq 0) 'Empty array was replaced by a default.'
    Assert-True ((Get-ConfigValue $optional @('absent.nested', 'zero') 99) -eq 0) 'Optional nested path fallback failed.'

    $sanitized = Invoke-Sanitize (ConvertFrom-Json -InputObject '{"values":[null,false,0,"","ghp_test","Bearer token","BearerToken=test;Url=x","accessToken=x","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],"nested":{"unchanged":"hello"}}' -AsHashtable)
    Assert-True ($sanitized.values.Count -eq 9) 'Sanitizing changed array length.'
    Assert-True ($null -eq $sanitized.values[0] -and $sanitized.values[1] -eq $false -and $sanitized.values[2] -eq 0) 'Sanitizing changed non-string values.'
    Assert-True ($sanitized.values[3] -eq '' -and $sanitized.values[4] -eq 'EDIT_ME_GITHUB_PAT') 'Secret sanitizing changed.'
    Assert-True ($sanitized.values[5] -eq 'EDIT_ME_BEARER_TOKEN') 'Bearer secret was not sanitized.'
    Assert-True ($sanitized.values[6] -eq 'BearerToken=EDIT_ME_TOKEN;Url=x') 'Connection string was not sanitized.'
    Assert-True ($sanitized.values[7] -eq 'EDIT_ME_ACCESS_TOKEN' -and $sanitized.values[8] -eq 'EDIT_ME_SECRET') 'Token sanitizing changed.'

    $reserved = @{ Keys = @('key-value'); Values = 'value-value'; Count = 0 }
    $reservedCopy = Invoke-Sanitize $reserved
    Assert-True ($reservedCopy['Keys'][0] -eq 'key-value' -and $reservedCopy['Values'] -eq 'value-value' -and $reservedCopy['Count'] -eq 0) 'Dictionary member names shadowed configuration keys.'
    foreach ($length in @(0, 1, 2, 3, 4, 5, 6, 31, 128, 4096)) {
        $text = ('x' * $length) + [char]0x03BB + [char]0xD83D + [char]0xDE80
        $encodedText = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
        Assert-True ((ConvertFrom-Base64Utf8 $encodedText) -ceq $text) "Base64 UTF-8 round trip failed for length $length."
        Assert-True ((ConvertFrom-Base64Utf8 (" `t" + $encodedText + "`r`n")) -ceq $text) 'Base64 whitespace handling changed.'
    }
    Assert-True ((ConvertFrom-Base64Utf8 '') -eq '') 'Empty Base64 handling changed.'
    foreach ($invalid in @('A', 'AA=', 'AAA', '====', 'A===', 'AAA!', 'AA==AAAA')) {
        $failed = $false
        try { ConvertFrom-Base64Utf8 $invalid | Out-Null } catch { $failed = $true }
        Assert-True $failed 'Invalid Base64 must fail explicitly.'
    }
    Write-Host 'PASS: dictionary keys and Base64 padding, UTF-8, whitespace, and invalid input'

    $cases = @(
        @{ Name = 'empty'; Count = 0; Arm = $true; Wrapped = $true; Download = $false; Overrides = $false }
        @{ Name = 'single-arm'; Count = 1; Arm = $true; Wrapped = $true; Download = $false; Overrides = $false }
        @{ Name = 'multiple-arm'; Count = 2; Arm = $true; Wrapped = $true; Download = $false; Overrides = $false }
        @{ Name = 'single-dataplane'; Count = 1; Arm = $false; Wrapped = $false; Download = $false; Overrides = $true }
        @{ Name = 'multiple-dataplane'; Count = 2; Arm = $false; Wrapped = $true; Download = $false; Overrides = $false }
        @{ Name = 'downloads'; Count = 1; Arm = $false; Wrapped = $true; Download = $true; Overrides = $false }
    )
    foreach ($case in $cases) {
        $Output = Join-Path $tempRoot $case.Name
        $Subscription = 'test-sub'
        $ResourceGroup = 'test-rg'
        $AgentName = 'test-agent'
        $API_VERSION = '2025-05-01-preview'
        $ARM_BASE = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$AgentName"
        $script:DpTokenCache = ''
        $script:ArmResources = @{}
        foreach ($child in @('connectors', 'tools', 'skills', 'scheduledTasks', 'incidentFilters', 'subagents', 'hooks', 'commonPrompts', 'pluginConfigs')) {
            $script:ArmResources[$child] = @()
        }
        $script:DpResponses = @{}
        $script:AgentResponse = @{
            location = 'eastus2'
            properties = @{
                agentEndpoint = 'https://agent.example.test'
                actionConfiguration = @{ accessLevel = 'Low'; mode = 'Review' }
                upgradeChannel = 'Stable'
                defaultModelProvider = 'OpenAI'
                adminUsers = @()
            }
        }
        $INCLUDE_KNOWLEDGE = $true
        $INCLUDE_KNOWLEDGE_ITEMS = $true
        $INCLUDE_MEMORIES = $true
        $INCLUDE_REPO_INSTRUCTIONS = $true
        $DOWNLOAD_FILES = $case.Download
        $DryRun = $false
        $SetOverrides = @{}
        if ($case.Overrides) {
            $SetOverrides = @{
                agentName = 'clone'
                resourceGroup = 'clone-rg'
                location = 'uksouth'
                targetRGs = 'clone-target'
                accessLevel = 'High'
                actionMode = 'Autonomous'
                connectionKey = "test-key'with-quotes"
                unknown = 'ignored'
            }
        }
        $dpPaths = @{
            tools = '/api/v2/extendedAgent/tools'
            skills = '/api/v2/extendedAgent/skills'
            scheduledTasks = '/api/v2/extendedAgent/scheduledtasks'
            incidentFilters = '/api/v2/extendedAgent/incidentFilters'
            subagents = '/api/v2/extendedAgent/agents'
            hooks = '/api/v2/extendedAgent/hooks'
            commonPrompts = '/api/v2/extendedAgent/commonprompts'
            pluginConfigs = '/api/v2/extendedAgent/plugins'
        }
        $repoItems = @(); $knowledge = @(); $memories = @(); $insights = @(); $knowledgeItems = @()
        $platform = $null
        if ($case.Count -gt 0) {
            $script:AgentResponse.properties.incidentManagementConfiguration = @{ type = 'PagerDuty' }
            $script:AgentResponse.properties.adminUsers = @('admin@example.test')
            $script:AgentResponse.properties.knowledgeGraphConfiguration = @{
                managedResources = @('/subscriptions/sub/resourceGroups/z-rg', '/subscriptions/sub/resourceGroups/a-rg', '/subscriptions/sub/resourceGroups/z-rg')
            }
            $platform = @{ spec = @{ platformType = 'PagerDuty' } }
            $script:DpResponses['/api/v2/incidents/indexing/pagerduty/configuration'] = $platform
            foreach ($toggle in @('AppInsights', 'LogAnalytics', 'AzureMonitor')) {
                $script:ArmResources.connectors += @{
                    name = "agent/$toggle"
                    properties = @{
                        dataConnectorType = $toggle
                        dataSource = '/subscriptions/sub/resourceGroups/monitoring'
                        extendedProperties = @{ lookbackDays = 0; appId = '' }
                    }
                }
            }
        }
        for ($i = 0; $i -lt $case.Count; $i++) {
            $script:ArmResources.connectors += @{
                name = "agent/custom-$i"
                properties = @{
                    dataConnectorType = 'Custom'
                    dataSource = 'Url=x;BearerToken=source-secret'
                    extendedProperties = @{ bearerToken = "short-token-$i"; flag = $false; count = 0 }
                }
            }
            $specs = @{
                tools = @{ url = 'https://tool.example.test'; nested = @{ enabled = $false; limit = 0; entries = @() } }
                skills = @{
                    description = 'A skill'
                    tools = $(if ($case.Name -eq 'single-arm') { ,@() } elseif ($i -gt 0) { ,@('ReadFile', 'ListDir') } else { ,@('ReadFile') })
                    skillContent = "# Skill $i`nContent with quotes: `"hello`" and $([char]0x03BB)"
                    additionalFiles = @(@{ name = 'guide.md'; content = '# Guide' })
                }
                scheduledTasks = @{ cron = '0 * * * *'; enabled = $false }
                incidentFilters = @{ handlingAgent = "subagent-$i" }
                subagents = @{ instructions = '# Instructions'; handoffDescription = ('h' * 201) }
                hooks = @{ command = 'echo hello' }
                commonPrompts = @{ prompt = '# Shared prompt' }
                pluginConfigs = @{ enabled = $false }
            }
            foreach ($child in $specs.Keys) {
                $name = "$child-$i"
                if ($case.Arm) { $script:ArmResources[$child] += New-OpaqueResource $name $specs[$child] }
                $dpPath = $dpPaths[$child]
                if (-not $script:DpResponses.ContainsKey($dpPath)) { $script:DpResponses[$dpPath] = @() }
                $script:DpResponses[$dpPath] += @{ name = $name; properties = $specs[$child] }
            }
            $handlerPath = '/api/v1/incidentPlayground/handlers'
            if (-not $script:DpResponses.ContainsKey($handlerPath)) { $script:DpResponses[$handlerPath] = @() }
            $script:DpResponses[$handlerPath] += @{ incidentFilterId = "incidentFilters-$i"; customInstructions = '# Handle incidents' }
            $repoItems += @{ name = "repo-$i"; properties = @{ url = 'https://github.com/example/repo'; type = 'GitHub' } }
            $script:DpResponses["/api/v1/WorkspaceMemory/list?type=repo-instructions&repo=repo-$i"] = @{
                value = @(@{ path = 'instructions.md'; size = 0 })
            }
            $script:DpResponses['/api/v2/plugins/marketplaces'] = @{ value = @(@{ metadata = @{ name = 'market' }; spec = @{ url = 'https://market.example.test' } }) }
            $script:DpResponses['/api/v2/plugins/installations'] = @(@{ name = 'plugin'; properties = @{ marketplace = 'market' } })
            $triggerPath = '/api/v1/httpTriggers'
            if (-not $script:DpResponses.ContainsKey($triggerPath)) { $script:DpResponses[$triggerPath] = @() }
            $script:DpResponses[$triggerPath] += @{ name = "trigger-$i"; agentPrompt = 'Run'; agent = "subagent-$i" }
            $knowledge += @{ filename = "doc-$i.md"; isIndexed = ($i -eq 0); fileSize = 0 }
            $memories += @{ path = "memory-$i.md"; size = 0 }
            $knowledgeItems += @{
                name = "knowledge-$i"
                properties = @{ dataConnectorType = 'KnowledgeText'; extendedProperties = @{ displayName = "Knowledge $i" } }
            }
            $insights += @{ id = "insight-$i"; title = "Insight $i"; insightMarkdown = '# Learned pattern' }
        }
        foreach ($path in @($dpPaths.Values)) {
            if ($case.Wrapped -and $script:DpResponses.ContainsKey($path)) {
                $script:DpResponses[$path] = @{ value = $script:DpResponses[$path] }
            }
        }
        if ($case.Wrapped -and $script:DpResponses.ContainsKey('/api/v1/httpTriggers')) {
            $script:DpResponses['/api/v1/httpTriggers'] = @{ value = $script:DpResponses['/api/v1/httpTriggers'] }
        }
        $script:DpResponses['/api/v2/repos/'] = @{ value = $repoItems }
        $script:DpResponses['/api/v1/AgentMemory/files'] = @{ files = $knowledge }
        $script:DpResponses['/api/v1/WorkspaceMemory/list?type=synthesized-knowledge'] = @{ files = $memories }
        $script:DpResponses['/api/v1/WorkspaceMemory/list'] = @{ value = $memories }
        $script:DpResponses['/api/v1/threads/insights?skip=0&take=1000'] = @{ insights = $insights }
        $dpConnectors = @(
            foreach ($connector in $script:ArmResources.connectors) {
                @{ name = $connector.name.Split('/')[-1]; properties = $connector.properties }
            }
        ) + $knowledgeItems
        $script:DpResponses['/api/v2/extendedAgent/connectors'] = @{ value = $dpConnectors }
        $global:ExportJsonTestState = [pscustomobject]@{
            AgentResponse = $script:AgentResponse
            ArmResources = $script:ArmResources
            DpResponses = $script:DpResponses
            Requests = @()
            DownloadPaths = @()
        }

        & $body 6>$null

        $agentConfig = Read-JsonFile 'agent.json'
        $connectorConfig = Read-JsonFile 'connectors.json'
        $expected = Read-JsonFile 'expected-config.json'
        Assert-True ($connectorConfig.connectors -is [array]) "$($case.Name): connectors lost array shape."
        Assert-True ($connectorConfig.connectors.Count -eq $case.Count) "$($case.Name): wrong connector count."
        foreach ($field in @('skills', 'subagents', 'hooks', 'commonPrompts', 'scheduledTasks', 'responsePlans', 'repos')) {
            $value = $expected[$field]
            Assert-True ($value -is [array] -and $value.Count -eq $case.Count) "$($case.Name): invalid $field array."
        }
        Assert-True ($expected.connectors -is [array]) 'Expected connectors lost array shape.'
        Assert-True ($connectorConfig.toggles.enableAzureMonitorConnector -is [bool]) 'Connector toggle lost boolean type.'
        Assert-True ($connectorConfig.toggles.azureMonitorLookbackDays -eq $(if ($case.Count) { 0 } else { 7 })) 'Lookback value changed.'
        Assert-True ($expected.agent.upgradeChannel -eq 'Stable' -and $agentConfig.upgradeChannel -eq 'Preview') 'Existing deployment defaults changed.'
        if ($case.Overrides) {
            Assert-True ($agentConfig.identity.agentName -eq 'clone' -and $agentConfig.identity.location -eq 'uksouth') 'Identity overrides failed.'
            Assert-True ($agentConfig.identity.resourceGroup -eq 'clone-rg' -and $agentConfig.identity.targetResourceGroups -eq 'clone-target') 'Resource overrides failed.'
            Assert-True ($agentConfig.access.accessLevel -eq 'High' -and $agentConfig.access.actionMode -eq 'Autonomous') 'Access overrides failed.'
        } else {
            Assert-True ($agentConfig.identity.targetResourceGroups -is [array]) 'Target resource groups lost array shape.'
            Assert-True ($agentConfig.identity.targetResourceGroups.Count -eq $(if ($case.Count) { 2 } else { 0 })) 'Resource groups were not deduplicated.'
        }
        Assert-True ((Get-Content -LiteralPath (Join-Path $Output '.gitignore') -Raw) -match 'connectors.secrets.env') 'Secrets are not ignored.'
        if ($case.Count -gt 0) {
            $skill = Read-YamlFile 'config\skills\skills-0.yaml'
            $toolCount = if ($case.Name -eq 'single-arm') { 0 } else { 1 }
            Assert-True ($skill.metadata.spec.tools -is [array] -and $skill.metadata.spec.tools.Count -eq $toolCount) 'Skill tools changed.'
            if ($case.Count -gt 1) {
                $secondSkill = Read-YamlFile 'config\skills\skills-1.yaml'
                Assert-True ($secondSkill.metadata.spec.tools.Count -eq 2) 'Multiple skill tools changed.'
            }
            Assert-True ($skill.skillContent -eq 'skills/skills-0.md') 'Skill content reference changed.'
            Assert-True ($skill.additionalFiles[0].content -eq 'skills-0/guide.md') 'Additional skill file reference is invalid.'
            Assert-True ((Get-Content -LiteralPath (Join-Path $Output 'config\skills\skills-0\guide.md') -Raw) -eq '# Guide') 'Additional skill file content missing.'
            $tool = Read-YamlFile 'config\tools\tools-0.yaml'
            Assert-True ($tool.spec.nested.entries -is [array] -and $tool.spec.nested.entries.Count -eq 0) 'Nested empty array changed.'
            Assert-True ($tool.spec.nested.enabled -eq $false -and $tool.spec.nested.limit -eq 0) 'Nested false/zero changed.'
            $subagent = Read-YamlFile 'config\subagents\subagents-0.yaml'
            Assert-True ($subagent.spec.instructions -eq 'subagents/subagents-0.instructions.md') 'Subagent instructions reference changed.'
            Assert-True ($subagent.spec.handoffDescription -eq 'subagents-0.handoff.md') 'Handoff reference changed.'
            $filter = Read-YamlFile 'automations\incident-filters\incidentFilters-0.yaml'
            Assert-True ($filter.spec.customInstructions -eq '# Handle incidents') 'Incident handler instructions were not merged.'
            $trigger = Read-YamlFile 'automations\http-triggers\trigger-0.yaml'
            Assert-True ($trigger.spec.prompt -eq 'Run' -and $trigger.spec.agentMode -eq 'Review') 'HTTP trigger mapping changed.'
            $repo = Read-YamlFile 'config\repos\repo-0.yaml'
            Assert-True ($repo.spec.type -eq 'github' -and $repo.spec.branch -eq 'main') 'Repository defaults changed.'
            $plugin = Read-YamlFile 'config\plugin-configs\pluginConfigs-0.yaml'
            $enabled = Get-ConfigValue $plugin @('spec.enabled', 'properties.enabled')
            Assert-True ($enabled -eq $false) 'Plugin configuration changed.'
            $prompt = Read-YamlFile 'config\common-prompts\commonPrompts-0.yaml'
            Assert-True ((Get-ConfigValue $prompt @('spec.prompt', 'properties.prompt')) -eq '# Shared prompt') 'Common prompt changed.'
            $platformConfig = Read-YamlFile 'automations\incident-platforms\pagerduty.yaml'
            $key = if ($case.Overrides) { "test-key'with-quotes" } else { '${PAGERDUTY_API_KEY}' }
            Assert-True ($platformConfig.spec.connectionKey -eq $key) 'Incident platform connection key missing.'
            $docs = @(Read-JsonFile 'data\knowledge.json')
            Assert-True ($docs.Count -eq $case.Count -and $docs[0].indexStatus -eq 'indexed') 'Knowledge document mapping changed.'
            if ($case.Count -gt 1) { Assert-True ($docs[1].indexStatus -eq 'pending') 'False indexing status was lost.' }
            $items = @(Read-JsonFile 'data\knowledge-items.json')
            Assert-True ($items.Count -eq $case.Count -and $items[0].displayName -eq 'Knowledge 0') 'Knowledge items changed.'
            $repoInstructions = @(Read-JsonFile 'data\repo-instructions.json')
            Assert-True ($repoInstructions.Count -eq $case.Count -and $repoInstructions[0].files -is [array]) 'Repository instruction file array changed.'
            Assert-True ((Read-JsonFile 'admin-settings.json').adminUsers -is [array]) 'Admin user array changed.'
            $insight = Read-YamlFile 'data\session-insights\insight-0.yaml'
            Assert-True ($insight.insightMarkdown -eq 'session-insights/insight-0.md' -and $insight.feedbackCount -eq 0) 'Session insight mapping changed.'
            if ($case.Download) {
                Assert-True (Test-Path -LiteralPath (Join-Path $Output 'data\knowledge-items\knowledge-0.md')) 'Knowledge download missing.'
                Assert-True (Test-Path -LiteralPath (Join-Path $Output 'data\synthesized-knowledge\memory.md')) 'Memory download missing.'
                Assert-True (Test-Path -LiteralPath (Join-Path $Output 'data\repo-instructions\repo-0\instructions.md')) 'Repository instruction download missing.'
                Assert-True (-not (Test-Path -LiteralPath "${Output}-files")) 'Download staging directory was not removed.'
                Assert-True ($repoInstructions[0].files[0].content -eq '# Downloaded memory') 'Downloaded instruction content changed.'
            }
        }
        foreach ($download in $global:ExportJsonTestState.DownloadPaths) {
            Assert-True (-not (Test-Path -LiteralPath $download)) 'Temporary download was not cleaned up or moved.'
        }
        Write-Host "PASS: $($case.Name) export"
        $constrainedOutput = "${Output}-constrained"
        Invoke-ConstrainedExport $constrainedOutput $case.Download
        foreach ($filename in @('agent.json', 'connectors.json', 'expected-config.json')) {
            $actual = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $constrainedOutput $filename) -Raw) -AsHashtable
            $reference = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $Output $filename) -Raw) -AsHashtable
            if ($filename -eq 'agent.json') {
                $actual.Remove('_exported_at')
                $reference.Remove('_exported_at')
            }
            Assert-True ((ConvertTo-Json -InputObject $actual -Depth 100 -Compress) -ceq (ConvertTo-Json -InputObject $reference -Depth 100 -Compress)) "Constrained $filename differs."
        }
        $yamlFiles = @(Get-ChildItem -LiteralPath $Output -Recurse -Filter '*.yaml' -File)
        $constrainedYamlFiles = @(Get-ChildItem -LiteralPath $constrainedOutput -Recurse -Filter '*.yaml' -File)
        Assert-True ($yamlFiles.Count -eq $constrainedYamlFiles.Count) 'Constrained YAML file count differs.'
        foreach ($file in $yamlFiles) {
            $relative = $file.FullName.Substring($Output.Length + 1)
            $reference = Get-Content -LiteralPath $file.FullName -Raw
            $actual = Get-Content -LiteralPath (Join-Path $constrainedOutput $relative) -Raw
            Assert-True ($actual -ceq $reference) "Constrained YAML differs: $relative"
        }
        Write-Host "PASS: $($case.Name) export in ConstrainedLanguage"
    }

    $script:DpResponses['/api/v2/extendedAgent/connectors'] = @{ value = @() }
    $AGENT_ENDPOINT = 'https://agent.example.test'
    Assert-True ($null -eq (Invoke-DpGet '/http-error')) 'HTTP failure contract changed.'
    $failed = $false
    try { Invoke-DpGet '/invalid-json' | Out-Null } catch { $failed = $true }
    Assert-True $failed 'Invalid JSON must fail explicitly.'
    $destination = Join-Path $tempRoot 'failed-download.txt'
    Assert-True (-not (Invoke-DpDownload '/http-error' $destination)) 'Failed download reported success.'
    Write-Host 'PASS: optional values, secret sanitizing, and HTTP/JSON failures'

    $global:ExportJsonTestState.Requests = @()
    $dryOutput = Join-Path $tempRoot 'dry-run'
    $dryLog = & $exporter -Subscription test-sub -ResourceGroup test-rg -AgentName test-agent `
        -Output $dryOutput -NoInstallDependencies -NoDownload -NoKnowledge -NoMemories -DryRun 6>&1
    Assert-True ($LASTEXITCODE -eq 0) "Full exporter invocation failed: $($dryLog -join [Environment]::NewLine)"
    Assert-True (-not (Test-Path -LiteralPath $dryOutput)) 'Dry run wrote configuration files.'
    Assert-True ($global:ExportJsonTestState.Requests -notcontains '/api/v1/AgentMemory/files') 'Knowledge skip flag was ignored.'
    Assert-True ($global:ExportJsonTestState.Requests -notcontains '/api/v1/WorkspaceMemory/list') 'Memory skip flag was ignored.'
    Assert-True ($global:ExportJsonTestState.Requests -notcontains '/api/v1/WorkspaceMemory/list?type=repo-instructions&repo=repo-0') 'Repository instructions were included by default.'
    Write-Host 'PASS: full exporter prerequisites, dry run, and skip flags without the removed CLI'
} finally {
    Remove-Variable -Name ExportJsonTestState -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
