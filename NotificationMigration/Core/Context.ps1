# Run context: everything a stage needs, passed explicitly (no globals).
#   $Ctx.Config    merged + validated config
#   $Ctx.Store     JSONL store handle
#   $Ctx.Audit     hash-chained audit log for this run
#   $Ctx.RunId     unique id of this invocation
#   $Ctx.Operator  DOMAIN\user running the command
#   $Ctx.DryRun    no copying / no target writes
#   $Ctx.SidMap    target->source SID map (compare.acl.mode = mapped)

function New-MigContext {
    param([Parameter(Mandatory = $true)][string] $ConfigPath, [System.Collections.IDictionary] $Override,
          [switch] $DryRun, [string] $Operator)
    $cfg = Get-MigrationConfig -Path $ConfigPath -Override $Override
    foreach ($k in @('storeDir', 'reportDir', 'logDir')) { Assert-MigPathNotUnderSource -Path $cfg._resolved[$k] -SourceRoot $cfg.paths.sourceRoot }
    $runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    if (-not $Operator) { $Operator = Get-MigOperator }
    $ctx = [pscustomobject]@{
        Config   = $cfg
        Store    = Initialize-MigStore -Path $cfg._resolved.storeDir
        Audit    = New-MigAuditLog -LogDir $cfg._resolved.logDir -RunId $runId -Algorithm $cfg.audit.hashAlgorithm -HashChain ([bool]$cfg.audit.hashChain)
        RunId    = $runId
        Operator = $Operator
        DryRun   = [bool]$DryRun
        SidMap   = Get-MigSidMap -Config $cfg
    }
    Write-MigAudit -Audit $ctx.Audit -Operator $Operator -Event 'run.started' -Data ([ordered]@{
        config_path = $cfg._meta.configPath; config_hash = $cfg._meta.configHash; dry_run = [bool]$DryRun
        ps_version = $PSVersionTable.PSVersion.ToString(); module_version = $script:MigModuleVersion
    })
    Invoke-MigAuditSealOrphans -Audit $ctx.Audit -Operator $Operator
    return $ctx
}

function Close-MigContext {
    param([Parameter(Mandatory = $true)] $Ctx)
    Close-MigAuditLog -Audit $Ctx.Audit
}

function Invoke-MigStageRun {
    <#
    Wraps one stage execution for one scope:
      scope lock -> gate check -> 'started' -> action -> audit 'stage.completed' -> store 'completed' (with audit ref).
    The audit line is written BEFORE the store event, so every approvable completion is provably in the audit log.
    $Action is a scriptblock or command name, invoked with @Parameters; it returns a summary hashtable.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $Stage, [string] $BatchId,
          [Parameter(Mandatory = $true)] $Action, [hashtable] $Parameters = @{})
    $scope = Get-MigStageScope -Stage $Stage -BatchId $BatchId
    $lock = Lock-MigScope -Ctx $Ctx -Scope $scope
    try {
        Assert-MigStageReady -Ctx $Ctx -Stage $Stage -BatchId $BatchId
        $started = [DateTime]::UtcNow
        Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'stage.started' -Data ([ordered]@{ stage = $Stage; scope = $scope; dry_run = $Ctx.DryRun })
        Add-MigStageEvent -Store $Ctx.Store -Stage $Stage -Scope $scope -State started -RunId $Ctx.RunId -Operator $Ctx.Operator -DryRun $Ctx.DryRun -AuditRef $Ctx.Audit.LastRef
        try {
            $summary = & $Action @Parameters
            if ($summary -isnot [System.Collections.IDictionary]) { $summary = [ordered]@{ result = $summary } }
        } catch {
            $err = $_.Exception.Message
            Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Level error -Event 'stage.failed' -Data ([ordered]@{ stage = $Stage; scope = $scope; error = $err })
            Add-MigStageEvent -Store $Ctx.Store -Stage $Stage -Scope $scope -State failed -RunId $Ctx.RunId -Operator $Ctx.Operator -DryRun $Ctx.DryRun -Summary @{ error = $err } -AuditRef $Ctx.Audit.LastRef
            throw
        }
        $summary['elapsed_sec'] = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 1)
        Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'stage.completed' -Data ([ordered]@{ stage = $Stage; scope = $scope; summary = $summary })
        Add-MigStageEvent -Store $Ctx.Store -Stage $Stage -Scope $scope -State completed -RunId $Ctx.RunId -Operator $Ctx.Operator -DryRun $Ctx.DryRun -Summary $summary -AuditRef $Ctx.Audit.LastRef
        return $summary
    } finally {
        Unlock-MigScope -Lock $lock
    }
}

function Lock-MigScope {
    <#
    Exclusive lock per scope (a batch, or 'global') so two processes - e.g. local mode on both servers, or two
    operators - can never run stages on the same batch at the same time. Waits up to 30s, then fails clearly.
    A lock left by a killed process is released by the OS when the process dies (FileShare.None handle).
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $Scope)
    $dir = Join-Path $Ctx.Store.Root 'locks'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ($Scope + '.lock')
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($true) {
        try { return [System.IO.File]::Open($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -gt $deadline) { throw "LOCKED: another process is running a stage for scope '$Scope' ($path)." }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Unlock-MigScope {
    param($Lock)
    if ($Lock) { $Lock.Dispose() }
}

function Write-MigProgress {
    <# Observability: progress bar + verbose line. Stages call this per chunk. #>
    param([Parameter(Mandatory = $true)][string] $Activity, [string] $Status, [int] $Done, [int] $Total, [DateTime] $Started)
    $pct = 0
    if ($Total -gt 0) { $pct = [Math]::Min(100, [int](100 * $Done / $Total)) }
    $eta = ''
    if ($Started -and $Done -gt 0 -and $Total -gt $Done) {
        $elapsed = ([DateTime]::UtcNow - $Started.ToUniversalTime()).TotalSeconds
        $eta = ' ETA ' + [TimeSpan]::FromSeconds([int]($elapsed / $Done * ($Total - $Done))).ToString()
    }
    Write-Progress -Activity $Activity -Status ("$Status $Done/$Total$eta") -PercentComplete $pct
}
