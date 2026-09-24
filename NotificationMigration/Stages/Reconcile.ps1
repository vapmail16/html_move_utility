# Stage 4: Reconcile (FR-05, FR-06, C-03, C-04, C-05, C-06).
# Compares the batch's source and target manifests with the Compare providers named in compare.fileFields
# (files) and compare.dirFields (directories), classifies every difference, optionally auto-retries the copy
# of fixable items (reconcile.autoRetry) and records the outcome:
#   reconcile.results.<runId>.jsonl  one record per remaining issue (batch info reconcile.results_file names it)
#   file status              verified | mismatch | exception
#   exception register       unresolved items (category = issue category; extras -> extra_on_target), bulk-opened
#   batch info               reconcile = @{ passed; totals per side; counts per category; accepted_issues;
#                            open_exceptions; verify_run_id; results_file; stale = $false; ... }, state
# passed = no issue left except those covered by an ACCEPTED exception (same fingerprint) and no OPEN exception.
# A file whose exceptions are all RESOLVED is re-checked: verified if it now matches, otherwise a new exception
# with the same category is opened. Extras on the target are NEVER deleted.
# With reconcile.compactStore the batch's target manifest is compacted at the end of a real run.

$script:MigReconcileCategoryOrder = @('missing', 'scan_error', 'size_mismatch', 'hash_mismatch', 'metadata_mismatch', 'extra')

function Get-MigCompareCategory {
    param([Parameter(Mandatory = $true)][string] $Field)
    switch ($Field) {
        'exists' { return 'missing' }
        'size'   { return 'size_mismatch' }
        'hash'   { return 'hash_mismatch' }
        default  { return 'metadata_mismatch' }
    }
}

function Get-MigCompareFieldValue {
    <# The manifest value shown in results for a compare field. #>
    param($Record, [Parameter(Mandatory = $true)][string] $Field)
    if ($null -eq $Record) { return $null }
    switch ($Field) {
        'exists'     { return $Record['kind'] }
        'size'       { return $Record['size_bytes'] }
        'hash'       { return $Record['hash'] }
        'created'    { return $Record['created_utc'] }
        'modified'   { return $Record['modified_utc'] }
        'attributes' { return $Record['attributes'] }
        'acl'        { return $Record['acl_hash'] }
        default      { return $Record[$Field] }
    }
}

function Get-MigCompareProviderSet {
    <# Resolves compare providers once: @{ file = [@{ name; sb }]; dir = [...] }. Unknown names throw. #>
    param([Parameter(Mandatory = $true)] $Config)
    $set = @{}
    foreach ($pair in @(@('file', 'compare.fileFields'), @('dir', 'compare.dirFields'))) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($n in @(Get-MigConfigSetting -Config $Config -Path $pair[1])) {
            if (-not $n) { continue }
            $list.Add(@{ name = [string]$n; sb = (Get-MigProvider -Kind Compare -Name ([string]$n)) })
        }
        $set[$pair[0]] = $list.ToArray()
    }
    return $set
}

function New-MigReconcileIssue {
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $RelPath, [string] $Kind,
          [Parameter(Mandatory = $true)][string] $Category, [string] $Field, $SourceValue, $TargetValue, [string] $Detail)
    return [ordered]@{
        run_id = $Ctx.RunId; rel_path = $RelPath; kind = $Kind; category = $Category; field = $Field
        source_value = $SourceValue; target_value = $TargetValue; detail = $Detail; ts_utc = Get-MigUtcNow
    }
}

