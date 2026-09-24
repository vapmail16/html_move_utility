# Delta stage (FR-08): after the source is frozen, find what was added or changed since the manifest.
#   Pass 1 (walk, streamed in chunks like Inventory): each source entry is compared with its batch's
#     manifest record on delta.detectBy (size, modified, created, attributes, hash).
#       - 'hash' in detectBy  -> every file is re-hashed and compared (slow, strongest).
#       - otherwise           -> cheap parallel stat; only new/changed entries are scanned.
#     New AND changed entries are always fully re-scanned (re-hashed): a carried-forward hash could let a changed
#     file verify against its old content. New/changed records are appended to the source manifest and files
#     get a 'pending' status event.
#   Pass 2 (per batch, streamed): manifest entries no longer present on the source are NOT tombstoned
#     (the source is supposed to be frozen); each one opens a 'source_deleted' exception.
#   Then, for every batch Delta wrote to: the plan totals are refreshed (as Batching does) and the C-01
#   manifest checksum is re-recorded. Batches with new/changed entries (the affected batches) get
#   state 'delta_pending' and reconcile.stale = $true (a batch that did not exist before: 'inventoried'),
#   so Copy -> Verify -> Reconcile run again for them.
# Exceptions are opened in bulk (one write per batch) and the stage writes ONE summary audit event
# (counts + the first 50 paths per category), not one per file.
# Under -DryRun nothing is written to the store (no manifest, status, batch info, checksums or exceptions):
# the summary only reports what a real Delta would do.

# Runs inside a runspace: self-contained. $Item = array of @{ rel_path; kind; full }. Outputs rel_paths that are gone.
$script:MigDeltaExistsWorker = {
    param($Item, $A)
    foreach ($e in $Item) {
        $exists = $false
        try {
            if ($e.kind -eq 'dir') { $exists = [System.IO.Directory]::Exists($e.full) } else { $exists = [System.IO.File]::Exists($e.full) }
        } catch { $exists = $false }
        if (-not $exists) { $e.rel_path }
    }
}

