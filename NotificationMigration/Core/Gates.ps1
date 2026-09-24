# Maker-checker gates (control C-08).
# A stage may start only when the previous stage in pipeline.stages has COMPLETED for the relevant scope,
# and, if that previous stage is listed in pipeline.gates, a reviewer has APPROVED that exact completion run.
# With makerCheckerDistinctUsers, the approver must differ from the operator who ran the stage.

$script:MigGlobalStages = @('Inventory', 'Batching', 'Delta')

function Get-MigStageScope {
    <# 'global' for whole-migration stages, otherwise the batch id. #>
    param([Parameter(Mandatory = $true)][string] $Stage, [string] $BatchId)
    if ($script:MigGlobalStages -contains $Stage) { return 'global' }
    if ($Stage -eq 'Report' -and -not $BatchId) { return 'global' }
    if (-not $BatchId) { throw "Stage '$Stage' needs a batch id." }
    return $BatchId
}

function Get-MigPreviousStage {
    param([Parameter(Mandatory = $true)] $Config, [Parameter(Mandatory = $true)][string] $Stage)
    if ($Stage -eq 'Delta') { return $null }   # not chained: can run whenever inventory exists
    $stages = @($Config.pipeline.stages)
    $i = [array]::IndexOf($stages, $Stage)
    if ($i -le 0) { return $null }
    return $stages[$i - 1]
}

function Get-MigGateApproval {
    <# Latest decision for (stage, scope, run_id), or $null. Pass -Records to reuse an already-read gates.jsonl. #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $Stage, [Parameter(Mandatory = $true)][string] $Scope,
          [Parameter(Mandatory = $true)][string] $RunId, [object[]] $Records)
    if ($null -eq $Records) { $Records = Read-MigStoreRecords -Store $Store -Name 'gates.jsonl' }
    $latest = $null
    foreach ($g in $Records) {
        if ($g['stage'] -eq $Stage -and $g['scope'] -eq $Scope -and $g['run_id'] -eq $RunId) { $latest = $g }
    }
    return $latest
}

function Get-MigStageChain {
    <# Stages before $Stage in pipeline order, nearest first, each with its scope. Delta counts as a re-inventory. #>
    param([Parameter(Mandatory = $true)] $Config, [Parameter(Mandatory = $true)][string] $Stage, [string] $BatchId)
    $stages = @($Config.pipeline.stages)
    $i = [array]::IndexOf($stages, $Stage)
    $chain = @()
    for ($j = $i - 1; $j -ge 0; $j--) { $chain += , @{ stage = $stages[$j]; scope = (Get-MigStageScope -Stage $stages[$j] -BatchId $BatchId) } }
    return $chain
}

function Test-MigSummaryPassed {
    <# A stage summary counts as failed when it reports passed/parity = false or failed files. #>
    param($Summary)
    if ($null -eq $Summary) { return $true }
    foreach ($k in @('passed', 'parity')) { if ($Summary.Contains($k) -and $Summary[$k] -eq $false) { return $false } }
    foreach ($k in @('files_failed')) { if ($Summary.Contains($k) -and [long]$Summary[$k] -gt 0) { return $false } }
    return $true
}

