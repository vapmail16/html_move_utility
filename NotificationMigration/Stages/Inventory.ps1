# Stage 1: Inventory (FR-01 source manifest, FR-07 resume, C-01 manifest checksums).
# Walks paths.sourceRoot as a stream and processes it in chunks (inventory.chunkSize * threads entries),
# so memory stays bounded however many millions of files the source holds. Per chunk:
#   1. (inventory.skipUnchanged) cheap parallel stat; entries whose manifest record is unchanged on
#      inventory.detectBy (default size + modified) and has no error are skipped (no re-hash) -> safe resume.
#      With 'hash' in detectBy, files are always re-hashed (only a hash can prove the content is unchanged).
#   2. everything else is scanned (metadata + hash + ACL hash) by Get-MigScanRecords.
#   3. batch_id is assigned by the configured Batch provider (batching.strategy / batching.options).
#   4. new/changed files (detectBy, plus the hash that was just computed) get a 'pending' status event,
#      then the records are appended to the batch's source manifest (status first: a crash in between
#      just re-queues the file on the next run).
# At the end:
#   - scan errors are opened as exceptions (one bulk write per batch) and audited in ONE event;
#   - batch info: a batch that did not exist before gets state 'inventoried'; an existing batch that received
#     new or changed entries gets state 'delta_pending' and reconcile.stale = $true (its earlier Copy /
#     Verify / Reconcile evidence no longer covers the manifest). Batches with no changes are untouched;
#   - C-01: manifest checksums (inventory.hash.algorithm) for every batch written in this run, and for any
#     batch that has no recorded checksum yet.
# Read-only on the source, so it also runs under -DryRun (FR-10: inventory + plan).
#
# The helpers below (stat worker, manifest index cache, batch resolver, batch state, checksums) are shared
# with Stages/Delta.ps1.

# Runs inside a runspace: must be self-contained. $Item = array of entries @{rel_path; kind; full}.
# Returns the cheap metadata the scanner would record (same formats), without hashing, plus the
# timestamps as ticks for fast comparison with the manifest index.
$script:MigInvStatWorker = {
    param($Item, $A)
    foreach ($e in $Item) {
        $r = @{ rel_path = $e.rel_path; kind = $e.kind; size_bytes = $null; created_utc = $null; modified_utc = $null
                created_ticks = $null; modified_ticks = $null; attributes = $null; error = $null }
        try {
            if ($e.kind -eq 'dir') { $fsi = New-Object System.IO.DirectoryInfo($e.full) } else { $fsi = New-Object System.IO.FileInfo($e.full) }
            $fsi.Refresh()
            if (-not $fsi.Exists) { throw 'Entry no longer exists.' }
            $c = $fsi.CreationTimeUtc; $m = $fsi.LastWriteTimeUtc
            $r.created_utc = $c.ToString('o'); $r.created_ticks = $c.Ticks
            $r.modified_utc = $m.ToString('o'); $r.modified_ticks = $m.Ticks
            $attrs = $fsi.Attributes
            foreach ($ign in $A.IgnoreAttributes) { $attrs = $attrs -band (-bnot [int][System.IO.FileAttributes]$ign) }
            $r.attributes = ([System.IO.FileAttributes]$attrs).ToString()
            if ($e.kind -eq 'file') { $r.size_bytes = $fsi.Length }
        } catch {
            $r.error = $_.Exception.Message
        }
        $r
    }
}

function Get-MigInvStatRecords {
    <# Parallel stat of $Entries (no hashing). Output is aligned with the input order. #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries)
    if ($Entries.Count -eq 0) { return @() }
    $cfg = $Ctx.Config
    $threads = Get-MigEffectiveThreads -Ctx $Ctx -Default ([int]$cfg.inventory.threads)
    $chunkSize = [Math]::Max(1, [int]$cfg.inventory.chunkSize)
    $chunks = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Entries.Count; $i += $chunkSize) {
        $chunks.Add([object[]]@($Entries[$i..([Math]::Min($i + $chunkSize, $Entries.Count) - 1)]))
    }
    $workerArgs = @{ IgnoreAttributes = @($cfg.compare.ignoreAttributes | Where-Object { $_ }) }
    $out = @(Invoke-MigParallel -Items $chunks.ToArray() -ScriptBlock $script:MigInvStatWorker -Threads $threads -Arguments $workerArgs)
    if ($out.Count -ne $Entries.Count) { throw "Stat worker returned $($out.Count) records for $($Entries.Count) entries." }
    return , $out
}

$script:MigInvInvariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:MigInvRoundtrip = [System.Globalization.DateTimeStyles]::RoundtripKind
$script:MigInvUtcKind = [DateTimeKind]::Utc

