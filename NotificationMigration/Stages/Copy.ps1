# Stage 2: Copy (FR-03, FR-06, FR-07, FR-10).
# Plans the files of one batch that still need copying (not verified, not in the exception register),
# hands them to the configured Copy provider (copy.engine) in checkpointed chunks and records per-file
# status. Idempotent: verified files are never re-planned, so a resumed run only does the remaining work.
# Chunks are built BY FOLDER: a folder is never split across chunks unless it holds more than
# copy.chunkSize * copy.splitFolderFactor planned files, so Robocopy can copy it in whole-folder mode
# (one process per folder, no file names on the command line).
# Also holds the helpers shared with Verify, Reconcile and the Copy providers (config access, exception
# register access, staleness flag).

function Get-MigConfigSetting {
    <#
    Reads a dotted config path ('copy.robocopy.threads'). The merged config always contains every key of
    config/defaults.json, so callers do not pass a default for those keys; $Default only covers optional keys.
    #>
    param([Parameter(Mandatory = $true)] $Config, [Parameter(Mandatory = $true)][string] $Path, $Default = $null)
    $cur = $Config
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur -or $cur -isnot [System.Collections.IDictionary] -or -not $cur.Contains($part)) { return $Default }
        $cur = $cur[$part]
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function Get-MigParentRelPath {
    <# Parent of a canonical rel_path ('' for top-level entries). #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $RelPath)
    $i = $RelPath.LastIndexOf('\')
    if ($i -lt 0) { return '' }
    return $RelPath.Substring(0, $i)
}

function Get-MigRelPathDepth {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $RelPath)
    if ([string]::IsNullOrEmpty($RelPath)) { return 0 }
    return $RelPath.Split('\').Count
}

function Get-MigCopyState {
    <# Kept for readability in the stages; the attempt-counting rules live in Get-MigFileStatus (Core/Store.ps1). #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId)
    return , (Get-MigFileStatus -Store $Store -BatchId $BatchId)
}

function Get-MigCopyStateValue {
    param([Parameter(Mandatory = $true)] $State, [Parameter(Mandatory = $true)][string] $RelPath, [Parameter(Mandatory = $true)][string] $Key)
    if (-not $State.ContainsKey($RelPath)) {
        if ($Key -eq 'attempts') { return 0 }
        return $null
    }
    return $State[$RelPath][$Key]
}

# ---- Exception register helpers (C-06) ----------------------------------------------------------------
# Rules shared by Copy, Reconcile and the orphan sweep:
#  - OPEN or ACCEPTED fingerprints (batch|rel_path|category) are never opened again.
#  - A RESOLVED exception means someone fixed the target. The item is re-checked; if the problem is still
#    there a NEW exception with the same category is opened (Add-MigExceptions itself skips every known
#    fingerprint, so re-opens are written here, in one extra append).

function Get-MigExceptionIndex {
    <#
    Reads the batch's exception register once. Returns @{ Fp = Dictionary[fingerprint -> 'open'|'accepted'|'resolved'];
    Path = Dictionary[rel_path -> @{ open; accepted; resolved }]; Open = <open count> }. When several records share a
    fingerprint (a re-open after a resolution) the effective state is open > accepted > resolved.
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId)
    $fp = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $path = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $rank = @{ open = 3; accepted = 2; resolved = 1 }
    $idx = @{ Fp = $fp; Path = $path; Open = 0 }
    foreach ($e in (Get-MigExceptions -Store $Store -BatchId $BatchId)) {
        $st = [string]$e['status']
        if (-not $rank.ContainsKey($st)) { continue }
        $f = [string]$e['fingerprint']
        if (-not $f) { $f = Get-MigExceptionFingerprint -BatchId $BatchId -RelPath ([string]$e['rel_path']) -Category ([string]$e['category']) }
        if (-not $fp.ContainsKey($f) -or $rank[$st] -gt $rank[$fp[$f]]) { $fp[$f] = $st }
        $rel = [string]$e['rel_path']
        if (-not $path.ContainsKey($rel)) { $path[$rel] = @{ open = 0; accepted = 0; resolved = 0 } }
        $path[$rel][$st]++
        if ($st -eq 'open') { $idx.Open++ }
    }
    return $idx
}

function Test-MigExceptionRecheck {
    <# True when the rel_path has resolved exception(s) and none open or accepted: it must be checked again. #>
    param([Parameter(Mandatory = $true)] $Index, [Parameter(Mandatory = $true)][string] $RelPath)
    if (-not $Index.Path.ContainsKey($RelPath)) { return $false }
    $p = $Index.Path[$RelPath]
    return ($p.resolved -gt 0 -and $p.open -eq 0 -and $p.accepted -eq 0)
}