function Test-MigStageReady {
    <#
    Returns @{ ready = bool; reason = string }. Does not throw. For a real (non-dry) run of $Stage:
      1. the previous pipeline stage's latest REAL event must be a completion (not a newer failed/in-progress run);
      2. if that stage is gated, that exact completion must be approved, and the approval must be provable in
         the hash-chained audit log (a line added to gates.jsonl by hand does not count);
      3. the chain must be fresh: every earlier stage (and Delta, which re-inventories) completed BEFORE the
         previous stage's approved run - re-running an earlier stage invalidates later approvals.
    Dry-run events never satisfy or block a real run. A dry run of a stage needs no approvals.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $Stage, [string] $BatchId)
    if ($Ctx.DryRun) { return @{ ready = $true; reason = $null } }
    $events = Read-MigStoreRecords -Store $Ctx.Store -Name 'stages.jsonl'
    $gates = Read-MigStoreRecords -Store $Ctx.Store -Name 'gates.jsonl'
    $logDir = $Ctx.Config._resolved.logDir

    # Delta and the global/final Report: need an approved Inventory (Delta runs at freeze; the final report must
    # never be produced from an unreviewed manifest).
    if ($Stage -eq 'Delta' -or ($Stage -eq 'Report' -and -not $BatchId)) {
        $inv = Get-MigLatestStageEvent -Store $Ctx.Store -Stage 'Inventory' -Scope 'global' -CompletedOnly -RealOnly -Records $events
        if (-not $inv) { return @{ ready = $false; reason = "Stage '$Stage' requires a completed Inventory." } }
        if (@($Ctx.Config.pipeline.gates) -contains 'Inventory') {
            $g = Get-MigGateApproval -Store $Ctx.Store -Stage 'Inventory' -Scope 'global' -RunId $inv['run_id'] -Records $gates
            if (-not $g -or $g['decision'] -ne 'approved') { return @{ ready = $false; reason = "Gate 'Inventory' (run $($inv['run_id'])) is not approved." } }
        }
        return @{ ready = $true; reason = $null }
    }

    $prev = Get-MigPreviousStage -Config $Ctx.Config -Stage $Stage
    if (-not $prev) { return @{ ready = $true; reason = $null } }
    $scope = Get-MigStageScope -Stage $prev -BatchId $BatchId
    $last = Get-MigLatestStageEvent -Store $Ctx.Store -Stage $prev -Scope $scope -RealOnly -Records $events
    # A Delta is a newer inventory: when it completed after the Inventory, it becomes the input that the
    # next stage (normally Batching) depends on, and its own gate approval is what counts.
    if ($prev -eq 'Inventory') {
        $delta = Get-MigLatestStageEvent -Store $Ctx.Store -Stage 'Delta' -Scope 'global' -RealOnly -Records $events
        if ($delta -and (-not $last -or [DateTime]::Parse([string]$delta['ts_utc'], $null, 'RoundtripKind') -gt [DateTime]::Parse([string]$last['ts_utc'], $null, 'RoundtripKind'))) {
            $prev = 'Delta'; $last = $delta
        }
    }
    if (-not $last -or $last['state'] -ne 'completed') {
        if ($last -and $last['state'] -eq 'failed') { return @{ ready = $false; reason = "The latest '$prev' run for scope '$scope' ($($last['run_id'])) failed; re-run it." } }
        if ($last) { return @{ ready = $false; reason = "'$prev' for scope '$scope' has a newer run ($($last['run_id'])) that has not completed." } }
        if (Get-MigLatestStageEvent -Store $Ctx.Store -Stage $prev -Scope $scope -Records $events) { return @{ ready = $false; reason = "Stage '$Stage' requires '$prev' for scope '$scope', which has only completed as a dry run." } }
        return @{ ready = $false; reason = "Stage '$Stage' requires '$prev' completed for scope '$scope'." }
    }
    if (@($Ctx.Config.pipeline.gates) -contains $prev) {
        $g = Get-MigGateApproval -Store $Ctx.Store -Stage $prev -Scope $scope -RunId $last['run_id'] -Records $gates
        if (-not $g -or $g['decision'] -ne 'approved') {
            return @{ ready = $false; reason = "Gate '$prev' for scope '$scope' (run $($last['run_id'])) is not approved. Run Approve-MigrationGate." }
        }
        if (-not (Test-MigAuditReference -LogDir $logDir -Ref $g['audit_ref'] -Event 'gate.decision')) {
            return @{ ready = $false; reason = "Gate '$prev' for scope '$scope': approval record has no matching entry in the audit log (possible tampering)." }
        }
    }
    # Freshness: nothing upstream that affects this scope may have completed after the previous stage's run.
    $prevTs = [DateTime]::Parse([string]$last['ts_utc'], $null, 'RoundtripKind')
    $stale = Get-MigStaleUpstream -Ctx $Ctx -Events $events -Stage $prev -Scope $scope -BatchId $BatchId -Since $prevTs
    if ($stale) { return @{ ready = $false; reason = "'$($stale.stage)' ($($stale.scope)) was re-run after '$prev' ($scope)$($stale.why); re-run and re-approve '$prev' first." } }
    return @{ ready = $true; reason = $null }
}

function Test-MigEventAffectsBatch {
    <#
    Whether a global Inventory/Delta completion changed data in $BatchId. Uses the summary's affected_batches
    list; a summary without that list is treated as affecting every batch (conservative).
    #>
    param($Event, [string] $BatchId)
    if (-not $BatchId) { return $true }
    $sum = $Event['summary']
    if ($null -eq $sum -or -not ([System.Collections.IDictionary]$sum).Contains('affected_batches')) { return $true }
    return (@($sum['affected_batches']) -contains $BatchId)
}