function Invoke-MigStageDelta {
    param([Parameter(Mandatory = $true)] $Ctx)
    $cfg = $Ctx.Config
    $detectBy = @('size', 'modified')
    $raw = Get-MigValue $cfg.delta 'detectBy' $null
    if ($null -ne $raw) { $detectBy = @(@($raw) | Where-Object { $_ }) }
    $state = [pscustomobject]@{
        Ctx        = $Ctx
        Resolver   = Get-MigInvBatchResolver -Ctx $Ctx
        Cache      = New-MigInvManifestCache -Ctx $Ctx
        DetectBy   = [string[]]$detectBy
        FullHash   = ($detectBy -contains 'hash')
        Known      = Get-MigInvKnownBatchIds -Store $Ctx.Store
        Affected   = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Written    = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        PerBatch   = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        Exceptions = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        Samples    = @{ new = (New-Object System.Collections.Generic.List[object]); changed = (New-Object System.Collections.Generic.List[object])
                        errors = (New-Object System.Collections.Generic.List[object]); source_deleted = (New-Object System.Collections.Generic.List[object]) }
        Started    = [DateTime]::UtcNow
        Seen       = 0
        Summary    = [ordered]@{ files = 0; dirs = 0; bytes = [long]0; errors = 0; new = 0; changed = 0; unchanged = 0
                                 missing_on_source = 0; bytes_new_or_changed = [long]0; exceptions_opened = 0 }
    }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'delta.started' -Data ([ordered]@{
        source_root = $cfg.paths.sourceRoot; detect_by = $state.DetectBy; dry_run = $Ctx.DryRun
    })

    # Pass 1: walk.
    $bufferSize = Get-MigInvBufferSize -Ctx $Ctx
    $buffer = New-Object System.Collections.Generic.List[object]
    Get-MigInvWalk -Ctx $Ctx | ForEach-Object {
        $buffer.Add($_)
        if ($buffer.Count -ge $bufferSize) { Invoke-MigDeltaChunk -State $state -Entries $buffer.ToArray(); $buffer.Clear() }
    }
    if ($buffer.Count -gt 0) { Invoke-MigDeltaChunk -State $state -Entries $buffer.ToArray(); $buffer.Clear() }

    # Pass 2: manifest entries that are gone from the source.
    $missing = Find-MigDeltaMissing -State $state
    $s = $state.Summary
    $s.missing_on_source = $missing

    $checksums = @()
    if (-not $Ctx.DryRun) {
        $s.exceptions_opened = Save-MigInvExceptions -State $state
        # Batch info for every batch written: fresh plan totals; affected batches go back into the copy loop.
        $info = Get-MigBatches -Store $Ctx.Store
        foreach ($bid in $state.Written) {
            $extra = [ordered]@{ plan = (Get-MigBatchPlanTotals -Store $Ctx.Store -BatchId $bid) }
            if ($state.Affected.Contains($bid)) {
                $pb = $state.PerBatch[$bid]
                $extra['delta'] = [ordered]@{ run_id = $Ctx.RunId; new = $pb.new; changed = $pb.changed; ts_utc = Get-MigUtcNow }
                [void](Set-MigInvBatchChanged -Ctx $Ctx -BatchId $bid -Known $state.Known -Info $info -Extra $extra)
            } else {
                Set-MigBatchInfo -Store $Ctx.Store -BatchId $bid -Data $extra
            }
        }
        $checksums = Write-MigManifestChecksums -Ctx $Ctx -BatchIds ([string[]]@($state.Written)) -EventPrefix 'delta'
    }
    Write-Progress -Activity 'Delta' -Completed

    # Totals of the whole source manifest after this Delta (every batch, latest record per path, files without
    # errors), so the final report can cross-check its totals. Under -DryRun: the manifest as stored.
    $s['source_files'] = 0
    $s['source_bytes'] = [long]0
    foreach ($bid in (Get-MigBatchIds -Store $Ctx.Store)) {
        if (-not (Test-MigInvBatchHasManifest -Store $Ctx.Store -BatchId $bid)) { continue }
        $t = Get-MigBatchManifestTotals -Store $Ctx.Store -BatchId $bid
        $s['source_files'] += $t.ok_file_count
        $s['source_bytes'] += $t.ok_bytes
    }

    # Exact: ordinal-sorted ids of the batches with new or changed entries.
    $affectedIds = [string[]]@($state.Affected)
    [Array]::Sort($affectedIds, [StringComparer]::Ordinal)
    $s['affected_batches'] = $affectedIds
    $s['manifest_checksums'] = @($checksums).Count
    $s['detect_by'] = $state.DetectBy
    $s['dry_run'] = $Ctx.DryRun
    # Truthful result: unreadable entries, or files deleted from a source that should be frozen, need a decision.
    $s['passed'] = ($s.errors -eq 0 -and $s.missing_on_source -eq 0)
    $audit = [ordered]@{}
    foreach ($k in $s.Keys) { $audit[$k] = $s[$k] }
    foreach ($k in $state.Samples.Keys) { $audit['first_' + $k] = $state.Samples[$k].ToArray() }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'delta.completed' -Data $audit
    return $s
}

function Add-MigDeltaBatchCount {
    param([Parameter(Mandatory = $true)] $State, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)][string] $What)
    if (-not $State.PerBatch.ContainsKey($BatchId)) { $State.PerBatch[$BatchId] = @{ new = 0; changed = 0 } }
    $State.PerBatch[$BatchId][$What]++
    [void]$State.Affected.Add($BatchId)
}