function ConvertTo-MigInvTicks {
    <# Manifest timestamp (ISO 'o' string, DateTime or DateTimeOffset) -> UTC ticks ([long]), or $null. #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $d = [DateTime]::MinValue
        if ([DateTime]::TryParseExact($Value, 'o', $script:MigInvInvariant, $script:MigInvRoundtrip, [ref]$d) -and $d.Kind -eq $script:MigInvUtcKind) { return $d.Ticks }
    }
    $d = ConvertTo-MigBatchDate $Value
    if ($null -eq $d) { return $null }
    return $d.Ticks
}

function Get-MigInvDetectBy {
    <#
    inventory.detectBy: the fields that decide whether an entry changed since its manifest record
    (size, modified, created, attributes, hash). Default size + modified. Unknown values fail clearly.
    #>
    param([Parameter(Mandatory = $true)] $Ctx)
    $raw = Get-MigValue $Ctx.Config.inventory 'detectBy' @('size', 'modified')
    $fields = @(@($raw) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    $allowed = @('size', 'modified', 'created', 'attributes', 'hash')
    $bad = @($fields | Where-Object { $allowed -notcontains $_ })
    if ($bad.Count -gt 0) { throw ("inventory.detectBy: unknown field(s) '{0}'. Allowed: {1}." -f ($bad -join "', '"), ($allowed -join ', ')) }
    if ($fields.Count -eq 0) { throw ("inventory.detectBy must list at least one field ({0})." -f ($allowed -join ', ')) }
    return [string[]]@($fields | Select-Object -Unique)
}

# ---- Batch resolver ----------------------------------------------------------------------------------

$script:MigInvSafeIdRegex = New-Object System.Text.RegularExpressions.Regex('^[A-Za-z0-9._-]+$')

function Get-MigInvBatchResolver {
    <#
    Looks up the configured Batch provider once per stage run and resets the per-run compiled-options cache,
    so providers parse their options / template once per run (not once per entry).
    #>
    param([Parameter(Mandatory = $true)] $Ctx)
    Reset-MigBatchCompileCache
    $b = $Ctx.Config.batching
    $opts = Get-MigValue $b 'options' $null
    if ($null -eq $opts) { $opts = @{} }
    $name = [string]$b.strategy
    return @{ Name = $name; Script = (Get-MigProvider -Kind Batch -Name $name); Options = $opts }
}

function Resolve-MigInvBatchId {
    param([Parameter(Mandatory = $true)] $Resolver, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RelPath, $Record)
    $out = & $Resolver.Script $RelPath $Record $Resolver.Options
    if ($out -is [array]) { if ($out.Count -eq 0) { $out = $null } else { $out = $out[-1] } }
    $id = [string]$out
    if ([string]::IsNullOrEmpty($id)) { throw "Batch provider '$($Resolver.Name)' returned no batch id for '$RelPath'." }
    if ($script:MigInvSafeIdRegex.IsMatch($id)) { return $id }
    return ConvertTo-MigSafeBatchId $id
}

# ---- Manifest index cache ----------------------------------------------------------------------------
# Compact projection of a batch's source manifest: rel_path -> object[] with the positions below.
# The cache is an LRU bounded by the total number of records held across batches
# (inventory.manifestCacheRecords, default 2,000,000; <= 0 = unbounded). The batch being worked on is never evicted.
#   0 kind  1 size_bytes ([long])  2 modified (UTC ticks)  3 created (UTC ticks)  4 attributes  5 hash  6 has_error

function New-MigInvManifestCache {
    param([Parameter(Mandatory = $true)] $Ctx)
    $cap = [long](Get-MigValue $Ctx.Config.inventory 'manifestCacheRecords' 2000000)
    return [pscustomobject]@{
        Store    = $Ctx.Store
        Capacity = $cap
        Held     = [long]0
        Map      = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        Order    = New-Object System.Collections.Generic.List[string]
    }
}

function Add-MigInvIndexEntries {
    <#
    Folds manifest records into an index (latest record wins, tombstones remove). One loop, no per-record
    function calls: timestamps become ticks, kind / attributes strings are shared, only 7 fields are kept.
    #>
    param([Parameter(Mandatory = $true)] $Index, [AllowEmptyCollection()][object[]] $Records)
    $d = [DateTime]::MinValue
    foreach ($r in $Records) {
        $rel = $r['rel_path']
        if ($null -eq $rel) { continue }
        if ($r['deleted'] -eq $true) { [void]$Index.Remove([string]$rel); continue }
        $kind = $r['kind']
        switch ($kind) { 'file' { $kind = 'file' } 'dir' { $kind = 'dir' } 'error' { $kind = 'error' } default { $kind = [string]$kind } }
        $size = $null
        if ($null -ne $r['size_bytes']) { $size = [long]$r['size_bytes'] }
        $mt = $null; $v = $r['modified_utc']
        if ($v -is [string] -and [DateTime]::TryParseExact($v, 'o', $script:MigInvInvariant, $script:MigInvRoundtrip, [ref]$d) -and $d.Kind -eq $script:MigInvUtcKind) { $mt = $d.Ticks }
        elseif ($null -ne $v) { $mt = ConvertTo-MigInvTicks $v }
        $ct = $null; $v = $r['created_utc']
        if ($v -is [string] -and [DateTime]::TryParseExact($v, 'o', $script:MigInvInvariant, $script:MigInvRoundtrip, [ref]$d) -and $d.Kind -eq $script:MigInvUtcKind) { $ct = $d.Ticks }
        elseif ($null -ne $v) { $ct = ConvertTo-MigInvTicks $v }
        $attrs = $r['attributes']
        if ($null -ne $attrs) { $attrs = [string]::Intern([string]$attrs) }
        $hasError = ($kind -eq 'error') -or -not [string]::IsNullOrEmpty([string]$r['error'])
        $Index[[string]$rel] = [object[]]@($kind, $size, $mt, $ct, $attrs, $r['hash'], $hasError)
    }
}

function Test-MigInvBatchHasManifest {
    <# True when batches/<id>/source.manifest.jsonl exists (does not create the batch folder). #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId)
    $p = Join-Path (Join-Path (Join-Path $Store.Root 'batches') $BatchId) 'source.manifest.jsonl'
    return (Test-Path -LiteralPath $p -PathType Leaf)
}

function Get-MigInvManifestIndex {
    <# Returns the index for one batch, streaming it from the store on first use. #>
    param([Parameter(Mandatory = $true)] $Cache, [Parameter(Mandatory = $true)][string] $BatchId)
    if ($Cache.Map.ContainsKey($BatchId)) {
        if ($Cache.Order[$Cache.Order.Count - 1] -ne $BatchId) { [void]$Cache.Order.Remove($BatchId); $Cache.Order.Add($BatchId) }
        return , $Cache.Map[$BatchId]
    }
    $idx = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    if (Test-MigInvBatchHasManifest -Store $Cache.Store -BatchId $BatchId) {
        $path = Join-Path (Join-Path (Join-Path $Cache.Store.Root 'batches') $BatchId) 'source.manifest.jsonl'
        Invoke-MigStoreLineBlocks -Path $path -Action { param($block) Add-MigInvIndexEntries -Index $idx -Records $block }
    }
    $Cache.Map[$BatchId] = $idx
    $Cache.Order.Add($BatchId)
    $Cache.Held += $idx.Count
    Invoke-MigInvCacheEviction -Cache $Cache
    return , $idx
}

function Invoke-MigInvCacheEviction {
    <# Evicts least recently used batches until the records held fit the capacity (never the most recent one). #>
    param([Parameter(Mandatory = $true)] $Cache)
    while ($Cache.Capacity -gt 0 -and $Cache.Held -gt $Cache.Capacity -and $Cache.Order.Count -gt 1) {
        $old = $Cache.Order[0]
        $Cache.Order.RemoveAt(0)
        $Cache.Held -= $Cache.Map[$old].Count
        [void]$Cache.Map.Remove($old)
    }
}

function Update-MigInvManifestIndex {
    <# Keeps a cached index in step with records just appended to the manifest. #>
    param([Parameter(Mandatory = $true)] $Cache, [Parameter(Mandatory = $true)][string] $BatchId, [object[]] $Records)
    if (-not $Cache.Map.ContainsKey($BatchId)) { return }
    $idx = $Cache.Map[$BatchId]
    $before = $idx.Count
    Add-MigInvIndexEntries -Index $idx -Records $Records
    $Cache.Held += ($idx.Count - $before)
}

function Get-MigInvChangedFields {
    <#
    Compares a current record (scan or stat) with an index entry on $Fields (size, modified, created,
    attributes, hash). Returns the differing field names (callers wrap in @()). A previous error always counts as 'error'.
    Stat records carry modified_ticks / created_ticks; scan records only the ISO strings (parsed here).
    #>
    param([Parameter(Mandatory = $true)] $Existing, [Parameter(Mandatory = $true)] $Current, [string[]] $Fields)
    $diff = New-Object System.Collections.Generic.List[string]
    if ($Existing[6]) { $diff.Add('error') }
    if ($Existing[0] -ne [string]$Current['kind']) { $diff.Add('kind'); return $diff.ToArray() }
    $isFile = ($Existing[0] -eq 'file')
    foreach ($f in $Fields) {
        switch ($f) {
            'size' {
                if (-not $isFile) { break }
                $cur = $null
                if ($null -ne $Current['size_bytes']) { $cur = [long]$Current['size_bytes'] }
                if ($Existing[1] -ne $cur) { $diff.Add('size') }
            }
            'modified' {
                if ($Current.Contains('modified_ticks')) { $cur = $Current['modified_ticks'] } else { $cur = ConvertTo-MigInvTicks $Current['modified_utc'] }
                if ($Existing[2] -ne $cur) { $diff.Add('modified') }
            }
            'created' {
                if ($Current.Contains('created_ticks')) { $cur = $Current['created_ticks'] } else { $cur = ConvertTo-MigInvTicks $Current['created_utc'] }
                if ($Existing[3] -ne $cur) { $diff.Add('created') }
            }
            'attributes' { if ([string]$Existing[4] -ne [string]$Current['attributes']) { $diff.Add('attributes') } }
            'hash' {
                if (-not $isFile) { break }
                if (-not $Current.Contains('hash') -or [string]$Existing[5] -ne [string]$Current['hash']) { $diff.Add('hash') }
            }
        }
    }
    return $diff.ToArray()
}

# ---- Exceptions (bulk, deduplicated by the register's fingerprint) --------------------------------------

function Add-MigInvExceptionItem {
    <# Queues one exception for the end-of-stage bulk write (Save-MigInvExceptions). #>
    param([Parameter(Mandatory = $true)] $State, [Parameter(Mandatory = $true)][string] $BatchId,
          [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RelPath, [Parameter(Mandatory = $true)][string] $Category, [string] $Detail)
    if ([string]::IsNullOrEmpty($RelPath)) { $RelPath = '.' }   # the root itself
    if (-not $State.Exceptions.ContainsKey($BatchId)) { $State.Exceptions[$BatchId] = New-Object System.Collections.Generic.List[object] }
    $State.Exceptions[$BatchId].Add(@{ rel_path = $RelPath; category = $Category; detail = $Detail })
}

function Save-MigInvExceptions {
    <#
    Opens the queued exceptions with one Add-MigExceptions call per batch (items already in the register in
    any status are skipped). Returns the number opened. Clears the queue.
    #>
    param([Parameter(Mandatory = $true)] $State)
    $opened = 0
    foreach ($bid in @($State.Exceptions.Keys)) {
        $items = $State.Exceptions[$bid].ToArray()
        if ($items.Count -eq 0) { continue }
        $opened += @(Add-MigExceptions -Store $State.Ctx.Store -BatchId $bid -Items $items -RunId $State.Ctx.RunId).Count
    }
    $State.Exceptions.Clear()
    return $opened
}

function Add-MigInvSample {
    <# Keeps the first 50 items of a list (paths for the one-per-stage audit event). #>
    param([Parameter(Mandatory = $true)] $List, $Item)
    if ($List.Count -lt 50) { $List.Add($Item) }
}

# ---- Batch state -------------------------------------------------------------------------------------

function Get-MigInvKnownBatchIds {
    <# Batch ids that exist before a stage run: batch info records plus batch folders with a source manifest. #>
    param([Parameter(Mandatory = $true)] $Store)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in (Get-MigBatches -Store $Store).Keys) { [void]$set.Add([string]$k) }
    foreach ($b in (Get-MigBatchIds -Store $Store)) { if (Test-MigInvBatchHasManifest -Store $Store -BatchId $b) { [void]$set.Add($b) } }
    return , $set
}

function Set-MigInvBatchChanged {
    <#
    Records that $BatchId's source manifest changed (shared contract with Copy / Verify / Reconcile):
      - new batch (not in $Known)  -> state 'inventoried'
      - existing batch             -> state 'delta_pending' and reconcile.stale = $true, merged into the
                                      batch's existing reconcile keys (Reconcile clears it).
    $Extra: more keys to merge into the same batch info record (e.g. plan, delta, inventory).
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)] $Known,
          [Parameter(Mandatory = $true)] $Info, [System.Collections.IDictionary] $Extra)
    $data = [ordered]@{}
    if ($Known.Contains($BatchId)) {
        $rec = [ordered]@{}
        $old = $null
        if ($Info.ContainsKey($BatchId)) { $old = Get-MigValue $Info[$BatchId] 'reconcile' $null }
        if ($old -is [System.Collections.IDictionary]) { foreach ($k in @($old.Keys)) { $rec[$k] = $old[$k] } }
        $rec['stale'] = $true
        $data['state'] = 'delta_pending'
        $data['reconcile'] = $rec
    } else {
        $data['state'] = 'inventoried'
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $data[$k] = $Extra[$k] } }
    Set-MigBatchInfo -Store $Ctx.Store -BatchId $BatchId -Data $data
    return $data['state']
}