function Test-MigExceptionAccepted {
    param([Parameter(Mandatory = $true)] $Index, [Parameter(Mandatory = $true)][string] $BatchId,
          [Parameter(Mandatory = $true)][string] $RelPath, [Parameter(Mandatory = $true)][string] $Category)
    $f = Get-MigExceptionFingerprint -BatchId $BatchId -RelPath $RelPath -Category $Category
    return ($Index.Fp.ContainsKey($f) -and $Index.Fp[$f] -eq 'accepted')
}

function Add-MigStageExceptions {
    <#
    Opens exceptions for $Items (@{ rel_path; category; detail }) with at most two appends: new fingerprints via
    Add-MigExceptions (one write), resolved fingerprints re-opened as new records (one write). Open and accepted
    fingerprints are skipped. Updates $Index. Returns the opened records (re-opens carry reopens = <old status>).
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId,
          [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Items, $Index)
    if ($Items.Count -eq 0) { return , @() }
    if ($null -eq $Index) { $Index = Get-MigExceptionIndex -Store $Ctx.Store -BatchId $BatchId }
    $fresh = New-Object System.Collections.Generic.List[object]
    $reopen = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $Items) {
        $f = Get-MigExceptionFingerprint -BatchId $BatchId -RelPath ([string]$i['rel_path']) -Category ([string]$i['category'])
        if (-not $seen.Add($f)) { continue }
        if ($Index.Fp.ContainsKey($f)) {
            if ($Index.Fp[$f] -ne 'resolved') { continue }
            $rec = New-MigExceptionRecord -BatchId $BatchId -RelPath ([string]$i['rel_path']) -Category ([string]$i['category']) -Detail ([string]$i['detail']) -RunId $Ctx.RunId
            $rec['reopens'] = 'resolved'
            $reopen.Add($rec)
        } else {
            $fresh.Add($i)
        }
    }
    $opened = New-Object System.Collections.Generic.List[object]
    if ($fresh.Count -gt 0) { foreach ($r in @(Add-MigExceptions -Store $Ctx.Store -BatchId $BatchId -Items $fresh.ToArray() -RunId $Ctx.RunId)) { $opened.Add($r) } }
    if ($reopen.Count -gt 0) {
        Add-MigStoreRecords -Store $Ctx.Store -Name 'exceptions.jsonl' -BatchId $BatchId -Records $reopen.ToArray()
        foreach ($r in $reopen) { $opened.Add($r) }
    }
    foreach ($r in $opened) {
        $Index.Fp[[string]$r['fingerprint']] = 'open'
        $rel = [string]$r['rel_path']
        if (-not $Index.Path.ContainsKey($rel)) { $Index.Path[$rel] = @{ open = 0; accepted = 0; resolved = 0 } }
        $Index.Path[$rel].open++
        $Index.Open++
    }
    return , $opened.ToArray()
}

function Write-MigExceptionAudit {
    <# ONE audit summary event for the exceptions a stage opened (counts per category + first 50 paths). #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $Event, [Parameter(Mandatory = $true)][string] $BatchId,
          [AllowEmptyCollection()][object[]] $Records = @())
    if ($Records.Count -eq 0) { return }
    $byCat = [ordered]@{}
    $reopened = 0
    foreach ($r in $Records) {
        $c = [string]$r['category']
        if (-not $byCat.Contains($c)) { $byCat[$c] = 0 }
        $byCat[$c]++
        if ($r.Contains('reopens')) { $reopened++ }
    }
    $sample = @($Records | Select-Object -First 50 | ForEach-Object { [ordered]@{ id = $_['id']; rel_path = $_['rel_path']; category = $_['category'] } })
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Level warn -Event $Event -Data ([ordered]@{
        batch = $BatchId; count = $Records.Count; reopened = $reopened; by_category = $byCat; sample = $sample })
}

function Get-MigStaleReconcileInfo {
    <#
    The batch's current 'reconcile' info with stale = $true (other keys kept), or $null when the batch was never
    reconciled (nothing to invalidate). Stages that change data a reconcile relied on (Copy, Verify) merge this
    into their Set-MigBatchInfo call so the old reconcile is marked out of date.
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId)
    $b = Get-MigBatches -Store $Store
    if (-not $b.ContainsKey($BatchId)) { return $null }
    $cur = Get-MigValue $b[$BatchId] 'reconcile'
    if ($cur -isnot [System.Collections.IDictionary]) { return $null }
    $out = [ordered]@{}
    foreach ($k in @($cur.Keys)) { $out[$k] = $cur[$k] }
    $out['stale'] = $true
    return $out
}