function Invoke-MigDeltaChunk {
    param([Parameter(Mandatory = $true)] $State, [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries)
    $ctx = $State.Ctx
    $s = $State.Summary
    $State.Seen += $Entries.Count
    $toScan = New-Object System.Collections.Generic.List[object]
    $work = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Entries) { if ($e.kind -eq 'error') { $toScan.Add($e) } else { $work.Add($e) } }
    $classOf = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)

    if ($State.FullHash) {
        foreach ($w in $work) { $toScan.Add($w) }
    } elseif ($work.Count -gt 0) {
        $stats = Get-MigInvStatRecords -Ctx $ctx -Entries $work.ToArray()
        for ($i = 0; $i -lt $work.Count; $i++) {
            $st = $stats[$i]
            $rel = [string]$st['rel_path']
            if ($st['error']) { $toScan.Add($work[$i]); continue }
            $bid = Resolve-MigInvBatchId -Resolver $State.Resolver -RelPath $rel -Record $st
            $idx = Get-MigInvManifestIndex -Cache $State.Cache -BatchId $bid
            $ex = $null
            if (-not $idx.TryGetValue($rel, [ref]$ex)) { $classOf[$rel] = 'new'; $toScan.Add($work[$i]); continue }
            $diff = @(Get-MigInvChangedFields -Existing $ex -Current $st -Fields $State.DetectBy)
            if ($diff.Count -eq 0) {
                $s.unchanged++
                if ($st['kind'] -eq 'file') { $s.files++; $s.bytes += [long]$st['size_bytes'] } else { $s.dirs++ }
                continue
            }
            # Changed: always re-scanned (fresh hash + ACL hash), never carried forward.
            $classOf[$rel] = 'changed'
            $toScan.Add($work[$i])
        }
    }

    $records = @()
    if ($toScan.Count -gt 0) { $records = Get-MigScanRecords -Ctx $ctx -Side source -Entries $toScan.ToArray() }

    $byBatch = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $pendingByBatch = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $records) {
        $rel = [string]$r['rel_path']
        $bid = Resolve-MigInvBatchId -Resolver $State.Resolver -RelPath $rel -Record $r
        $r['batch_id'] = $bid
        if ($r['kind'] -eq 'file') { $s.files++; if ($null -ne $r['size_bytes']) { $s.bytes += [long]$r['size_bytes'] } }
        elseif ($r['kind'] -eq 'dir') { $s.dirs++ }

        if ($r['error'] -or $r['kind'] -eq 'error') {
            $s.errors++
            Add-MigInvExceptionItem -State $State -BatchId $bid -RelPath $rel -Category 'scan_error' -Detail ([string]$r['error'])
            Add-MigInvSample -List $State.Samples.errors -Item ([ordered]@{ batch_id = $bid; rel_path = $rel; kind = $r['kind']; error = $r['error'] })
            # A case-only duplicate would overwrite the first entry's record in the case-insensitive manifest.
            if (Test-MigInvCaseDuplicate $r) { continue }
            $idx = Get-MigInvManifestIndex -Cache $State.Cache -BatchId $bid
            $ex = $null
            if (-not $idx.TryGetValue($rel, [ref]$ex) -or -not $ex[6]) { Add-MigDeltaBatchCount -State $State -BatchId $bid -What 'changed' }
        } else {
            # Classify (full-hash mode, or entries not classified by the stat pass).
            $class = $null
            if (-not $classOf.TryGetValue($rel, [ref]$class)) {
                $idx = Get-MigInvManifestIndex -Cache $State.Cache -BatchId $bid
                $ex = $null
                if (-not $idx.TryGetValue($rel, [ref]$ex)) { $class = 'new' }
                elseif (@(Get-MigInvChangedFields -Existing $ex -Current $r -Fields $State.DetectBy).Count -gt 0) { $class = 'changed' }
                else { $class = 'unchanged' }
            }
            if ($class -eq 'unchanged') { $s.unchanged++; continue }
            $s[$class]++
            if ($r['kind'] -eq 'file' -and $null -ne $r['size_bytes']) { $s.bytes_new_or_changed += [long]$r['size_bytes'] }
            Add-MigDeltaBatchCount -State $State -BatchId $bid -What $class
            Add-MigInvSample -List $State.Samples[$class] -Item ([ordered]@{ batch_id = $bid; rel_path = $rel; kind = $r['kind']; size_bytes = $r['size_bytes'] })
        }
        if (-not $byBatch.ContainsKey($bid)) { $byBatch[$bid] = New-Object System.Collections.Generic.List[object]; $pendingByBatch[$bid] = New-Object System.Collections.Generic.List[object] }
        $byBatch[$bid].Add($r)
        if ($r['kind'] -eq 'file' -and -not $r['error']) { $pendingByBatch[$bid].Add(@{ rel_path = $rel; status = 'pending' }) }
    }

    if (-not $ctx.DryRun) {
        foreach ($bid in $byBatch.Keys) {
            $pending = $pendingByBatch[$bid]
            if ($pending.Count -gt 0) { Add-MigFileStatus -Store $ctx.Store -BatchId $bid -Events $pending.ToArray() -RunId $ctx.RunId }
            $recs = $byBatch[$bid].ToArray()
            Write-MigManifest -Store $ctx.Store -BatchId $bid -Side source -Records $recs
            Update-MigInvManifestIndex -Cache $State.Cache -BatchId $bid -Records $recs
            [void]$State.Written.Add($bid)
        }
    }
    Write-MigProgress -Activity 'Delta' -Status ('new {0}, changed {1}, errors {2}' -f $s.new, $s.changed, $s.errors) -Done $State.Seen -Total 0 -Started $State.Started
}

