# Public commands. Every command builds a run context (config + store + audit), does its work, closes the audit log.

$script:MigStageFunctions = @{
    Inventory  = 'Invoke-MigStageInventory'
    Batching   = 'Invoke-MigStageBatching'
    Copy       = 'Invoke-MigStageCopy'
    Verify     = 'Invoke-MigStageVerify'
    Reconcile  = 'Invoke-MigStageReconcile'
    HtmlChecks = 'Invoke-MigStageHtmlChecks'
    Delta      = 'Invoke-MigStageDelta'
    Report     = 'Invoke-MigStageReport'
}

function Invoke-MigStageForScopes {
    <# Runs one stage: once for global stages, or once per batch. Returns @{ ran; skipped; failed }. #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $Stage, [string[]] $Batch, [switch] $Final, [switch] $SkipNotReady)
    $fn = $script:MigStageFunctions[$Stage]
    $result = @{ ran = @(); skipped = @(); failed = @() }

    $isGlobal = ($script:MigGlobalStages -contains $Stage) -or ($Stage -eq 'Report' -and ($Final -or -not $Batch))
    if ($isGlobal) {
        $params = @{ Ctx = $Ctx }
        if ($Stage -eq 'Report') { $params['Final'] = [bool]$Final }
        $s = Invoke-MigStageRun -Ctx $Ctx -Stage $Stage -Action $fn -Parameters $params
        $result.ran += , @{ scope = 'global'; summary = $s }
        return $result
    }

    $batches = @($Batch)
    if (-not $Batch) { $batches = @((Get-MigBatches -Store $Ctx.Store).Keys) }
    if ($batches.Count -eq 0) { throw "No batches found. Run -Stage Batching first." }
    foreach ($b in $batches) {
        if ($SkipNotReady) {
            $ready = Test-MigStageReady -Ctx $Ctx -Stage $Stage -BatchId $b
            if (-not $ready.ready) { $result.skipped += , @{ scope = $b; reason = $ready.reason }; continue }
        }
        try {
            $s = Invoke-MigStageRun -Ctx $Ctx -Stage $Stage -BatchId $b -Action $fn -Parameters @{ Ctx = $Ctx; BatchId = $b }
            $result.ran += , @{ scope = $b; summary = $s }
        } catch {
            $result.failed += , @{ scope = $b; error = $_.Exception.Message }
            Write-Warning "[$Stage/$b] $($_.Exception.Message)"
        }
    }
    return $result
}

function Migrate-Notifications {
    <#
    .SYNOPSIS
    Runs a migration stage. Copy only: nothing under sourceRoot is ever modified.
    .EXAMPLE
    Migrate-Notifications -Stage Inventory -Config .\migration.config.json
    Migrate-Notifications -Stage Copy -Batch 2019-03 -Config .\migration.config.json
    Migrate-Notifications -Stage All -DryRun -Config .\migration.config.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Inventory', 'Batching', 'Copy', 'Verify', 'Reconcile', 'HtmlChecks', 'Delta', 'Report', 'All')][string] $Stage,
        [string] $Config = '.\migration.config.json',
        [string[]] $Batch,
        [switch] $DryRun,
        [switch] $Final,
        [hashtable] $Override
    )
    $ctx = New-MigContext -ConfigPath $Config -Override $Override -DryRun:$DryRun
    try {
        if ($Stage -ne 'All') {
            return Invoke-MigStageForScopes -Ctx $ctx -Stage $Stage -Batch $Batch -Final:$Final
        }
        # All: walk the pipeline. Batch stages run only for batches whose gate is satisfied; gated stages
        # therefore stop the run until a reviewer approves. Dry run = inventory + plan only (FR-10).
        $stages = @($ctx.Config.pipeline.stages)
        if ($DryRun) { $dryStages = @($ctx.Config.pipeline.dryRunStages); $stages = @($stages | Where-Object { $dryStages -contains $_ }) }
        $all = [ordered]@{}
        foreach ($s in $stages) {
            $ready = $true
            if ($script:MigGlobalStages -contains $s) { $ready = (Test-MigStageReady -Ctx $ctx -Stage $s).ready }
            if (-not $ready) { Write-Warning "Stopping at '$s': $((Test-MigStageReady -Ctx $ctx -Stage $s).reason)"; break }
            if ($s -eq 'Report') {
                # Per-batch reports for batches that are ready, then the final report.
                if (-not $DryRun -and (Get-MigBatches -Store $ctx.Store).Count -gt 0) {
                    $reportBatches = @($Batch)
                    if (-not $Batch) { $reportBatches = @((Get-MigBatches -Store $ctx.Store).Keys) }
                    $all['Report.batches'] = Invoke-MigStageForScopes -Ctx $ctx -Stage 'Report' -Batch $reportBatches -SkipNotReady
                }
                $all['Report.final'] = Invoke-MigStageForScopes -Ctx $ctx -Stage 'Report' -Final
                continue
            }
            $all[$s] = Invoke-MigStageForScopes -Ctx $ctx -Stage $s -Batch $Batch -SkipNotReady
        }
        return $all
    } finally {
        Close-MigContext -Ctx $ctx
    }
}

