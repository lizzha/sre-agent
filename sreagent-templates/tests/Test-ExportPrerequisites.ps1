#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Exporter = Join-Path $Root 'bin\ps\Export-Agent.ps1'
$Pwsh = (Get-Process -Id $PID).Path
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sre-export-prereq-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $TempRoot | Out-Null

try {
    $probe = @'
param([string]$Exporter, [string]$Mode)
$ErrorActionPreference = 'Stop'

function Get-Module {
    param([string]$Name, [switch]$ListAvailable)
    if (($Mode -eq 'import-failure' -and $ListAvailable) -or
        ($Mode -eq 'loaded-import-failure' -and -not $ListAvailable)) {
        [pscustomobject]@{ Name = 'powershell-yaml' }
    }
}
function Install-Module {
    param([string]$Name, [string]$Scope, [string]$Repository, [switch]$Force, [string]$ErrorAction)
    if ($Name -ne 'powershell-yaml' -or $Scope -ne 'CurrentUser' -or $Repository -ne 'PSGallery' -or -not $Force) {
        throw 'Incorrect installation options.'
    }
    Write-Host 'TEST: installation attempted'
    if ($Mode -eq 'install-failure') { throw 'Simulated installation failure.' }
}
function Import-Module {
    param([string]$Name, [string]$Scope, [string]$ErrorAction)
    if ($Name -ne 'powershell-yaml' -or $Scope -ne 'Local') { throw 'Incorrect import options.' }
    throw 'Simulated import failure.'
}
function az { throw 'Azure must not be contacted when a prerequisite fails.' }

& $Exporter -Subscription test-subscription -ResourceGroup test-resource-group -AgentName test-agent `
    -NoInstallDependencies:($Mode -in @('missing', 'import-failure', 'loaded-import-failure'))
exit $LASTEXITCODE
'@
    $probePath = Join-Path $TempRoot 'probe.ps1'
    Set-Content -LiteralPath $probePath -Value $probe
    foreach ($mode in @('missing', 'install-failure', 'import-failure', 'loaded-import-failure', 'install-then-import')) {
        $output = & $Pwsh -NoLogo -NoProfile -File $probePath -Exporter $Exporter -Mode $mode 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"
        if ($exitCode -eq 0) { throw "Exporter unexpectedly succeeded: $mode" }
        if ($text -match 'Azure must not be contacted|Connecting to agent') {
            throw "Exporter contacted Azure before validating prerequisites: $text"
        }
        if ($mode -eq 'missing') {
            if ($text -notmatch 'powershell-yaml is required' -or $text -notmatch 'Install-Module -Name powershell-yaml -Scope CurrentUser') {
                throw "Missing dependency guidance: $text"
            }
            if ($text -match 'TEST: installation attempted') { throw '-NoInstallDependencies was ignored.' }
        } elseif ($mode -eq 'install-failure') {
            if ($text -notmatch 'Could not install powershell-yaml: Simulated installation failure') {
                throw "Installation failure was not reported: $text"
            }
        } else {
            if ($text -notmatch 'Could not import powershell-yaml: Simulated import failure') {
                throw "Import failure was not reported: $text"
            }
            if ($mode -eq 'install-then-import' -and $text -notmatch 'TEST: installation attempted') {
                throw "Automatic installation did not run: $text"
            }
            if ($mode -in @('import-failure', 'loaded-import-failure') -and $text -match 'TEST: installation attempted') {
                throw "An installed module was unnecessarily reinstalled: $text"
            }
        }
        Write-Host "PASS: YAML prerequisite $mode"
    }
} finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force
}