function Get-MigInvWalk {
    <# Get-MigTreeEntries with the inventory config applied (streams). #>
    param([Parameter(Mandatory = $true)] $Ctx)
    $cfg = $Ctx.Config
    $root = [string]$cfg.paths.sourceRoot
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "paths.sourceRoot '$root' does not exist or is not a folder."
    }
    $excl = @($cfg.inventory.excludePatterns | Where-Object { $_ })
    Get-MigTreeEntries -Root $root -ExcludePatterns $excl -IncludeDirectories ([bool]$cfg.inventory.includeDirectories) -UseLongPath ([bool]$cfg.paths.useLongPathPrefix)
}

function Get-MigInvBufferSize {
    param([Parameter(Mandatory = $true)] $Ctx)
    $threads = Get-MigEffectiveThreads -Ctx $Ctx -Default ([int]$Ctx.Config.inventory.threads)
    return [Math]::Max(1, [int]$Ctx.Config.inventory.chunkSize) * [Math]::Max(1, $threads)
}

function Test-MigInvCaseDuplicate {
    <# True for the walk's 'case_duplicate_of:<name>' error entries (never written to the manifest). #>
    param($Record)
    return ([string]$Record['error']).StartsWith('case_duplicate_of:', [StringComparison]::Ordinal)
}