function Approve-MigrationGate {
    <# Reviewer (checker) approves or rejects the latest completed run of a stage for a batch (or global stage). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Inventory', 'Batching', 'Copy', 'Verify', 'Reconcile', 'HtmlChecks', 'Delta', 'Report')][string] $Stage,
        [string] $Config = '.\migration.config.json',
        [string] $Batch,
        [switch] $Reject,
        [Parameter(Mandatory = $true)][string] $Comment,
        [switch] $Override
    )
    $ctx = New-MigContext -ConfigPath $Config
    try {
        $decision = 'approved'
        if ($Reject) { $decision = 'rejected' }
        return Set-MigGateDecision -Ctx $ctx -Stage $Stage -BatchId $Batch -Decision $decision -Comment $Comment -Override:$Override
    } finally { Close-MigContext -Ctx $ctx }
}

function Get-MigrationStatus {
    <# Per-batch view: latest state of each stage, gate decision, open exceptions. #>
    [CmdletBinding()]
    param([string] $Config = '.\migration.config.json')
    $cfg = Get-MigrationConfig -Path $Config
    $store = Initialize-MigStore -Path $cfg._resolved.storeDir
    $stageEvents = Read-MigStoreRecords -Store $store -Name 'stages.jsonl'
    $gates = Read-MigStoreRecords -Store $store -Name 'gates.jsonl'
    $openEx = Get-MigExceptions -Store $store -Status 'open'
    $scopes = @('global') + @((Get-MigBatches -Store $store).Keys)
    $stageNames = @($cfg.pipeline.stages) + @('Delta', 'Report') | Select-Object -Unique
    foreach ($scope in $scopes) {
        $row = [ordered]@{ Scope = $scope }
        foreach ($st in $stageNames) {
            $row[$st] = ''   # every row has every column, so Format-Table shows them all
            $ev = $stageEvents | Where-Object { $_['stage'] -eq $st -and $_['scope'] -eq $scope } | Select-Object -Last 1
            if (-not $ev) { continue }
            $state = $ev['state']
            $g = $gates | Where-Object { $_['stage'] -eq $st -and $_['scope'] -eq $scope -and $_['run_id'] -eq $ev['run_id'] } | Select-Object -Last 1
            if ($g) { $state += "/$($g['decision'])" }
            $row[$st] = $state
        }
        $row['OpenExceptions'] = @($openEx | Where-Object { $_['batch_id'] -eq $scope }).Count
        [pscustomobject]$row
    }
}

function Get-MigrationException {
    [CmdletBinding()]
    param([string] $Config = '.\migration.config.json', [string] $Batch, [ValidateSet('open', 'resolved', 'accepted')][string] $Status)
    $cfg = Get-MigrationConfig -Path $Config
    $store = Initialize-MigStore -Path $cfg._resolved.storeDir
    Get-MigExceptions -Store $store -BatchId $Batch -Status $Status | ForEach-Object { [pscustomobject]$_ }
}

