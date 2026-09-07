[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $PestArgument = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$composeFile = Join-Path $repoRoot 'docker-compose.test.yml'
$projectName = "pixelfed-owner-test-$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
$imageName = "pixelfed-owner-tests:$projectName"
$logPath = Join-Path ([System.IO.Path]::GetTempPath()) "$projectName.log"
$composePrefix = @('--project-name', $projectName, '--file', $composeFile)
$environmentNames = @(
    'COMPOSE_DISABLE_ENV_FILE',
    'OWNER_TEST_SOURCE_SHA',
    'OWNER_TEST_SOURCE_TREE',
    'OWNER_TEST_COMPOSER_LOCK_SHA',
    'OWNER_TEST_IMAGE'
)
$environmentSnapshot = @{}
$environmentWasPresent = @{}
$processEnvironment = [Environment]::GetEnvironmentVariables('Process')
foreach ($environmentName in $environmentNames) {
    $environmentWasPresent[$environmentName] = $processEnvironment.Contains($environmentName)
    if ($environmentWasPresent[$environmentName]) {
        $environmentSnapshot[$environmentName] = [string] $processEnvironment[$environmentName]
    }
}

$sourceSha = $null
$sourceTree = $null
$composerLockSha = $null
$status = 'BLOCKED'
$admission = 'BLOCKED'
$testResult = 'NOT_RUN'
$cleanup = 'NOT_REQUIRED'
$logLifecycle = 'NOT_CREATED'
$reportedLogPath = $null
$failureStep = $null
$failureExitCode = $null
$failureReason = $null
$cleanupRequired = $false

function Get-GitValue {
    param([string[]] $Arguments)

    $value = & git @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'git identity lookup failed'
    }

    return Get-OutputText $value
}

function Get-OutputText {
    param([object[]] $Value)

    if ($null -eq $Value) {
        return ''
    }

    return ([string]::Join([Environment]::NewLine, [string[]] $Value)).Trim()
}

function Invoke-Compose {
    param([string[]] $Arguments)

    & docker compose @composePrefix @Arguments *>> $logPath
    return [int] $LASTEXITCODE
}

function Test-RunImagePresent {
    & docker image inspect $imageName *> $null
    return [int] $LASTEXITCODE -eq 0
}

function Remove-RunImage {
    & docker image rm --force $imageName *>> $logPath
    return [int] $LASTEXITCODE
}

function Test-RunResourcesAbsent {
    $composeResources = & docker compose @composePrefix ps --all --format json 2>> $logPath
    $composeCode = [int] $LASTEXITCODE
    $networks = & docker network ls --filter "label=com.docker.compose.project=$projectName" --format '{{.Name}}' 2>> $logPath
    $networkCode = [int] $LASTEXITCODE
    $volumes = & docker volume ls --filter "label=com.docker.compose.project=$projectName" --format '{{.Name}}' 2>> $logPath
    $volumeCode = [int] $LASTEXITCODE

    return $composeCode -eq 0 -and $networkCode -eq 0 -and $volumeCode -eq 0 -and
        ([string]::IsNullOrWhiteSpace((Get-OutputText $composeResources))) -and
        ([string]::IsNullOrWhiteSpace((Get-OutputText $networks))) -and
        ([string]::IsNullOrWhiteSpace((Get-OutputText $volumes)))
}

function Assert-ComposeIsolation {
    $config = & docker compose @composePrefix config --format json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'docker compose isolation contract could not be read'
    }

    try {
        $document = ([string]::Join([Environment]::NewLine, [string[]] $config)) | ConvertFrom-Json
    }
    catch {
        throw 'docker compose isolation contract is not valid JSON'
    }

    $serviceNames = @($document.services.PSObject.Properties | ForEach-Object { $_.Name })
    if ($serviceNames.Count -ne 2 -or $serviceNames -notcontains 'redis' -or $serviceNames -notcontains 'owner-tests') {
        throw 'owner-test Compose service set is not isolated'
    }

    foreach ($serviceName in $serviceNames) {
        $service = $document.services.$serviceName
        if ($service.PSObject.Properties.Name -contains 'ports' -and $null -ne $service.ports) {
            throw 'owner-test Compose must not publish ports'
        }
        if ($service.PSObject.Properties.Name -contains 'volumes' -and $null -ne $service.volumes) {
            throw 'owner-test Compose must not mount volumes'
        }
    }

    if ($document.PSObject.Properties.Name -contains 'volumes' -and $null -ne $document.volumes) {
        throw 'owner-test Compose must not declare named volumes'
    }
}