# ---- Stage -------------------------------------------------------------------------------------------

function Invoke-MigStageInventory {
    param([Parameter(Mandatory = $true)] $Ctx)
    $cfg = $Ctx.Config
    $detectBy = Get-MigInvDetectBy -Ctx $Ctx
    $state = [pscustomobject]@{
        Ctx         = $Ctx
        Resolver    = Get-MigInvBatchResolver -Ctx $Ctx
        Cache       = New-MigInvManifestCache -Ctx $Ctx
        Skip        = [bool]$cfg.inventory.skipUnchanged
        StatFields  = [string[]]@($detectBy | Where-Object { $_ -ne 'hash' })
        ScanFields  = [string[]]@(@($detectBy) + 'hash' | Select-Object -Unique)
        FullHash    = ($detectBy -contains 'hash')
        Known       = Get-MigInvKnownBatchIds -Store $Ctx.Store
        Batches     = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Touched     = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        Exceptions  = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        ErrorSample = New-Object System.Collections.Generic.List[object]
        Started     = [DateTime]::UtcNow
        Summary     = [ordered]@{ files = 0; dirs = 0; bytes = [long]0; errors = 0; hashed = 0; skipped_unchanged = 0; new_or_changed = 0; exceptions_opened = 0; batches = 0 }
    }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'inventory.started' -Data ([ordered]@{
        source_root = $cfg.paths.sourceRoot; strategy = $state.Resolver.Name; skip_unchanged = $state.Skip; detect_by = $detectBy
        hash_algorithm = $cfg.inventory.hash.algorithm; dry_run = $Ctx.DryRun
    })

    $bufferSize = Get-MigInvBufferSize -Ctx $Ctx
    $buffer = New-Object System.Collections.Generic.List[object]
    Get-MigInvWalk -Ctx $Ctx | ForEach-Object {
        $buffer.Add($_)
        if ($buffer.Count -ge $bufferSize) {
            Invoke-MigInventoryChunk -State $state -Entries $buffer.ToArray()
            $buffer.Clear()
        }
    }
    if ($buffer.Count -gt 0) { Invoke-MigInventoryChunk -State $state -Entries $buffer.ToArray(); $buffer.Clear() }
    Write-Progress -Activity 'Inventory' -Completed

    $s = $state.Summary
    $s.exceptions_opened = Save-MigInvExceptions -State $state
    if ($s.errors -gt 0) {
        Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Level warn -Event 'inventory.scan_errors' -Data ([ordered]@{
            errors = $s.errors; exceptions_opened = $s.exceptions_opened; first = $state.ErrorSample.ToArray()
        })
    }

    # Batch info for every batch this run wrote records to (new -> inventoried, changed -> delta_pending + stale).
    $info = Get-MigBatches -Store $Ctx.Store
    $newBatches = 0; $changedBatches = 0
    $affected = New-Object System.Collections.Generic.List[string]
    foreach ($bid in @($state.Touched.Keys)) {
        $t = $state.Touched[$bid]
        $isNew = -not $state.Known.Contains($bid)
        if (-not $isNew -and $t.changed -eq 0) { continue }       # only unchanged re-scans: untouched
        $extra = [ordered]@{ inventory = [ordered]@{ run_id = $Ctx.RunId; records = $t.records; changed = $t.changed; ts_utc = Get-MigUtcNow } }
        [void](Set-MigInvBatchChanged -Ctx $Ctx -BatchId $bid -Known $state.Known -Info $info -Extra $extra)
        if ($isNew) { $newBatches++ } else { $changedBatches++ }
        $affected.Add($bid)
    }
    # Gate freshness invalidates only these batches (a summary without the key would affect every batch).
    $affectedIds = $affected.ToArray()
    [Array]::Sort($affectedIds, [StringComparer]::Ordinal)

    $checksums = Write-MigManifestChecksums -Ctx $Ctx -BatchIds ([string[]]@($state.Touched.Keys)) -IncludeMissing -EventPrefix 'inventory'
    $s.batches = $state.Batches.Count
    $s['batches_new'] = $newBatches
    $s['batches_changed'] = $changedBatches
    $s['affected_batches'] = [string[]]$affectedIds
    $s['manifest_checksums'] = $checksums.Count
    $s['detect_by'] = $detectBy
    # Truthful result for the gate: an inventory with unreadable entries is incomplete (see the exceptions).
    $s['passed'] = ($s.errors -eq 0)
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'inventory.completed' -Data $s
    return $s
}