function Add-MigStaleReconcileInfo {
    <# Adds 'reconcile' (stale = $true) to a Set-MigBatchInfo payload when the batch has a reconcile to invalidate. #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Data)
    $rec = Get-MigStaleReconcileInfo -Store $Store -BatchId $BatchId
    if ($null -ne $rec) { $Data['reconcile'] = $rec }
    return $Data
}

# ---- Copy plan helpers ------------------------------------------------------------------------------

function Get-MigCopyPlanRelPaths {
    <# Files of a Copy plan; $Plan.RelPaths = $null means every file of the batch's source manifest. #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)] $Plan)
    if ($null -ne $Plan['RelPaths']) { return , [string[]]@($Plan['RelPaths']) }
    $src = Read-MigManifest -Store $Ctx.Store -BatchId $BatchId -Side source
    $out = foreach ($r in $src.Values) { if ($r['kind'] -eq 'file' -and -not $r['error']) { [string]$r['rel_path'] } }
    return , [string[]]@($out)
}

function Get-MigCopyPlanDirectories {
    <# Directories of a Copy plan; $Plan.Directories = $null means every directory of the batch's source manifest. #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)] $Plan)
    if ($null -ne $Plan['Directories']) { return , [string[]]@($Plan['Directories']) }
    if ($null -ne $Plan['RelPaths']) { return , [string[]]@() }
    $src = Read-MigManifest -Store $Ctx.Store -BatchId $BatchId -Side source
    $out = foreach ($r in $src.Values) { if ($r['kind'] -eq 'dir' -and -not $r['error']) { [string]$r['rel_path'] } }
    return , [string[]]@($out)
}

function Get-MigCopyChunks {
    <#
    Groups planned files by parent folder and packs WHOLE folders into chunks of about $ChunkSize files.
    A folder larger than $ChunkSize stays whole in its own chunk; only a folder with more than
    $ChunkSize * $SplitFactor files is split into name lists of $ChunkSize. Returns
    @{ Chunks = [string[]...]; SplitDirs = HashSet of folders that were split }.
    #>
    param([AllowEmptyCollection()][string[]] $RelPaths = @(), [Parameter(Mandatory = $true)][int] $ChunkSize, [int] $SplitFactor = 1)
    $ChunkSize = [Math]::Max(1, $ChunkSize)
    $splitAt = [int64]$ChunkSize * [Math]::Max(1, $SplitFactor)
    $groups = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rel in $RelPaths) {
        if (-not $rel) { continue }
        $parent = Get-MigParentRelPath $rel
        if (-not $groups.ContainsKey($parent)) { $groups[$parent] = New-Object System.Collections.Generic.List[string] }
        $groups[$parent].Add($rel)
    }
    $chunks = New-Object System.Collections.Generic.List[object]
    $split = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $cur = New-Object System.Collections.Generic.List[string]
    foreach ($parent in $groups.Keys) {
        $files = $groups[$parent]
        if ($files.Count -gt $splitAt) {
            if ($cur.Count -gt 0) { $chunks.Add($cur.ToArray()); $cur.Clear() }
            [void]$split.Add($parent)
            for ($i = 0; $i -lt $files.Count; $i += $ChunkSize) {
                $chunks.Add($files.GetRange($i, [Math]::Min($ChunkSize, $files.Count - $i)).ToArray())
            }
            continue
        }
        if ($cur.Count -gt 0 -and ($cur.Count + $files.Count) -gt $ChunkSize) { $chunks.Add($cur.ToArray()); $cur.Clear() }
        $cur.AddRange($files)
    }
    if ($cur.Count -gt 0) { $chunks.Add($cur.ToArray()) }
    return @{ Chunks = $chunks.ToArray(); SplitDirs = $split }
}

