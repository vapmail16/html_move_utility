# Stage 3: Verify (FR-04). Scans the TARGET side of one batch into target.manifest.jsonl.
# Covers every rel_path of the batch's source manifest, plus extras: entries found in the target directories
# of this batch that are not in the source manifest but that the batch provider (batching.strategy) maps to
# this batch. Extra directories are descended into. Nothing on the target is modified (read-only scan).
# Entries that disappeared since a previous scan are tombstoned (deleted = $true) so re-verification is exact.
# Candidate extras are stat'ed (timestamps, size, attributes; no hashing) before the batch provider is asked,
# so date-based strategies (yearMonth, year) place them correctly.
# Also holds Find-MigTargetOrphans: a sweep of the whole target root for entries that belong to no known batch.

function Get-MigBatchMembershipTester {
    <# Returns @{ Provider; Options } used by Test-MigEntryInBatch; Provider is $null if the strategy is not registered. #>
    param([Parameter(Mandatory = $true)] $Ctx)
    $name = [string](Get-MigConfigSetting -Config $Ctx.Config -Path 'batching.strategy')
    $p = $null
    if ($name) {
        try { $p = Get-MigProvider -Kind Batch -Name $name }
        catch { Write-Warning "Verify: batch provider '$name' is not available; every unlisted target entry in the batch's directories is treated as an extra." }
    }
    return @{ Provider = $p; Options = (Get-MigConfigSetting -Config $Ctx.Config -Path 'batching.options') }
}

function Add-MigEntryMetadata {
    <#
    Stats a listed entry (metadata only, never hashing): created_utc, modified_utc, attributes and size_bytes are
    added to the entry, from the FileSystemInfo the listing already holds. Batch providers read these fields.
    #>
    param([Parameter(Mandatory = $true)] $Entry)
    if ($Entry.Contains('modified_utc')) { return }
    $fsi = $Entry['fsi']
    if ($null -eq $fsi) { return }
    try {
        $Entry['created_utc'] = $fsi.CreationTimeUtc.ToString('o')
        $Entry['modified_utc'] = $fsi.LastWriteTimeUtc.ToString('o')
        $Entry['attributes'] = $fsi.Attributes.ToString()
        if ($Entry['kind'] -eq 'file') { $Entry['size_bytes'] = $fsi.Length }
    } catch {
        $Entry['modified_utc'] = $null
        $Entry['stat_error'] = $_.Exception.Message
    }
}

function Get-MigEntryBatchId {
    <# Batch id of a listed target entry (stat'ed first), or $null when no provider is configured. Throws on provider errors. #>
    param([Parameter(Mandatory = $true)] $Tester, [Parameter(Mandatory = $true)] $Entry)
    if ($null -eq $Tester.Provider) { return $null }
    Add-MigEntryMetadata -Entry $Entry
    return [string](& $Tester.Provider $Entry['rel_path'] $Entry $Tester.Options)
}

function Test-MigEntryInBatch {
    param([Parameter(Mandatory = $true)] $Tester, [Parameter(Mandatory = $true)] $Entry, [Parameter(Mandatory = $true)][string] $BatchId)
    if ($null -eq $Tester.Provider) { return $true }
    try {
        $id = Get-MigEntryBatchId -Tester $Tester -Entry $Entry
        return ($id -eq $BatchId)
    } catch {
        Write-Warning "Verify: batch provider failed for '$($Entry.rel_path)': $($_.Exception.Message). Treating it as part of '$BatchId'."
        return $true
    }
}