function Add-MigInvTouched {
    param([Parameter(Mandatory = $true)] $State, [Parameter(Mandatory = $true)][string] $BatchId, [int] $Records, [int] $Changed)
    if (-not $State.Touched.ContainsKey($BatchId)) { $State.Touched[$BatchId] = @{ records = 0; changed = 0 } }
    $t = $State.Touched[$BatchId]
    $t.records += $Records; $t.changed += $Changed
}

function Invoke-MigInventoryChunk {
    <# Processes one buffered chunk of walk entries (see file header). #>
    param([Parameter(Mandatory = $true)] $State, [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries)
    $ctx = $State.Ctx
    $s = $State.Summary
    $toScan = New-Object System.Collections.Generic.List[object]
    $work = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Entries) { if ($e.kind -eq 'error') { $toScan.Add($e) } else { $work.Add($e) } }

    # 1. Resume: skip entries whose manifest record is unchanged on detectBy (no re-hash).
    if ($State.Skip -and $work.Count -gt 0) {
        $stats = Get-MigInvStatRecords -Ctx $ctx -Entries $work.ToArray()
        for ($i = 0; $i -lt $work.Count; $i++) {
            $st = $stats[$i]
            if ($st['error'] -or ($State.FullHash -and $st['kind'] -eq 'file')) { $toScan.Add($work[$i]); continue }
            $bid = Resolve-MigInvBatchId -Resolver $State.Resolver -RelPath $st['rel_path'] -Record $st
            $idx = Get-MigInvManifestIndex -Cache $State.Cache -BatchId $bid
            $ex = $null
            if ($idx.TryGetValue([string]$st['rel_path'], [ref]$ex)) {
                $diff = @(Get-MigInvChangedFields -Existing $ex -Current $st -Fields $State.StatFields)
                if ($diff.Count -eq 0 -and ($ex[0] -ne 'file' -or $ex[5])) {
                    $s.skipped_unchanged++
                    [void]$State.Batches.Add($bid)
                    if ($st['kind'] -eq 'file') { $s.files++; $s.bytes += [long]$st['size_bytes'] } else { $s.dirs++ }
                    continue
                }
            }
            $toScan.Add($work[$i])
        }
    } else {
        foreach ($w in $work) { $toScan.Add($w) }
    }
    if ($toScan.Count -eq 0) { Write-MigInventoryProgress -State $State; return }

    # 2. Scan (hash + metadata) and 3. assign batches.
    $records = Get-MigScanRecords -Ctx $ctx -Side source -Entries $toScan.ToArray()
    $byBatch = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $pendingByBatch = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $changedByBatch = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $records) {
        $rel = [string]$r['rel_path']
        $bid = Resolve-MigInvBatchId -Resolver $State.Resolver -RelPath $rel -Record $r
        $r['batch_id'] = $bid
        [void]$State.Batches.Add($bid)
        if (-not $byBatch.ContainsKey($bid)) {
            $byBatch[$bid] = New-Object System.Collections.Generic.List[object]
            $pendingByBatch[$bid] = New-Object System.Collections.Generic.List[object]
            $changedByBatch[$bid] = 0
        }

        if ($r['kind'] -eq 'file') { $s.files++; if ($null -ne $r['size_bytes']) { $s.bytes += [long]$r['size_bytes'] } }
        elseif ($r['kind'] -eq 'dir') { $s.dirs++ }

        $idx = Get-MigInvManifestIndex -Cache $State.Cache -BatchId $bid
        $ex = $null
        $isNew = -not $idx.TryGetValue($rel, [ref]$ex)

        if ($r['error'] -or $r['kind'] -eq 'error') {
            $s.errors++
            Add-MigInvExceptionItem -State $State -BatchId $bid -RelPath $rel -Category 'scan_error' -Detail ([string]$r['error'])
            Add-MigInvSample -List $State.ErrorSample -Item ([ordered]@{ batch_id = $bid; rel_path = $rel; kind = $r['kind']; error = $r['error'] })
            # A case-only duplicate would overwrite the first entry's record in the case-insensitive manifest.
            if (Test-MigInvCaseDuplicate $r) { continue }
            if ($isNew -or -not $ex[6]) { $changedByBatch[$bid]++ }     # a good record turned into an error
            $byBatch[$bid].Add($r)
            continue
        }
        if ($r['kind'] -eq 'file') { $s.hashed++ }

        # 4. New or changed (vs the existing manifest record) -> pending. A re-hash of an unchanged file is not re-queued.
        $changed = $false
        if (-not $isNew) { $changed = @(Get-MigInvChangedFields -Existing $ex -Current $r -Fields $State.ScanFields).Count -gt 0 }
        if ($isNew -or $changed) {
            $s.new_or_changed++
            $changedByBatch[$bid]++
            if ($r['kind'] -eq 'file') { $pendingByBatch[$bid].Add(@{ rel_path = $rel; status = 'pending' }) }
        }
        $byBatch[$bid].Add($r)
    }

    foreach ($bid in $byBatch.Keys) {
        $recs = $byBatch[$bid].ToArray()
        if ($recs.Count -eq 0) { continue }
        $pending = $pendingByBatch[$bid]
        if ($pending.Count -gt 0) { Add-MigFileStatus -Store $ctx.Store -BatchId $bid -Events $pending.ToArray() -RunId $ctx.RunId }
        Write-MigManifest -Store $ctx.Store -BatchId $bid -Side source -Records $recs
        Update-MigInvManifestIndex -Cache $State.Cache -BatchId $bid -Records $recs
        Add-MigInvTouched -State $State -BatchId $bid -Records $recs.Count -Changed $changedByBatch[$bid]
    }
    Write-MigInventoryProgress -State $State
}