function Invoke-MigCopyProvider {
    <#
    Runs the configured Copy provider and normalises its result. A provider that throws is treated as
    "every file in the plan failed" so attempts are still counted and the run can continue.
    $Plan = @{ RelPaths; Directories; DryRun; Force; SplitDirs } (Force = re-copy even if robocopy thinks the file is
    the same; SplitDirs = optional folders whose planned files are spread over several plans).
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)][hashtable] $Plan)
    $engine = [string](Get-MigConfigSetting -Config $Ctx.Config -Path 'copy.engine')
    $provider = Get-MigProvider -Kind Copy -Name $engine
    try {
        $r = & $provider $Ctx $BatchId $Plan
        if ($r -is [array]) { $r = $r | Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1 }
        if ($r -isnot [System.Collections.IDictionary]) { throw "Copy provider '$engine' returned no result." }
    } catch {
        $msg = $_.Exception.Message
        $failed = @(foreach ($p in @($Plan['RelPaths']) + @($Plan['Directories'])) { if ($p) { @{ rel_path = [string]$p; error = "copy provider '$engine' failed: $msg" } } })
        $r = @{ exit_code = -1; succeeded = $false; copied = @(); failed = $failed; log_path = $null; error = $msg }
    }
    $out = @{
        exit_code = $r['exit_code']; succeeded = [bool]$r['succeeded']; log_path = $r['log_path']
        copied = @(@($r['copied']) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        failed = @(@($r['failed']) | Where-Object { $_ })
        exit_codes = @(@($r['exit_codes']) | Where-Object { $null -ne $_ })
        log_files = @(@($r['log_files']) | Where-Object { $_ })
        log_sidecars = @(@($r['log_sidecars']) | Where-Object { $_ })
        invocations = $r['invocations']
    }
    if ($out.exit_codes.Count -eq 0 -and $null -ne $out.exit_code) { $out.exit_codes = @($out.exit_code) }
    if ($out.log_files.Count -eq 0 -and $out.log_path) { $out.log_files = @($out.log_path) }
    return $out
}

function Save-MigCopyOutcome {
    <#
    Records file status for a provider result: 'copied' per success, 'pending' + error per failure
    (flagged copy_failed so it counts as an attempt). With -OpenExceptions, a failure that brings the
    attempts to copy.maxRetries becomes status 'exception' + an exception (category copy_failed), opened in
    bulk (one write) through Add-MigStageExceptions.
    -Directories: plan directories not reported as failed are recorded 'copied' (so dir retries are bounded too).
    Updates $State in place. Returns @{ copied; failed; exceptions_opened; opened = [exception records] }.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)] $Result,
          [Parameter(Mandatory = $true)] $State, [string[]] $Directories = @(), [switch] $OpenExceptions, $ExceptionIndex)
    $max = [int](Get-MigConfigSetting -Config $Ctx.Config -Path 'copy.maxRetries')
    $events = New-Object System.Collections.Generic.List[object]
    $failedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($f in $Result.failed) {
        $rel = [string]$f['rel_path']
        if (-not $failedSet.Add($rel)) { continue }
        if (-not $State.ContainsKey($rel)) { $State[$rel] = @{ status = $null; attempts = 0; last_error = $null } }
        $s = $State[$rel]
        $s.attempts++
        $s.status = 'pending'; $s.last_error = [string]$f['error']
        $events.Add([ordered]@{ rel_path = $rel; status = 'pending'; error = [string]$f['error']; copy_failed = $true; attempt = $s.attempts })
        if ($OpenExceptions -and $s.attempts -ge $max) {
            $s.status = 'exception'
            $events.Add([ordered]@{ rel_path = $rel; status = 'exception'; error = [string]$f['error'] })
            $items.Add(@{ rel_path = $rel; category = 'copy_failed'; detail = ('copy failed after {0} attempt(s): {1}' -f $s.attempts, $f['error']) })
        }
    }
    $copied = 0
    $ok = @($Result.copied) + @($Directories)
    foreach ($rel in $ok) {
        if (-not $rel -or $failedSet.Contains($rel)) { continue }
        if (-not $State.ContainsKey($rel)) { $State[$rel] = @{ status = $null; attempts = 0; last_error = $null } }
        $State[$rel].attempts++
        $State[$rel].status = 'copied'
        $events.Add([ordered]@{ rel_path = $rel; status = 'copied' })
        $copied++
    }
    if ($events.Count -gt 0) { Add-MigFileStatus -Store $Ctx.Store -BatchId $BatchId -Events $events.ToArray() -RunId $Ctx.RunId }
    $opened = @()
    if ($items.Count -gt 0) { $opened = Add-MigStageExceptions -Ctx $Ctx -BatchId $BatchId -Items $items.ToArray() -Index $ExceptionIndex }
    return @{ copied = $copied; failed = $failedSet.Count; exceptions_opened = @($opened).Count; opened = @($opened) }
}