function Set-MigrationException {
    <# Assign an owner / record a resolution in the exception register (C-06). Audited. #>
    [CmdletBinding()]
    param([string] $Config = '.\migration.config.json', [Parameter(Mandatory = $true)][string] $Id,
          [ValidateSet('open', 'resolved', 'accepted')][string] $Status, [string] $Resolution, [string] $Owner)
    $ctx = New-MigContext -ConfigPath $Config
    try {
        if ($Status -and $Status -ne 'open' -and -not $Resolution) { throw 'A resolution note is required to close an exception.' }
        $null = Update-MigException -Store $ctx.Store -Id $Id -Status $Status -Resolution $Resolution -Owner $Owner -By $ctx.Operator
        Write-MigAudit -Audit $ctx.Audit -Operator $ctx.Operator -Event 'exception.updated' -Data ([ordered]@{ id = $Id; status = $Status; owner = $Owner; resolution = $Resolution })
    } finally { Close-MigContext -Ctx $ctx }
}

function Test-MigrationAuditLog {
    <# Verifies the hash chain and checksum of one audit log (or every log in a folder). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    $files = @()
    if (Test-Path -LiteralPath $Path -PathType Container) { $files = @(Get-ChildItem -LiteralPath $Path -Filter 'run-*.jsonl' | ForEach-Object { $_.FullName }) }
    else { $files = @($Path) }
    foreach ($f in $files) {
        $r = Test-MigAuditChain -Path $f
        [pscustomobject]@{ Path = $f; Valid = $r.valid; Lines = $r.lines; Error = $r.error }
    }
}

function Register-MigrationFreeze {
    <#
    Control C-02 evidence before the final Delta: reads the ACL of sourceRoot and records it (SDDL + hash).
    Fails when any principal outside freeze.allowedWriters holds write/modify/delete rights on the source root,
    i.e. the source is not actually frozen. Windows only (needs NTFS ACLs).
    #>
    [CmdletBinding()]
    param([string] $Config = '.\migration.config.json', [Parameter(Mandatory = $true)][string] $Comment)
    $ctx = New-MigContext -ConfigPath $Config
    try {
        if (-not (Test-MigIsWindows)) { throw 'Register-MigrationFreeze needs Windows (NTFS ACLs).' }
        $root = $ctx.Config.paths.sourceRoot
        $acl = Get-Acl -LiteralPath $root
        $allowed = @($ctx.Config.freeze.allowedWriters)
        $writeRights = [System.Security.AccessControl.FileSystemRights]'Write, Modify, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
        $violations = @(foreach ($r in $acl.Access) {
            if ($r.AccessControlType -ne 'Allow') { continue }
            if (($r.FileSystemRights -band $writeRights) -eq 0) { continue }
            $who = $r.IdentityReference.Value
            if (@($allowed | Where-Object { $who -like $_ }).Count -gt 0) { continue }
            '{0} ({1})' -f $who, $r.FileSystemRights
        })
        $rec = [ordered]@{ source_root = $root; sddl = $acl.Sddl; sddl_hash = Get-MigStringHash -Text $acl.Sddl
                           frozen = ($violations.Count -eq 0); violations = $violations; recorded_by = $ctx.Operator; comment = $Comment; ts_utc = Get-MigUtcNow }
        Write-MigAudit -Audit $ctx.Audit -Operator $ctx.Operator -Event 'freeze.recorded' -Data $rec
        $rec['audit_ref'] = $ctx.Audit.LastRef
        Add-MigStoreRecord -Store $ctx.Store -Name 'freeze.jsonl' -Record $rec
        if ($violations.Count -gt 0) { throw "Source is NOT frozen. Principals with write/delete rights: $($violations -join '; ')" }
        return [pscustomobject]$rec
    } finally { Close-MigContext -Ctx $ctx }
}