function Write-MigInventoryProgress {
    param([Parameter(Mandatory = $true)] $State)
    $s = $State.Summary
    $seen = $s.files + $s.dirs
    Write-MigProgress -Activity 'Inventory' -Status ('files {0}, dirs {1}, bytes {2}, hashed {3}, skipped {4}, errors {5}' -f $s.files, $s.dirs, $s.bytes, $s.hashed, $s.skipped_unchanged, $s.errors) -Done $seen -Total 0 -Started $State.Started
    Write-Verbose ('Inventory: {0} entries, {1} bytes, {2} errors' -f $seen, $s.bytes, $s.errors)
}

# ---- C-01 manifest checksums -------------------------------------------------------------------------

function Get-MigManifestChecksumAlgorithm {
    param([Parameter(Mandatory = $true)] $Ctx)
    return ([string](Get-MigValue $Ctx.Config.inventory.hash 'algorithm' 'SHA256')).ToUpperInvariant()
}

function Write-MigManifestChecksums {
    <#
    C-01: checksum (inventory.hash.algorithm) of batches' source.manifest.jsonl, appended to
    <store>/manifest.checksums.jsonl (latest record per batch wins) as @{ batch_id; file; algorithm; hash; run_id; ts_utc },
    and audited in ONE event. -BatchIds: the batches to checksum (those written in this run); -IncludeMissing also
    covers every batch with a manifest but no recorded checksum. Without -BatchIds every batch is covered.
    Returns the records written.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [string[]] $BatchIds, [switch] $IncludeMissing, [string] $EventPrefix = 'inventory')
    $alg = Get-MigManifestChecksumAlgorithm -Ctx $Ctx
    $want = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($PSBoundParameters.ContainsKey('BatchIds')) {
        foreach ($b in @($BatchIds)) { if ($b) { [void]$want.Add($b) } }
        if ($IncludeMissing) {
            $recorded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($r in (Read-MigStoreRecords -Store $Ctx.Store -Name 'manifest.checksums.jsonl')) { [void]$recorded.Add([string]$r['batch_id']) }
            foreach ($b in (Get-MigBatchIds -Store $Ctx.Store)) { if (-not $recorded.Contains($b)) { [void]$want.Add($b) } }
        }
    } else {
        foreach ($b in (Get-MigBatchIds -Store $Ctx.Store)) { [void]$want.Add($b) }
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($bid in $want) {
        if (-not (Test-MigInvBatchHasManifest -Store $Ctx.Store -BatchId $bid)) { continue }
        $path = Get-MigStorePath -Store $Ctx.Store -Name 'source.manifest.jsonl' -BatchId $bid
        $out.Add([ordered]@{
            batch_id = $bid; file = ('batches/{0}/source.manifest.jsonl' -f $bid); algorithm = $alg
            hash = Get-MigFileHash -Path $path -Algorithm $alg; run_id = $Ctx.RunId; ts_utc = Get-MigUtcNow
        })
    }
    if ($out.Count -gt 0) {
        Add-MigStoreRecords -Store $Ctx.Store -Name 'manifest.checksums.jsonl' -Records $out.ToArray()
        Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event ($EventPrefix + '.manifest_checksums') -Data ([ordered]@{
            count = $out.Count; algorithm = $alg; checksums = @($out | Select-Object -First 50)
        })
    }
    return , $out.ToArray()
}