function Invoke-MigStageCopy {
    <#
    Copies the outstanding files of one batch. Returns a summary hashtable.
    DryRun: the provider only lists (robocopy /L); no status or batch info is written.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId)
    $cfg = $Ctx.Config
    $store = $Ctx.Store
    $engine = [string](Get-MigConfigSetting -Config $cfg -Path 'copy.engine')
    $chunkSize = [Math]::Max(1, [int](Get-MigConfigSetting -Config $cfg -Path 'copy.chunkSize'))
    $splitFactor = [Math]::Max(1, [int](Get-MigConfigSetting -Config $cfg -Path 'copy.splitFolderFactor'))
    Assert-MigPathNotUnderSource -Path $cfg.paths.targetRoot -SourceRoot $cfg.paths.sourceRoot

    $src = Read-MigManifest -Store $store -BatchId $BatchId -Side source
    if ($src.Count -eq 0) { throw "Batch '$BatchId' has no source manifest records. Run Inventory and Batching first." }
    $state = Get-MigCopyState -Store $store -BatchId $BatchId
    $exIndex = Get-MigExceptionIndex -Store $store -BatchId $BatchId

    $normal = New-Object System.Collections.Generic.List[string]
    $force = New-Object System.Collections.Generic.List[string]
    $dirs = New-Object System.Collections.Generic.List[string]
    $skippedVerified = 0; $skippedException = 0; $skippedError = 0; $recheck = 0
    foreach ($rec in $src.Values) {
        $rel = [string]$rec['rel_path']
        if ($rec['kind'] -eq 'error' -or $rec['error']) { $skippedError++; continue }
        $st = Get-MigCopyStateValue -State $state -RelPath $rel -Key 'status'
        if ($st -eq 'verified') { $skippedVerified++; continue }
        if ($st -eq 'exception') {
            # Only a RESOLVED exception (none open or accepted) brings the item back into the plan.
            if (-not (Test-MigExceptionRecheck -Index $exIndex -RelPath $rel)) { $skippedException++; continue }
            $recheck++
        }
        if ($rec['kind'] -eq 'dir') { $dirs.Add($rel) }
        elseif ($rec['kind'] -eq 'file') {
            # 'mismatch' files are known-bad copies: force a re-copy even if size/timestamps look identical.
            if ($st -eq 'mismatch') { $force.Add($rel) } else { $normal.Add($rel) }
        }
    }
    $dirArr = @($dirs | Sort-Object { Get-MigRelPathDepth $_ } -Descending)

    $summary = [ordered]@{
        batch = $BatchId; engine = $engine; dry_run = [bool]$Ctx.DryRun; nothing_to_do = $false
        files_planned = $normal.Count + $force.Count; dirs_planned = $dirArr.Count; chunks = 0; invocations = 0
        files_attempted = 0; files_copied = 0; files_failed = 0; dirs_failed = 0; exceptions_opened = 0
        files = 0; bytes = [int64]0; bytes_copied = [int64]0
        skipped_verified = $skippedVerified; skipped_exception = $skippedException; skipped_scan_error = $skippedError
        rechecked_resolved = $recheck
        exit_codes = @(); log_files = @(); log_sidecars = @()
    }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'copy.started' -Data ([ordered]@{
        batch = $BatchId; engine = $engine; dry_run = [bool]$Ctx.DryRun; files_planned = $summary.files_planned; dirs_planned = $dirArr.Count })

    if ($summary.files_planned -eq 0 -and $dirArr.Count -eq 0) {
        $summary.nothing_to_do = $true
        $summary['message'] = 'Nothing to copy: every file in the batch is verified or in the exception register.'
        Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'copy.finished' -Data $summary
        return $summary
    }

    # Checkpointed calls, whole folders per chunk; directories go with the last call so their timestamps are
    # applied after the files.
    $calls = New-Object System.Collections.Generic.List[hashtable]
    foreach ($grp in @(@{ Files = $normal.ToArray(); Force = $false }, @{ Files = $force.ToArray(); Force = $true })) {
        $plan = Get-MigCopyChunks -RelPaths $grp.Files -ChunkSize $chunkSize -SplitFactor $splitFactor
        foreach ($slice in $plan.Chunks) {
            $calls.Add(@{ RelPaths = [string[]]$slice; Directories = [string[]]@(); DryRun = [bool]$Ctx.DryRun; Force = $grp.Force; SplitDirs = [string[]]@($plan.SplitDirs) })
        }
    }
    if ($calls.Count -eq 0) { $calls.Add(@{ RelPaths = [string[]]@(); Directories = [string[]]@(); DryRun = [bool]$Ctx.DryRun; Force = $false; SplitDirs = [string[]]@() }) }
    $calls[$calls.Count - 1].Directories = [string[]]$dirArr
    $summary.chunks = $calls.Count

    # Mark the batch as copying and its last reconcile as stale BEFORE touching the target (crash-safe).
    if (-not $Ctx.DryRun) { Set-MigBatchInfo -Store $store -BatchId $BatchId -Data (Add-MigStaleReconcileInfo -Store $store -BatchId $BatchId -Data @{ state = 'copying' }) }
    $exitCodes = New-Object System.Collections.Generic.List[object]
    $logFiles = New-Object System.Collections.Generic.List[string]
    $sidecars = New-Object System.Collections.Generic.List[string]
    $openedAll = New-Object System.Collections.Generic.List[object]
    $failSample = New-Object System.Collections.Generic.List[object]
    $failTotal = 0
    $started = [DateTime]::UtcNow
    $done = 0
    foreach ($plan in $calls) {
        $n = @($plan.RelPaths).Count
        $planSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $plan.RelPaths) { [void]$planSet.Add($p) }
        $r = Invoke-MigCopyProvider -Ctx $Ctx -BatchId $BatchId -Plan $plan
        foreach ($c in $r.exit_codes) { $exitCodes.Add($c) }
        foreach ($l in $r.log_files) { if (-not $logFiles.Contains([string]$l)) { $logFiles.Add([string]$l) } }
        foreach ($l in $r.log_sidecars) { if (-not $sidecars.Contains([string]$l)) { $sidecars.Add([string]$l) } }
        if ($null -ne $r.invocations) { $summary.invocations += [int]$r.invocations }
        $summary.files_attempted += $n
        $fileFailed = 0; $dirFailed = 0
        foreach ($f in $r.failed) {
            if ($planSet.Contains([string]$f['rel_path'])) { $fileFailed++ } else { $dirFailed++ }
            if ($failSample.Count -lt 50) { $failSample.Add($f) }
        }
        $failTotal += @($r.failed).Count
        $summary.files_failed += $fileFailed
        $summary.dirs_failed += $dirFailed
        foreach ($c in $r.copied) {
            if (-not $planSet.Contains($c)) { continue }
            $summary.files_copied++
            if ($src.ContainsKey($c) -and $null -ne $src[$c]['size_bytes']) { $summary.bytes += [int64]$src[$c]['size_bytes'] }
        }
        if (-not $Ctx.DryRun) {
            $o = Save-MigCopyOutcome -Ctx $Ctx -BatchId $BatchId -Result $r -State $state -Directories $plan.Directories -OpenExceptions -ExceptionIndex $exIndex
            foreach ($x in $o.opened) { $openedAll.Add($x) }
        }
        $done += $n
        Write-MigProgress -Activity "Copy $BatchId" -Status 'files' -Done $done -Total $summary.files_planned -Started $started
    }
    Write-Progress -Activity "Copy $BatchId" -Completed
    $summary.files = $summary.files_copied
    $summary.bytes_copied = $summary.bytes
    $summary.exceptions_opened = $openedAll.Count
    $summary.exit_codes = @($exitCodes | Select-Object -Unique)
    $summary.log_files = $logFiles.ToArray()
    $summary.log_sidecars = $sidecars.ToArray()

    if ($failTotal -gt 0) {
        Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Level warn -Event 'copy.failures' -Data ([ordered]@{
            batch = $BatchId; count = $failTotal; files = $summary.files_failed; dirs = $summary.dirs_failed; sample = $failSample.ToArray() })
    }
    Write-MigExceptionAudit -Ctx $Ctx -Event 'copy.exceptions_opened' -BatchId $BatchId -Records $openedAll.ToArray()

    if (-not $Ctx.DryRun) {
        $newState = 'copied'
        if ($summary.files_failed -gt 0 -or $summary.dirs_failed -gt 0) { $newState = 'copying' }
        Set-MigBatchInfo -Store $store -BatchId $BatchId -Data @{
            state = $newState
            copy  = [ordered]@{ files_attempted = $summary.files_attempted; files_copied = $summary.files_copied; files_failed = $summary.files_failed
                               dirs_failed = $summary.dirs_failed; bytes_copied = $summary.bytes_copied; exit_codes = $summary.exit_codes
                               log_files = $summary.log_files; log_sidecars = $summary.log_sidecars; run_id = $Ctx.RunId }
        }
    }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'copy.finished' -Data $summary
    return $summary
}