function Approve-MigrationSignOff {
    <#
    Control C-09: records one of the three sign-offs on the latest final report. Each role must be signed by a
    different person, and nobody who operated (made) a stage may sign as Control owner.
    #>
    [CmdletBinding()]
    param([string] $Config = '.\migration.config.json',
          [Parameter(Mandatory = $true)][ValidateSet('SourceOwner', 'TargetOwner', 'ControlOwner')][string] $Role,
          [Parameter(Mandatory = $true)][string] $Comment)
    $ctx = New-MigContext -ConfigPath $Config
    try {
        $final = Get-MigLatestStageEvent -Store $ctx.Store -Stage 'Report' -Scope 'global' -CompletedOnly -RealOnly
        if (-not $final -or -not ($final['summary'] -and $final['summary']['final'])) { throw 'Run Migrate-Notifications -Stage Report -Final first; sign-off applies to a final report.' }
        $existing = @(Read-MigStoreRecords -Store $ctx.Store -Name 'signoff.jsonl' | Where-Object { $_['report_run_id'] -eq $final['run_id'] })
        foreach ($e in $existing) {
            if ($e['role'] -eq $Role) { throw "Role '$Role' has already signed report run $($final['run_id'])." }
            if ($e['signer'] -eq $ctx.Operator) { throw "'$($ctx.Operator)' already signed as '$($e['role'])'; the three roles need three different people." }
        }
        if ($Role -eq 'ControlOwner') {
            $makers = @(Read-MigStoreRecords -Store $ctx.Store -Name 'stages.jsonl' | Where-Object { $_['state'] -eq 'completed' -and -not $_['dry_run'] } | ForEach-Object { $_['operator'] } | Select-Object -Unique)
            if ($makers -contains $ctx.Operator) { throw "'$($ctx.Operator)' operated migration stages and cannot sign as Control owner." }
        }
        $rec = [ordered]@{ role = $Role; signer = $ctx.Operator; report_run_id = $final['run_id']; report_summary = $final['summary']; comment = $Comment; ts_utc = Get-MigUtcNow }
        Write-MigAudit -Audit $ctx.Audit -Operator $ctx.Operator -Event 'signoff.recorded' -Data $rec
        $rec['audit_ref'] = $ctx.Audit.LastRef
        Add-MigStoreRecord -Store $ctx.Store -Name 'signoff.jsonl' -Record $rec
        return [pscustomobject]$rec
    } finally { Close-MigContext -Ctx $ctx }
}

function Register-MigrationRetention {
    <# Control C-10: records the retention ticket and the date until which the source must be kept. #>
    [CmdletBinding()]
    param([string] $Config = '.\migration.config.json', [Parameter(Mandatory = $true)][string] $Ticket,
          [Parameter(Mandatory = $true)][DateTime] $RetainUntil, [string] $Comment)
    $ctx = New-MigContext -ConfigPath $Config
    try {
        $rec = [ordered]@{ ticket = $Ticket; retain_until = $RetainUntil.ToUniversalTime().ToString('o'); recorded_by = $ctx.Operator; comment = $Comment; ts_utc = Get-MigUtcNow }
        Write-MigAudit -Audit $ctx.Audit -Operator $ctx.Operator -Event 'retention.recorded' -Data $rec
        $rec['audit_ref'] = $ctx.Audit.LastRef
        Add-MigStoreRecord -Store $ctx.Store -Name 'retention.jsonl' -Record $rec
        return [pscustomobject]$rec
    } finally { Close-MigContext -Ctx $ctx }
}

function Export-MigrationManifest {
    <#
    Control C-01 evidence: exports each batch's source manifest as CSV with a checksum sidecar under
    <reportDir>/manifests/. Audited. Read-only on source and target.
    #>
    [CmdletBinding()]
    param([string] $Config = '.\migration.config.json', [string[]] $Batch)
    $ctx = New-MigContext -ConfigPath $Config
    try {
        $ids = @($Batch)
        if (-not $Batch) { $ids = @(Get-MigBatchIds -Store $ctx.Store | Where-Object { $_ -ne 'ORPHANS' }) }
        foreach ($b in $ids) { [pscustomobject](Export-MigManifestCsv -Ctx $ctx -BatchId $b) }
    } finally { Close-MigContext -Ctx $ctx }
}