function Get-MigStaleUpstream {
    <#
    Returns @{stage; scope; why} for the first upstream completion newer than $Since that invalidates a run of
    $Stage/$Scope, or $null. Rules:
      - batch-scoped upstream stages of the same batch: any newer completion invalidates;
      - Inventory / Delta (global): only when they changed this batch (affected_batches);
      - Batching (global) is ignored for batch scopes: a re-plan only matters when a newer Inventory/Delta changed
        this batch, and that case is already caught by the rule above (it also forces Batching to re-run,
        because Copy's previous stage is Batching).
    For global stages ($BatchId empty) every newer upstream completion invalidates.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [object[]] $Events, [Parameter(Mandatory = $true)][string] $Stage,
          [Parameter(Mandatory = $true)][string] $Scope, [string] $BatchId, [Parameter(Mandatory = $true)][DateTime] $Since)
    $upstream = @(Get-MigStageChain -Config $Ctx.Config -Stage $Stage -BatchId $BatchId) + @(@{ stage = 'Delta'; scope = 'global' })
    foreach ($u in $upstream) {
        if (@('Inventory', 'Delta') -notcontains $u.stage) { continue }
        foreach ($e in $Events) {
            if ($e['stage'] -ne $u.stage -or $e['scope'] -ne 'global' -or $e['state'] -ne 'completed' -or $e['dry_run'] -eq $true) { continue }
            if ([DateTime]::Parse([string]$e['ts_utc'], $null, 'RoundtripKind') -le $Since) { continue }
            if (Test-MigEventAffectsBatch -Event $e -BatchId $BatchId) {
                return @{ stage = $u.stage; scope = 'global'; why = $(if ($BatchId) { " and changed batch '$BatchId'" } else { '' }) }
            }
        }
    }
    foreach ($u in $upstream) {
        if (@('Inventory', 'Delta') -contains $u.stage) { continue }
        $ue = Get-MigLatestStageEvent -Store $Ctx.Store -Stage $u.stage -Scope $u.scope -CompletedOnly -RealOnly -Records $Events
        if (-not $ue -or [DateTime]::Parse([string]$ue['ts_utc'], $null, 'RoundtripKind') -le $Since) { continue }
        if ($BatchId -and $u.scope -eq 'global') { continue }
        return @{ stage = $u.stage; scope = $u.scope; why = '' }
    }
    return $null
}

function Assert-MigStageReady {
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $Stage, [string] $BatchId)
    $r = Test-MigStageReady -Ctx $Ctx -Stage $Stage -BatchId $BatchId
    if (-not $r.ready) { throw "GATE: $($r.reason)" }
}

function Set-MigGateDecision {
    <#
    Records a checker's decision on the latest REAL completed run of a stage. Refuses:
      - the maker approving their own run (pipeline.makerCheckerDistinctUsers);
      - approving a run whose summary shows failure (pipeline.requireSuccessToApprove), unless -Override with a
        comment - the override is recorded and shown in reports.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $Stage, [string] $BatchId,
          [Parameter(Mandatory = $true)][ValidateSet('approved', 'rejected')][string] $Decision, [string] $Comment, [switch] $Override)
    $scope = Get-MigStageScope -Stage $Stage -BatchId $BatchId
    $done = Get-MigLatestStageEvent -Store $Ctx.Store -Stage $Stage -Scope $scope -RealOnly
    if (-not $done) {
        if (Get-MigLatestStageEvent -Store $Ctx.Store -Stage $Stage -Scope $scope) { throw "Cannot approve a dry run of '$Stage' for '$scope'; only real runs can be approved." }
        throw "Nothing to approve: '$Stage' has not run for scope '$scope'."
    }
    if ($done['state'] -ne 'completed') { throw "Cannot decide on '$Stage' for '$scope': its latest run ($($done['run_id'])) is '$($done['state'])'." }
    if ($Ctx.Config.pipeline.makerCheckerDistinctUsers -and $done['operator'] -eq $Ctx.Operator) {
        throw "MAKER-CHECKER: '$($Ctx.Operator)' ran '$Stage' for '$scope' and cannot also approve it."
    }
    $passed = Test-MigSummaryPassed -Summary $done['summary']
    if ($Decision -eq 'approved' -and -not $passed -and (Get-MigValue $Ctx.Config.pipeline 'requireSuccessToApprove' $true)) {
        if (-not $Override) { throw "'$Stage' for '$scope' did not pass (see its summary). Fix and re-run, or approve with -Override and a justification." }
        if ([string]::IsNullOrWhiteSpace($Comment) -or $Comment.Length -lt 20) { throw 'An override needs a justification comment of at least 20 characters.' }
    }
    $rec = [ordered]@{
        stage = $Stage; scope = $scope; run_id = $done['run_id']; maker = $done['operator']; checker = $Ctx.Operator
        decision = $Decision; comment = $Comment; stage_passed = $passed; override = [bool]($Override -and -not $passed)
        stage_summary = $done['summary']; ts_utc = Get-MigUtcNow
    }
    Write-MigAudit -Audit $Ctx.Audit -Event 'gate.decision' -Data $rec -Operator $Ctx.Operator
    $rec['audit_ref'] = $Ctx.Audit.LastRef
    Add-MigStoreRecord -Store $Ctx.Store -Name 'gates.jsonl' -Record $rec
    return $rec
}