function Get-MigTargetChildEntries {
    <#
    One-level listing of a target directory. Returns @{ exists; error; entries = [@{ rel_path; kind; full; reparse; fsi }] }.
    'fsi' is the FileSystemInfo of the listing (used by Add-MigEntryMetadata; never written to the store).
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RelDir, [object[]] $Excludes = @())
    $cfg = $Ctx.Config
    $useLong = [bool](Get-MigConfigSetting -Config $cfg -Path 'paths.useLongPathPrefix')
    $full = Get-MigLongPath -Path (Join-MigPath -Root $cfg.paths.targetRoot -RelPath $RelDir) -Enabled $useLong
    $res = @{ exists = $false; error = $null; entries = @() }
    try {
        $di = New-Object System.IO.DirectoryInfo($full)
        if (-not $di.Exists) { return $res }
        $res.exists = $true
        $children = @($di.EnumerateFileSystemInfos())
    } catch {
        $res.error = $_.Exception.Message
        return $res
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($c in $children) {
        if ($RelDir) { $rel = $RelDir + '\' + $c.Name } else { $rel = $c.Name }
        $skip = $false
        foreach ($rx in $Excludes) { if ($rx.IsMatch($rel)) { $skip = $true; break } }
        if ($skip) { continue }
        $isDir = ($c.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0
        $kind = 'file'
        if ($isDir) { $kind = 'dir' }
        $list.Add(@{ rel_path = $rel; kind = $kind; full = $c.FullName; reparse = (($c.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0); fsi = $c })
    }
    $res.entries = $list.ToArray()
    return $res
}

function Get-MigExcludeRegexes {
    param([Parameter(Mandatory = $true)] $Ctx)
    return @(@(Get-MigConfigSetting -Config $Ctx.Config -Path 'inventory.excludePatterns') | Where-Object { $_ } | ForEach-Object { New-Object regex($_, 'IgnoreCase') })
}

function New-MigTargetTombstone {
    param([Parameter(Mandatory = $true)][string] $RelPath, [string] $Kind, [Parameter(Mandatory = $true)][string] $BatchId)
    return [ordered]@{ rel_path = $RelPath; kind = $Kind; batch_id = $BatchId; side = 'target'; scanned_utc = Get-MigUtcNow; error = $null; deleted = $true }
}

function Update-MigTargetScan {
    <#
    Rescans specific rel_paths on the target (used by Reconcile after a retry). Writes target manifest records
    (tombstones for paths that no longer exist) and updates $Target (Dictionary from Read-MigManifest) in place.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId,
          [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $RelPaths, [Parameter(Mandatory = $true)] $Target)
    $cfg = $Ctx.Config
    $useLong = [bool](Get-MigConfigSetting -Config $cfg -Path 'paths.useLongPathPrefix')
    $entries = New-Object System.Collections.Generic.List[object]
    $tomb = New-Object System.Collections.Generic.List[object]
    foreach ($rel in $RelPaths) {
        $full = Get-MigLongPath -Path (Join-MigPath -Root $cfg.paths.targetRoot -RelPath $rel) -Enabled $useLong
        if ([System.IO.File]::Exists($full)) { $entries.Add(@{ rel_path = $rel; kind = 'file'; full = $full }) }
        elseif ([System.IO.Directory]::Exists($full)) { $entries.Add(@{ rel_path = $rel; kind = 'dir'; full = $full }) }
        elseif ($Target.ContainsKey($rel)) { $tomb.Add((New-MigTargetTombstone -RelPath $rel -Kind $Target[$rel]['kind'] -BatchId $BatchId)) }
    }
    $recs = @()
    if ($entries.Count -gt 0) { $recs = @(Get-MigScanRecords -Ctx $Ctx -Side target -Entries $entries.ToArray()) }
    foreach ($r in $recs) { $r['batch_id'] = $BatchId }
    $all = @($recs) + @($tomb.ToArray())
    if ($all.Count -gt 0) { Write-MigManifest -Store $Ctx.Store -BatchId $BatchId -Side target -Records $all }
    foreach ($r in $recs) { $Target[[string]$r['rel_path']] = $r }
    foreach ($t in $tomb) { [void]$Target.Remove([string]$t['rel_path']) }
}

function Invoke-MigStageVerify {
    <# Scans the target side of one batch (hash + metadata) into the target manifest. Returns a summary. #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId)
    $cfg = $Ctx.Config
    $store = $Ctx.Store
    $src = Read-MigManifest -Store $store -BatchId $BatchId -Side source
    if ($src.Count -eq 0) { throw "Batch '$BatchId' has no source manifest records. Run Inventory and Batching first." }
    $prev = Read-MigManifest -Store $store -BatchId $BatchId -Side target
    $excludes = Get-MigExcludeRegexes -Ctx $Ctx
    $tester = Get-MigBatchMembershipTester -Ctx $Ctx
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'verify.started' -Data ([ordered]@{ batch = $BatchId; source_entries = $src.Count; dry_run = [bool]$Ctx.DryRun })

    # Directories to list on the target: every source directory of the batch and the parent of every entry.
    $dirSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rec in $src.Values) {
        $k = [string]$rec['kind']
        if ($k -ne 'file' -and $k -ne 'dir') { continue }
        $rel = [string]$rec['rel_path']
        if ($k -eq 'dir') { [void]$dirSet.Add($rel) }
        [void]$dirSet.Add((Get-MigParentRelPath $rel))
    }
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($d in (@($dirSet) | Sort-Object)) { $queue.Enqueue($d) }
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $dirSet) { [void]$visited.Add($d) }

    $found = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $dirErrors = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $extras = New-Object System.Collections.Generic.List[string]
    while ($queue.Count -gt 0) {
        $d = $queue.Dequeue()
        $res = Get-MigTargetChildEntries -Ctx $Ctx -RelDir $d -Excludes $excludes
        if ($res.error) { $dirErrors[$d] = $res.error; continue }
        foreach ($e in $res.entries) {
            if ($src.ContainsKey($e.rel_path)) { $found[$e.rel_path] = $e; continue }
            if (-not (Test-MigEntryInBatch -Tester $tester -Entry $e -BatchId $BatchId)) { continue }
            $found[$e.rel_path] = $e
            $extras.Add($e.rel_path)
            if ($e.kind -eq 'dir' -and -not $e.reparse -and $visited.Add($e.rel_path)) { $queue.Enqueue($e.rel_path) }
        }
    }

    $entries = @($found.Values | ForEach-Object { @{ rel_path = $_.rel_path; kind = $_.kind; full = $_.full } })
    $records = @()
    if ($entries.Count -gt 0) { $records = @(Get-MigScanRecords -Ctx $Ctx -Side target -Entries $entries) }
    foreach ($r in $records) { $r['batch_id'] = $BatchId }

    $more = New-Object System.Collections.Generic.List[object]
    $missing = 0
    foreach ($rec in $src.Values) {
        $k = [string]$rec['kind']
        if ($k -ne 'file' -and $k -ne 'dir') { continue }
        $rel = [string]$rec['rel_path']
        if ($found.ContainsKey($rel)) { continue }
        $parent = Get-MigParentRelPath $rel
        if ($dirErrors.ContainsKey($parent)) {
            $more.Add([ordered]@{ rel_path = $rel; kind = 'error'; batch_id = $BatchId; side = 'target'; scanned_utc = Get-MigUtcNow
                                   error = "target directory could not be listed: $($dirErrors[$parent])" })
            continue
        }
        $missing++
        if ($prev.ContainsKey($rel)) { $more.Add((New-MigTargetTombstone -RelPath $rel -Kind $k -BatchId $BatchId)) }
    }
    foreach ($rel in @($prev.Keys)) {
        if (-not $found.ContainsKey($rel) -and -not $src.ContainsKey($rel)) { $more.Add((New-MigTargetTombstone -RelPath $rel -Kind $prev[$rel]['kind'] -BatchId $BatchId)) }
    }

    $files = 0; $dirs = 0; $bytes = [int64]0; $errors = 0
    foreach ($r in $records) {
        if ($r['error'] -or $r['kind'] -eq 'error') { $errors++; continue }
        if ($r['kind'] -eq 'file') { $files++; $bytes += [int64]$r['size_bytes'] } elseif ($r['kind'] -eq 'dir') { $dirs++ }
    }
    $errors += @($more | Where-Object { $_['kind'] -eq 'error' }).Count

    $summary = [ordered]@{
        batch = $BatchId; dry_run = [bool]$Ctx.DryRun; files = $files; dirs = $dirs; bytes = $bytes; errors = $errors
        extras = $extras.Count; missing = $missing; directory_errors = $dirErrors.Count
    }
    if (-not $Ctx.DryRun) {
        $all = @($records) + @($more.ToArray())
        if ($all.Count -gt 0) { Write-MigManifest -Store $store -BatchId $BatchId -Side target -Records $all }
        # A new target manifest invalidates the batch's previous reconcile (reconcile.stale).
        Set-MigBatchInfo -Store $store -BatchId $BatchId -Data (Add-MigStaleReconcileInfo -Store $store -BatchId $BatchId -Data @{
            state  = 'verified'
            verify = [ordered]@{ files = $files; dirs = $dirs; bytes = $bytes; errors = $errors; extras = $extras.Count; missing = $missing; run_id = $Ctx.RunId }
        })
    }
    if ($extras.Count -gt 0) {
        Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Level warn -Event 'verify.extras' -Data ([ordered]@{ batch = $BatchId; count = $extras.Count; sample = @($extras | Select-Object -First 20) })
    }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'verify.finished' -Data $summary
    return $summary
}

# ---- Orphan sweep -------------------------------------------------------------------------------------

# Strategies whose batch id depends only on the path: every entry under a directory that itself matched the
# strategy belongs to that directory's batch, so the sweep does not need to descend into it.
$script:MigPathBatchStrategies = @('regex', 'folderDepth')

function Find-MigTargetOrphans {
    <#
    Walks the target root (read-only; nothing is ever deleted). Each entry is mapped to a batch with the configured
    batch provider (stat'ed first, metadata only, so date strategies work). An entry is an orphan ONLY when its batch
    id is not a batch of the store ('ORPHANS' excluded). Entries of a known batch that are missing from its source
    manifest are that batch's extras (Verify/Reconcile report them there) and are not reported again here.
    Orphans are registered as exceptions (category extra_on_target) in batch 'ORPHANS' (not in dry run), in bulk.
    Cost: with a path-based strategy (regex, folderDepth) a directory that matched the strategy and maps to a known
    batch is not descended into; with other strategies (e.g. date-based) every entry is stat'ed.
    Returns @{ scanned; orphans = [rel_path]; errors; exceptions_opened; pruned_dirs }.
    #>
    param([Parameter(Mandatory = $true)] $Ctx)
    $cfg = $Ctx.Config
    $store = $Ctx.Store
    $orphanBatch = 'ORPHANS'
    $tester = Get-MigBatchMembershipTester -Ctx $Ctx
    $strategy = [string](Get-MigConfigSetting -Config $cfg -Path 'batching.strategy')
    if ($null -eq $tester.Provider) { throw "Find-MigTargetOrphans: batching.strategy '$strategy' is not a registered Batch provider." }
    $pathBased = $script:MigPathBatchStrategies -contains $strategy
    # Fallback ids (unmatched / parent-dir) mean "the strategy did not match": such directories are always descended.
    $fallback = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$fallback.Add((Get-MigBatchFallbackId -Record @{ kind = 'file' } -Options $tester.Options))
    [void]$fallback.Add((Get-MigBatchFallbackId -Record @{ kind = 'dir' } -Options $tester.Options))
    $excludes = Get-MigExcludeRegexes -Ctx $Ctx
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($b in (Get-MigBatchIds -Store $store)) { if ($b -ne $orphanBatch) { [void]$known.Add($b) } }

    $orphans = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $scanned = 0; $pruned = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push('')
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        $res = Get-MigTargetChildEntries -Ctx $Ctx -RelDir $d -Excludes $excludes
        if ($res.error) { $errors.Add(@{ rel_path = $d; error = $res.error }); continue }
        foreach ($e in $res.entries) {
            $scanned++
            try { $id = Get-MigEntryBatchId -Tester $tester -Entry $e }
            catch { $errors.Add(@{ rel_path = $e.rel_path; error = "batch provider failed: $($_.Exception.Message)" }); $id = $null }
            $isKnown = ($null -ne $id -and $known.Contains($id))
            if ($null -ne $id -and -not $isKnown) {
                $orphans.Add(@{ rel_path = $e.rel_path; category = 'extra_on_target'
                                detail = ("{0} on target maps to batch '{1}', which is not a batch of the store. Not deleted: extras are never removed by the tool." -f $e.kind, $id) })
            }
            if ($e.kind -ne 'dir' -or $e.reparse) { continue }
            if ($pathBased -and $isKnown -and -not $fallback.Contains($id)) { $pruned++; continue }
            $stack.Push($e.rel_path)
        }
    }

    $opened = @()
    if (-not $Ctx.DryRun -and $orphans.Count -gt 0) {
        $opened = Add-MigStageExceptions -Ctx $Ctx -BatchId $orphanBatch -Items $orphans.ToArray()
        Write-MigExceptionAudit -Ctx $Ctx -Event 'verify.orphans_exceptions_opened' -BatchId $orphanBatch -Records $opened
    }
    $paths = [string[]]@($orphans | ForEach-Object { [string]$_['rel_path'] })
    $lvl = 'info'
    if ($orphans.Count -gt 0 -or $errors.Count -gt 0) { $lvl = 'warn' }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Level $lvl -Event 'verify.orphans' -Data ([ordered]@{
        known_batches = $known.Count; scanned = $scanned; pruned_dirs = $pruned; orphans = $orphans.Count; errors = $errors.Count
        exceptions_opened = @($opened).Count; dry_run = [bool]$Ctx.DryRun
        sample = @($paths | Select-Object -First 50); error_sample = @($errors | Select-Object -First 20) })
    return @{ scanned = $scanned; orphans = $paths; errors = $errors.Count; exceptions_opened = @($opened).Count; pruned_dirs = $pruned }
}