# ---- C-01 manifest export (CSV) ----------------------------------------------------------------------

function ConvertTo-MigInvCsvCell {
    <# CSV cell, quoted. Values a spreadsheet would run as a formula (= + - @ start, non-numeric; tab/CR start) get a leading '. #>
    param($Value)
    if ($null -eq $Value) { $text = '' }
    elseif ($Value -is [DateTime]) { $text = $Value.ToUniversalTime().ToString('o') }
    elseif ($Value -is [DateTimeOffset]) { $text = $Value.UtcDateTime.ToString('o') }
    elseif ($Value -is [bool]) { $text = $Value.ToString().ToLowerInvariant() }
    else { $text = [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
    $num = 0.0
    if ($text.Length -gt 0 -and '=+-@'.IndexOf($text[0]) -ge 0 -and -not [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)) {
        $text = "'" + $text
    }
    if ($text.Length -gt 0 -and "`t`r".IndexOf($text[0]) -ge 0) { $text = "'" + $text }
    return '"' + $text.Replace('"', '""') + '"'
}

function Export-MigManifestCsv {
    <#
    Exports a batch's source manifest (latest record per rel_path, sorted) as CSV: UTF-8 with BOM, CRLF,
    spreadsheet-formula-safe cells. Written to <reportDir>/manifests/ (or -OutDir) as
    <batch>.source.manifest.<utc>.csv, with a checksum sidecar <csv>.<algorithm> ('<hash>  <file name>')
    using inventory.hash.algorithm. Audited. Returns @{ path; checksum_path; rows; algorithm; hash }.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, [string] $OutDir)
    Assert-MigBatchId $BatchId
    if (-not (Test-MigInvBatchHasManifest -Store $Ctx.Store -BatchId $BatchId)) { throw "Batch '$BatchId' has no source manifest (run Inventory first)." }
    if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path ([string]$Ctx.Config._resolved.reportDir) 'manifests' }
    $OutDir = Resolve-MigFullPath $OutDir
    Assert-MigPathNotUnderSource -Path $OutDir -SourceRoot $Ctx.Config.paths.sourceRoot
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

    $alg = Get-MigManifestChecksumAlgorithm -Ctx $Ctx
    $m = Read-MigManifest -Store $Ctx.Store -BatchId $BatchId -Side source
    $keys = [string[]]@($m.Keys)
    [Array]::Sort($keys, [StringComparer]::OrdinalIgnoreCase)
    $cols = @('rel_path', 'kind', 'batch_id', 'size_bytes', 'created_utc', 'modified_utc', 'attributes', 'hash', 'hash_algo', 'acl_hash', 'scanned_utc', 'error')
    $name = '{0}.source.manifest.{1}.csv' -f $BatchId, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $path = Join-Path $OutDir $name
    $w = New-Object System.IO.StreamWriter($path, $false, (New-Object System.Text.UTF8Encoding($true)))
    try {
        $w.Write((@($cols | ForEach-Object { ConvertTo-MigInvCsvCell $_ }) -join ',')); $w.Write("`r`n")
        foreach ($k in $keys) {
            $r = $m[$k]
            $cells = New-Object string[] $cols.Count
            for ($i = 0; $i -lt $cols.Count; $i++) { $cells[$i] = ConvertTo-MigInvCsvCell $r[$cols[$i]] }
            $w.Write([string]::Join(',', $cells)); $w.Write("`r`n")
        }
    } finally { $w.Dispose() }
    $hash = Get-MigFileHash -Path $path -Algorithm $alg
    $sidecar = $path + '.' + $alg.ToLowerInvariant()
    [System.IO.File]::WriteAllText($sidecar, ('{0}  {1}' -f $hash, $name) + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $result = [ordered]@{ path = $path; checksum_path = $sidecar; rows = $keys.Count; algorithm = $alg; hash = $hash }
    $audit = [ordered]@{ batch_id = $BatchId }
    foreach ($k in $result.Keys) { $audit[$k] = $result[$k] }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'inventory.manifest_exported' -Data $audit
    return $result
}