try {
    Set-Location $repoRoot

    $sourceSha = Get-GitValue @('rev-parse', 'HEAD')
    $sourceTree = Get-GitValue @('rev-parse', 'HEAD^{tree}')
    $composerLockSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repoRoot 'composer.lock')).Hash.ToLowerInvariant()
    $dirty = Get-GitValue @('status', '--porcelain', '--untracked-files=all')
    if ($dirty) {
        $failureStep = 'source-preflight'
        $failureReason = 'working-tree-not-clean'
        throw 'working tree is not clean'
    }

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $failureStep = 'docker-preflight'
        $failureReason = 'docker-not-found'
        throw 'docker command not found'
    }

    $env:COMPOSE_DISABLE_ENV_FILE = '1'
    $env:OWNER_TEST_SOURCE_SHA = $sourceSha
    $env:OWNER_TEST_SOURCE_TREE = $sourceTree
    $env:OWNER_TEST_COMPOSER_LOCK_SHA = $composerLockSha
    $env:OWNER_TEST_IMAGE = $imageName
    $cleanupRequired = $true

    $failureStep = 'compose-config'
    $exitCode = Invoke-Compose @('config', '--quiet')
    if ($exitCode -ne 0) {
        $failureExitCode = $exitCode
        $failureReason = 'compose-config-failed'
        throw 'docker compose config failed'
    }

    $failureStep = 'compose-isolation-contract'
    Assert-ComposeIsolation

    $failureStep = 'redis-readiness'
    $exitCode = Invoke-Compose @('up', '--detach', '--wait', 'redis')
    if ($exitCode -ne 0) {
        $failureExitCode = $exitCode
        $failureReason = 'redis-not-ready'
        throw 'redis did not become ready'
    }

    $failureStep = 'owner-test-build'
    $exitCode = Invoke-Compose @('build', 'owner-tests')
    if ($exitCode -ne 0) {
        $failureExitCode = $exitCode
        $failureReason = 'owner-test-image-build-failed'
        throw 'owner-test image build failed'
    }

    $admission = 'PASS'
    $failureStep = 'owner-tests'
    $runArguments = @('run', '--rm', '--no-deps', 'owner-tests') + $PestArgument
    $exitCode = Invoke-Compose $runArguments
    if ($exitCode -ne 0) {
        $failureExitCode = $exitCode
        $testResult = 'FAIL'
        $failureReason = 'owner-test-command-failed'
        throw 'owner-test command failed'
    }

    $testResult = 'PASS'
    $status = 'PASS'
    $failureStep = $null
}
catch {
    if (-not $failureReason) {
        $failureReason = 'owner-test-entrypoint-failed'
    }
}
finally {
    try {
        if ($cleanupRequired) {
            $downStep = Invoke-Compose @('down', '--volumes', '--remove-orphans')
            $removeImageStep = Remove-RunImage
            $imageRemains = Test-RunImagePresent
            $resourcesRemain = -not (Test-RunResourcesAbsent)
            if ($downStep -eq 0 -and -not $imageRemains -and -not $resourcesRemain) {
                $cleanup = 'PASS'
            }
            else {
                $cleanup = 'BLOCKED'
                if ($status -eq 'PASS') {
                    $status = 'BLOCKED'
                    $failureStep = 'cleanup'
                    $failureExitCode = if ($downStep -ne 0) { $downStep } elseif ($removeImageStep -ne 0) { $removeImageStep } else { 1 }
                    $failureReason = 'disposable-project-cleanup-failed'
                }
            }
        }
    }
    finally {
        foreach ($environmentName in $environmentNames) {
            if ($environmentWasPresent[$environmentName]) {
                [Environment]::SetEnvironmentVariable($environmentName, $environmentSnapshot[$environmentName], 'Process')
            }
            else {
                [Environment]::SetEnvironmentVariable($environmentName, $null, 'Process')
            }
        }
    }
}

if ($status -eq 'PASS') {
    if (Test-Path -LiteralPath $logPath) {
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $logPath) {
        $status = 'BLOCKED'
        $cleanup = 'BLOCKED'
        $failureStep = 'log-cleanup'
        $failureReason = 'run-log-delete-failed'
        $logLifecycle = 'BLOCKED_DELETE_FAILED'
        $reportedLogPath = $logPath
    }
    else {
        $logLifecycle = 'DELETED_ON_PASS'
    }
}
elseif (Test-Path -LiteralPath $logPath) {
    $logLifecycle = 'RETAINED_FAILURE_DIAGNOSTIC'
    $reportedLogPath = $logPath
}

$result = [ordered] @{
    status = $status
    evidenceClass = 'OWNER TESTS'
    admission = $admission
    testResult = $testResult
    sourceSha = $sourceSha
    sourceTree = $sourceTree
    composerLockSha = $composerLockSha
    project = $projectName
    cleanup = $cleanup
    logLifecycle = $logLifecycle
    logPath = $reportedLogPath
    failureStep = $failureStep
    failureExitCode = $failureExitCode
    failureReason = $failureReason
}

Write-Output ($result | ConvertTo-Json -Compress)

if ($status -eq 'PASS') {
    exit 0
}

exit 1