function Get-MigDeltaManifestKinds {
    <# Streams a batch's source manifest into rel_path -> kind ('file' | 'dir' only; latest record wins, tombstones removed). #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId)
    $kinds = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $path = Join-Path (Join-Path (Join-Path $Store.Root 'batches') $BatchId) 'source.manifest.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return , $kinds }
    Invoke-MigStoreLineBlocks -Path $path -Action {
        param($block)
        foreach ($r in $block) {
            $rel = $r['rel_path']
            if ($null -eq $rel) { continue }
            $k = [string]$r['kind']
            # Walk-error records are not entries; a later error record for a path hides its earlier entry.
            if ($r['deleted'] -eq $true -or ($k -ne 'file' -and $k -ne 'dir')) { [void]$kinds.Remove([string]$rel); continue }
            if ($k -eq 'file') { $kinds[[string]$rel] = 'file' } else { $kinds[[string]$rel] = 'dir' }
        }
    }
    return , $kinds
}

function Find-MigDeltaMissing {
    <# Pass 2: one batch at a time, checks every manifest entry still exists on the source. Returns the count. #>
    param([Parameter(Mandatory = $true)] $State)
    $ctx = $State.Ctx
    $cfg = $ctx.Config
    $root = [string]$cfg.paths.sourceRoot
    $useLong = [bool]$cfg.paths.useLongPathPrefix
    $threads = Get-MigEffectiveThreads -Ctx $ctx -Default ([int]$cfg.inventory.threads)
    $chunkSize = [Math]::Max(1, [int]$cfg.inventory.chunkSize)
    $total = 0
    foreach ($bid in (Get-MigBatchIds -Store $ctx.Store)) {
        if (-not (Test-MigInvBatchHasManifest -Store $ctx.Store -BatchId $bid)) { continue }
        $kinds = Get-MigDeltaManifestKinds -Store $ctx.Store -BatchId $bid
        $chunks = New-Object System.Collections.Generic.List[object]
        $cur = New-Object System.Collections.Generic.List[object]
        foreach ($kv in $kinds.GetEnumerator()) {
            $cur.Add(@{ rel_path = $kv.Key; kind = $kv.Value; full = (Get-MigLongPath -Path (Join-MigPath -Root $root -RelPath $kv.Key) -Enabled $useLong) })
            if ($cur.Count -ge $chunkSize) { $chunks.Add($cur.ToArray()); $cur.Clear() }
        }
        if ($cur.Count -gt 0) { $chunks.Add($cur.ToArray()) }
        $kinds = $null
        if ($chunks.Count -eq 0) { continue }
        $gone = @(Invoke-MigParallel -Items $chunks.ToArray() -ScriptBlock $script:MigDeltaExistsWorker -Threads $threads)
        foreach ($rel in $gone) {
            $total++
            Add-MigInvSample -List $State.Samples.source_deleted -Item ([ordered]@{ batch_id = $bid; rel_path = $rel })
            if (-not $ctx.DryRun) {
                Add-MigInvExceptionItem -State $State -BatchId $bid -RelPath $rel -Category 'source_deleted' `
                    -Detail 'In the source manifest but no longer on the source (source should be frozen). Not tombstoned.'
            }
        }
    }
    return $total
}