function Get-MigReconcileIssues {
    <# All issues for one rel_path (empty array when source and target match). #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $RelPath, $Source, $Target,
          [Parameter(Mandatory = $true)] $Providers, $Options)
    $issues = New-Object System.Collections.Generic.List[object]
    $sp = Test-MigRecordPresent $Source
    $tp = Test-MigRecordPresent $Target
    $kind = $null
    if ($sp) { $kind = [string]$Source['kind'] } elseif ($tp) { $kind = [string]$Target['kind'] }

    if ($sp -and ($Source['kind'] -eq 'error' -or $Source['error'])) {
        $issues.Add((New-MigReconcileIssue -Ctx $Ctx -RelPath $RelPath -Kind $kind -Category 'scan_error' -Field 'source' -SourceValue $Source['error'] -Detail "source scan error: $($Source['error'])"))
        return , $issues.ToArray()
    }
    if ($tp -and ($Target['kind'] -eq 'error' -or $Target['error'])) {
        $issues.Add((New-MigReconcileIssue -Ctx $Ctx -RelPath $RelPath -Kind $kind -Category 'scan_error' -Field 'target' -TargetValue $Target['error'] -Detail "target scan error: $($Target['error'])"))
        return , $issues.ToArray()
    }
    if ($sp -and -not $tp) {
        $issues.Add((New-MigReconcileIssue -Ctx $Ctx -RelPath $RelPath -Kind $kind -Category 'missing' -Field 'exists' -SourceValue $Source['kind'] -Detail "$kind missing on target"))
        return , $issues.ToArray()
    }
    if ($tp -and -not $sp) {
        $issues.Add((New-MigReconcileIssue -Ctx $Ctx -RelPath $RelPath -Kind $kind -Category 'extra' -Field 'exists' -TargetValue $Target['kind'] -Detail "$kind exists on target but not in the source manifest"))
        return , $issues.ToArray()
    }
    if (-not $sp -and -not $tp) { return , $issues.ToArray() }

    $list = $Providers.file
    if ($Source['kind'] -eq 'dir') { $list = $Providers.dir }
    foreach ($p in $list) {
        $detail = & $p.sb $Ctx $Source $Target $Options
        if ($null -eq $detail -or [string]::IsNullOrEmpty([string]$detail)) { continue }
        $cat = Get-MigCompareCategory -Field $p.name
        $issues.Add((New-MigReconcileIssue -Ctx $Ctx -RelPath $RelPath -Kind $kind -Category $cat -Field $p.name `
            -SourceValue (Get-MigCompareFieldValue $Source $p.name) -TargetValue (Get-MigCompareFieldValue $Target $p.name) -Detail ([string]$detail)))
        if ($p.name -eq 'exists') { break }   # kind differs: other fields are meaningless
    }
    return , $issues.ToArray()
}

function Get-MigPrimaryCategory {
    param([Parameter(Mandatory = $true)][object[]] $Issues)
    foreach ($c in $script:MigReconcileCategoryOrder) { foreach ($i in $Issues) { if ($i['category'] -eq $c) { return $c } } }
    return [string]$Issues[0]['category']
}

function Test-MigReconcileRetryable {
    <#
    True when re-copying could fix the item: source is readable, file/dir, not given up, attempts left.
    -Recheck: the item's exceptions are all resolved, so its 'exception' status does not block a retry.
    #>
    param($Source, [Parameter(Mandatory = $true)][object[]] $Issues, [Parameter(Mandatory = $true)] $State, [Parameter(Mandatory = $true)][string] $RelPath,
          [int] $MaxRetries, [bool] $Recheck = $false)
    if (-not (Test-MigRecordPresent $Source)) { return $false }
    if ($Source['error'] -or @('file', 'dir') -notcontains [string]$Source['kind']) { return $false }
    if (-not $Recheck -and (Get-MigCopyStateValue -State $State -RelPath $RelPath -Key 'status') -eq 'exception') { return $false }
    if ([int](Get-MigCopyStateValue -State $State -RelPath $RelPath -Key 'attempts') -ge $MaxRetries) { return $false }
    foreach ($i in $Issues) { if ($i['category'] -eq 'scan_error' -and $i['field'] -eq 'source') { return $false } }
    return $true
}

function Get-MigReconcileExceptionCategory {
    <# Exception category for a path's issues: the primary issue category, or extra_on_target for extras. #>
    param([Parameter(Mandatory = $true)][object[]] $Issues, [bool] $InSource)
    if (-not $InSource) { return 'extra_on_target' }
    return Get-MigPrimaryCategory -Issues $Issues
}

function Get-MigVerifyRunIdForReconcile {
    <# Latest REAL completed Verify run for the batch (stages.jsonl); falls back to batch info verify.run_id. #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId, $BatchInfo)
    $ev = Get-MigLatestStageEvent -Store $Store -Stage 'Verify' -Scope (Get-MigStageScope -Stage 'Verify' -BatchId $BatchId) -CompletedOnly -RealOnly
    if ($ev) { return [string]$ev['run_id'] }
    $v = Get-MigValue $BatchInfo 'verify'
    return (Get-MigValue $v 'run_id')
}

function Test-MigStatusSnapshotSupported {
    <#
    Status events can only be compacted when Get-MigFileStatus honours a snapshot's 'attempts_base' (otherwise
    compaction would lose the attempt count). Detected from the core function so compaction switches on by itself.
    #>
    $cmd = Get-Command Get-MigFileStatus -ErrorAction SilentlyContinue
    return ($null -ne $cmd -and [string]$cmd.Definition -match 'attempts_base')
}

function Invoke-MigReconcileCompaction {
    <#
    Compacts the batch's target manifest (latest record per rel_path). Status events are compacted only when
    the core supports snapshots: one snapshot event per rel_path (status, attempts_base, error) is appended
    first so the fold after compaction gives the same status, attempts and last_error.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId)
    $out = [ordered]@{}
    $t = Compress-MigStoreFile -Store $Ctx.Store -Name 'target.manifest.jsonl' -BatchId $BatchId -Key 'rel_path'
    $out['target_manifest'] = [ordered]@{ before = $t.before; after = $t.after; archive = $t.archive }
    if (Test-MigStatusSnapshotSupported) {
        $cur = Get-MigFileStatus -Store $Ctx.Store -BatchId $BatchId
        $snap = New-Object System.Collections.Generic.List[object]
        foreach ($k in $cur.Keys) {
            $v = $cur[$k]
            if (-not $v.status) { continue }
            $e = [ordered]@{ rel_path = $k; status = $v.status; attempts_base = [int]$v.attempts; snapshot = $true }
            if ($v.last_error) { $e['error'] = $v.last_error }
            $snap.Add($e)
        }
        if ($snap.Count -gt 0) { Add-MigFileStatus -Store $Ctx.Store -BatchId $BatchId -Events $snap.ToArray() -RunId $Ctx.RunId }
        $s = Compress-MigStoreFile -Store $Ctx.Store -Name 'status.events.jsonl' -BatchId $BatchId -Key 'rel_path'
        $out['status_events'] = [ordered]@{ before = $s.before; after = $s.after; archive = $s.archive }
    } else {
        $out['status_events'] = 'skipped: Get-MigFileStatus does not honour attempts_base yet'
    }
    return $out
}

function Invoke-MigStageReconcile {
    <# Reconciles one batch. Returns the reconcile summary (includes 'passed'). #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId)
    $cfg = $Ctx.Config
    $store = $Ctx.Store
    $maxRetries = [int](Get-MigConfigSetting -Config $cfg -Path 'copy.maxRetries')
    $autoRetry = [bool](Get-MigConfigSetting -Config $cfg -Path 'reconcile.autoRetry')
    $compact = [bool](Get-MigConfigSetting -Config $cfg -Path 'reconcile.compactStore')
    $options = Get-MigConfigSetting -Config $cfg -Path 'compare'
    $providers = Get-MigCompareProviderSet -Config $cfg

    $src = Read-MigManifest -Store $store -BatchId $BatchId -Side source
    if ($src.Count -eq 0) { throw "Batch '$BatchId' has no source manifest records. Run Inventory and Batching first." }
    $tgt = Read-MigManifest -Store $store -BatchId $BatchId -Side target
    $state = Get-MigCopyState -Store $store -BatchId $BatchId
    $exIndex = Get-MigExceptionIndex -Store $store -BatchId $BatchId
    $batchInfo = $null
    $allBatches = Get-MigBatches -Store $store
    if ($allBatches.ContainsKey($BatchId)) { $batchInfo = $allBatches[$BatchId] }
    $verifyRunId = Get-MigVerifyRunIdForReconcile -Store $store -BatchId $BatchId -BatchInfo $batchInfo
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'reconcile.started' -Data ([ordered]@{
        batch = $BatchId; source_entries = $src.Count; target_entries = $tgt.Count; auto_retry = $autoRetry; dry_run = [bool]$Ctx.DryRun; verify_run_id = $verifyRunId })

    $issues = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $src.Keys) { [void]$keys.Add($k) }
    foreach ($k in $tgt.Keys) { [void]$keys.Add($k) }
    foreach ($k in $keys) {
        $s = $null; $t = $null
        if ($src.ContainsKey($k)) { $s = $src[$k] }
        if ($tgt.ContainsKey($k)) { $t = $tgt[$k] }
        $found = Get-MigReconcileIssues -Ctx $Ctx -RelPath $k -Source $s -Target $t -Providers $providers -Options $options
        if ($found.Count -gt 0) { $issues[$k] = $found }
    }
    $initialIssues = $issues.Count
    $rechecked = 0
    foreach ($k in $src.Keys) {
        if ((Get-MigCopyStateValue -State $state -RelPath $k -Key 'status') -eq 'exception' -and (Test-MigExceptionRecheck -Index $exIndex -RelPath $k)) { $rechecked++ }
    }

    # ---- Auto-retry (FR-06): re-copy fixable items, rescan them on target, compare again. -------------
    $retried = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $rounds = 0
    if ($autoRetry -and -not $Ctx.DryRun) {
        for ($round = 1; $round -le ($maxRetries + 1); $round++) {
            $cand = @(foreach ($k in @($issues.Keys)) {
                $s = $null; if ($src.ContainsKey($k)) { $s = $src[$k] }
                if ($null -eq $s) { continue }
                # An accepted item stays as it is: re-copying would overwrite what a person signed off.
                if (Test-MigExceptionAccepted -Index $exIndex -BatchId $BatchId -RelPath $k -Category (Get-MigReconcileExceptionCategory -Issues $issues[$k] -InSource $true)) { continue }
                $re = Test-MigExceptionRecheck -Index $exIndex -RelPath $k
                if (Test-MigReconcileRetryable -Source $s -Issues $issues[$k] -State $state -RelPath $k -MaxRetries $maxRetries -Recheck $re) { $k }
            })
            if ($cand.Count -eq 0) { break }
            $rounds++
            $files = [string[]]@($cand | Where-Object { $src[$_]['kind'] -eq 'file' } | Sort-Object)
            $dirs = [string[]]@($cand | Where-Object { $src[$_]['kind'] -eq 'dir' } | Sort-Object { Get-MigRelPathDepth $_ } -Descending)
            foreach ($c in $cand) { [void]$retried.Add($c) }
            Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'reconcile.retry' -Data ([ordered]@{
                batch = $BatchId; round = $round; files = $files.Count; dirs = $dirs.Count; sample = @($cand | Select-Object -First 20) })
            $plan = @{ RelPaths = $files; Directories = $dirs; DryRun = $false; Force = $true }
            $r = Invoke-MigCopyProvider -Ctx $Ctx -BatchId $BatchId -Plan $plan
            [void](Save-MigCopyOutcome -Ctx $Ctx -BatchId $BatchId -Result $r -State $state -Directories $dirs)
            Update-MigTargetScan -Ctx $Ctx -BatchId $BatchId -RelPaths ([string[]]$cand) -Target $tgt
            foreach ($k in $cand) {
                $t = $null; if ($tgt.ContainsKey($k)) { $t = $tgt[$k] }
                $found = Get-MigReconcileIssues -Ctx $Ctx -RelPath $k -Source $src[$k] -Target $t -Providers $providers -Options $options
                if ($found.Count -gt 0) { $issues[$k] = $found } else { [void]$issues.Remove($k) }
            }
        }
    }

    # ---- Totals per side (C-04) and per-category counts. --------------------------------------------
    $tot = [ordered]@{ source_files = 0; target_files = 0; source_bytes = [int64]0; target_bytes = [int64]0; source_dirs = 0; target_dirs = 0 }
    foreach ($r in $src.Values) {
        if ($r['kind'] -eq 'file') { $tot.source_files++; if ($null -ne $r['size_bytes']) { $tot.source_bytes += [int64]$r['size_bytes'] } }
        elseif ($r['kind'] -eq 'dir') { $tot.source_dirs++ }
    }
    foreach ($r in $tgt.Values) {
        if ($r['kind'] -eq 'file') { $tot.target_files++; if ($null -ne $r['size_bytes']) { $tot.target_bytes += [int64]$r['size_bytes'] } }
        elseif ($r['kind'] -eq 'dir') { $tot.target_dirs++ }
    }
    $counts = @{ missing = 0; extra = 0; size_mismatch = 0; hash_mismatch = 0; metadata_mismatch = 0; scan_error = 0 }
    $allIssues = New-Object System.Collections.Generic.List[object]
    $acceptedIssues = 0
    $uncoveredIssues = 0
    foreach ($k in ($issues.Keys | Sort-Object)) {
        $list = $issues[$k]
        $excCat = Get-MigReconcileExceptionCategory -Issues $list -InSource ($src.ContainsKey($k))
        $isAccepted = Test-MigExceptionAccepted -Index $exIndex -BatchId $BatchId -RelPath $k -Category $excCat
        $seen = @{}
        foreach ($i in $list) {
            $i['accepted'] = $isAccepted
            $allIssues.Add($i)
            if ($isAccepted) { $acceptedIssues++ } else { $uncoveredIssues++ }
            $c = [string]$i['category']
            if (-not $seen.ContainsKey($c)) { $seen[$c] = $true; if ($counts.ContainsKey($c)) { $counts[$c]++ } }
        }
    }

    # ---- Status, exceptions, results (skipped in dry run). ------------------------------------------
    $opened = @()
    $verifiedNow = 0
    $resultsName = 'reconcile.results.{0}.jsonl' -f $Ctx.RunId
    if (-not $Ctx.DryRun) {
        $events = New-Object System.Collections.Generic.List[object]
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($k in $src.Keys) {
            $st = Get-MigCopyStateValue -State $state -RelPath $k -Key 'status'
            if (-not $issues.ContainsKey($k)) {
                # Includes re-checked items whose exceptions were resolved: they now match.
                if ($st -ne 'verified') { $events.Add([ordered]@{ rel_path = $k; status = 'verified' }); $verifiedNow++ }
                continue
            }
            $list = $issues[$k]
            $cat = Get-MigPrimaryCategory -Issues $list
            $detail = (@($list | ForEach-Object { $_['detail'] }) -join '; ')
            $sourceScanError = ($cat -eq 'scan_error' -and @($list | Where-Object { $_['field'] -eq 'source' }).Count -gt 0)
            if ($autoRetry -or $sourceScanError -or $st -eq 'exception') {
                # Retries exhausted (or not possible): register the item for an owner to resolve (C-06).
                # A resolved exception with the same category is re-opened as a new one by Add-MigStageExceptions.
                if ($st -ne 'exception') { $events.Add([ordered]@{ rel_path = $k; status = 'exception'; error = $detail }) }
                $attempts = Get-MigCopyStateValue -State $state -RelPath $k -Key 'attempts'
                $items.Add(@{ rel_path = $k; category = $cat; detail = ("{0} (copy attempts: {1})" -f $detail, $attempts) })
            } elseif ($st -ne 'mismatch') {
                # autoRetry off: mark for the next Copy run (mismatch -> Copy loop in the pipeline).
                $events.Add([ordered]@{ rel_path = $k; status = 'mismatch'; error = $detail })
            }
        }
        foreach ($k in $issues.Keys) {
            if ($src.ContainsKey($k)) { continue }
            $detail = (@($issues[$k] | ForEach-Object { $_['detail'] }) -join '; ') + '. Not deleted: extras are never removed by the tool.'
            $items.Add(@{ rel_path = $k; category = 'extra_on_target'; detail = $detail })
        }
        if ($events.Count -gt 0) { Add-MigFileStatus -Store $store -BatchId $BatchId -Events $events.ToArray() -RunId $Ctx.RunId }
        $opened = Add-MigStageExceptions -Ctx $Ctx -BatchId $BatchId -Items $items.ToArray() -Index $exIndex
        Write-MigExceptionAudit -Ctx $Ctx -Event 'reconcile.exceptions_opened' -BatchId $BatchId -Records $opened
        # Per-run results file (always created, empty when there is no issue, so the evidence exists).
        $resultsPath = Get-MigStorePath -Store $store -Name $resultsName -BatchId $BatchId
        if ($allIssues.Count -gt 0) { Add-MigStoreRecords -Store $store -Name $resultsName -BatchId $BatchId -Records $allIssues.ToArray() }
        elseif (-not (Test-Path -LiteralPath $resultsPath)) { [System.IO.File]::WriteAllText($resultsPath, '') }
    }
    $openCount = $exIndex.Open
    $passed = ($uncoveredIssues -eq 0 -and $openCount -eq 0)

    $rec = [ordered]@{
        passed = $passed; run_id = $Ctx.RunId; verify_run_id = $verifyRunId; stale = $false; results_file = $resultsName
        source_files = $tot.source_files; target_files = $tot.target_files
        source_bytes = $tot.source_bytes; target_bytes = $tot.target_bytes
        source_dirs = $tot.source_dirs; target_dirs = $tot.target_dirs
        missing = $counts.missing; extra = $counts.extra; size_mismatch = $counts.size_mismatch
        hash_mismatch = $counts.hash_mismatch; metadata_mismatch = $counts.metadata_mismatch; scan_errors = $counts.scan_error
        retried = $retried.Count; exceptions_opened = $opened.Count
        exceptions_reopened = @($opened | Where-Object { $_.Contains('reopens') }).Count
        accepted_issues = $acceptedIssues; open_exceptions = $openCount; rechecked_resolved = $rechecked
    }
    $compaction = $null
    if (-not $Ctx.DryRun) {
        $newState = 'mismatch'
        if ($passed) { $newState = 'reconciled' }
        Set-MigBatchInfo -Store $store -BatchId $BatchId -Data @{ reconcile = $rec; state = $newState }
        if ($compact) { $compaction = Invoke-MigReconcileCompaction -Ctx $Ctx -BatchId $BatchId }
    }
    $summary = [ordered]@{ batch = $BatchId; dry_run = [bool]$Ctx.DryRun }
    foreach ($k in $rec.Keys) { $summary[$k] = $rec[$k] }
    if ($Ctx.DryRun) { $summary['results_file'] = $null }
    $summary['issues'] = $allIssues.Count
    $summary['initial_issue_paths'] = $initialIssues
    $summary['retry_rounds'] = $rounds
    $summary['newly_verified'] = $verifiedNow
    $summary['files'] = $tot.target_files
    $summary['bytes'] = $tot.target_bytes
    if ($null -ne $compaction) { $summary['compaction'] = $compaction }
    $lvl = 'info'
    if (-not $passed) { $lvl = 'warn' }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Level $lvl -Event 'reconcile.finished' -Data $summary
    return $summary
}
