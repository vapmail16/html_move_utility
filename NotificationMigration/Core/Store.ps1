# JSON-lines manifest store. No database, no third-party modules.
#
# Layout under <storeDir>:
#   batches.jsonl                     batch plan + state events (latest wins per batch_id)
#   stages.jsonl                      stage run events (started/completed/failed) per scope
#   gates.jsonl                       maker-checker approvals
#   batches/<batchId>/exceptions.jsonl exception register events for the batch (latest wins per id)
#   batches/<batchId>/source.manifest.jsonl
#   batches/<batchId>/target.manifest.jsonl
#   batches/<batchId>/status.events.jsonl
#   batches/<batchId>/htmlchecks.<side>.jsonl
#   batches/<batchId>/<anything else a stage needs>.jsonl
#
# Files are append-only. Readers fold events so the latest record per key wins. A torn last line
# (crash mid-write) is skipped with a warning, so resume is always possible.

function Initialize-MigStore {
    param([Parameter(Mandatory = $true)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $batches = Join-Path $Path 'batches'
    if (-not (Test-Path -LiteralPath $batches)) { New-Item -ItemType Directory -Path $batches -Force | Out-Null }
    return [pscustomobject]@{ Root = (Resolve-Path -LiteralPath $Path).ProviderPath }
}

function Assert-MigBatchId {
    param([Parameter(Mandatory = $true)][string] $BatchId)
    if ($BatchId -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid batch id '$BatchId'. Allowed characters: A-Z a-z 0-9 . _ -" }
}

function ConvertTo-MigSafeBatchId {
    <# Batch strategies call this so any derived id is a valid folder name. #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value)
    $safe = [regex]::Replace($Value, '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrEmpty($safe)) { return '_' }
    return $safe
}

function Get-MigStorePath {
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $Name, [string] $BatchId)
    if ($BatchId) {
        Assert-MigBatchId $BatchId
        $dir = Join-Path (Join-Path $Store.Root 'batches') $BatchId
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        return Join-Path $dir $Name
    }
    return Join-Path $Store.Root $Name
}

function Add-MigStoreRecords {
    <#
    Appends records as JSON lines with ONE write + flush. If the file does not end in a newline (a previous
    process died mid-write), a newline is written first so the torn line stays isolated and the new records
    are never glued onto it. Retries briefly when another process is appending (shared store).
    #>
    param(
        [Parameter(Mandatory = $true)] $Store,
        [Parameter(Mandatory = $true)][string] $Name,
        [string] $BatchId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()] [object[]] $Records
    )
    if ($Records.Count -eq 0) { return }
    $path = Get-MigStorePath -Store $Store -Name $Name -BatchId $BatchId
    $sb = New-Object System.Text.StringBuilder
    foreach ($r in $Records) { [void]$sb.Append((ConvertTo-MigJsonLine $r)).Append("`n") }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($sb.ToString())
    $attempt = 0
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            break
        } catch [System.IO.IOException] {
            if (++$attempt -ge 40) { throw }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
    try {
        if ($fs.Length -gt 0) {
            [void]$fs.Seek(-1, [System.IO.SeekOrigin]::End)
            if ($fs.ReadByte() -ne 10) { $fs.WriteByte(10) }
        }
        [void]$fs.Seek(0, [System.IO.SeekOrigin]::End)
        $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true)
    } finally { $fs.Dispose() }
}

function Add-MigStoreRecord {
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $Name, [string] $BatchId, [Parameter(Mandatory = $true)] $Record)
    Add-MigStoreRecords -Store $Store -Name $Name -BatchId $BatchId -Records @(, $Record)
}

function ConvertFrom-MigJsonLines {
    <#
    Parses JSON lines in one bulk parse, falling back to per-line parsing. Only the LAST line may be
    unreadable (a torn write from a crash); a bad line anywhere else means the file was damaged or edited,
    which is an error - evidence is never silently dropped.
    #>
    param([string[]] $Lines, [string] $SourceName, [switch] $AllowTornTail)
    $Lines = @($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Lines.Count -eq 0) { return @() }
    # ConvertFrom-MigJsonArrayText always returns the parsed array as ONE object; assign it, don't wrap it in @().
    try { $parsed = ConvertFrom-MigJsonArrayText ('[' + ($Lines -join ',') + ']'); return $parsed }
    catch {
        $out = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            try { $one = ConvertFrom-MigJsonArrayText ('[' + $Lines[$i] + ']'); $out.Add($one[0]) }
            catch {
                if ($AllowTornTail -and $i -eq $Lines.Count - 1) { Write-Warning "Store: skipping torn last line in $SourceName (interrupted write)." }
                elseif ($AllowTornTail) {
                    # A torn line followed by more records: an interrupted write that later appends isolated with a newline.
                    if ($Lines[$i] -notmatch '^\{' -or $Lines[$i] -match '\}\s*$') { throw "Store: line $($i + 1) of $SourceName is not valid JSON (file damaged or edited)." }
                    Write-Warning "Store: skipping torn line $($i + 1) in $SourceName (interrupted write)."
                }
                else { throw "Store: line $($i + 1) of $SourceName is not valid JSON." }
            }
        }
        return $out.ToArray()
    }
}

function ConvertFrom-MigJsonArrayText {
    param([Parameter(Mandatory = $true)][string] $Text)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # Timestamps must stay ISO strings on every edition (5.1's serializer never converts them).
        if ($script:MigJsonHasDateKind) { return , (@(ConvertFrom-Json -InputObject $Text -AsHashtable -NoEnumerate -DateKind String)[0]) }
        return , (ConvertTo-MigDateStrings @(ConvertFrom-Json -InputObject $Text -AsHashtable -NoEnumerate)[0])
    }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    return , $ser.DeserializeObject($Text)
}

$script:MigJsonHasDateKind = [bool](Get-Command ConvertFrom-Json).Parameters['DateKind']

function ConvertTo-MigDateStrings {
    <# PowerShell 7.0-7.4 fallback: turns DateTime values parsed from JSON back into ISO-8601 'o' strings. #>
    param($Value)
    if ($Value -is [DateTime]) { return $Value.ToString('o') }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString('o') }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) { $Value[$k] = ConvertTo-MigDateStrings $Value[$k] }
        return $Value
    }
    if ($Value -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $Value.Count; $i++) { $Value[$i] = ConvertTo-MigDateStrings $Value[$i] }
        return , $Value
    }
    return $Value
}

function Read-MigStoreRecords {
    <#
    Reads all records of a store file. Opens with FileShare.ReadWrite so reads never fail while another process
    appends. Parses in blocks of lines to bound peak memory (no whole-file string join).
    A torn line is tolerated only when it looks like an interrupted write (starts with '{', no closing '}').
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $Name, [string] $BatchId, [int] $BlockLines = 20000)
    $path = Get-MigStorePath -Store $Store -Name $Name -BatchId $BatchId
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    Invoke-MigStoreLineBlocks -Path $path -BlockLines $BlockLines -Action { param($block) foreach ($r in $block) { $out.Add($r) } }
    return $out.ToArray()
}

function Invoke-MigStoreLineBlocks {
    <# Streams a JSONL file and calls $Action with each parsed block of records (for large per-batch files). #>
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][scriptblock] $Action, [int] $BlockLines = 20000)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $reader = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $buf = New-Object System.Collections.Generic.List[string]
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.Length -eq 0) { continue }
            $buf.Add($line)
            if ($buf.Count -ge $BlockLines) {
                # Hold back the last line so a torn line is only ever judged at the true end of file.
                $last = $buf[$buf.Count - 1]; $buf.RemoveAt($buf.Count - 1)
                & $Action (ConvertFrom-MigJsonLines -Lines $buf.ToArray() -SourceName $Path -AllowTornTail)
                $buf.Clear(); $buf.Add($last)
            }
        }
        if ($buf.Count -gt 0) { & $Action (ConvertFrom-MigJsonLines -Lines $buf.ToArray() -SourceName $Path -AllowTornTail) }
    } finally { $reader.Dispose(); $fs.Dispose() }
}

function Compress-MigStoreFile {
    <#
    Compaction: rewrites a store file keeping only the latest record per $Key (optionally dropping records where
    $DropWhere returns true). The previous file is kept as archive/<name>.<utc>.jsonl with a checksum sidecar,
    so no evidence is lost. Returns @{ before; after; archive }.
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $Name, [string] $BatchId,
          [Parameter(Mandatory = $true)][string] $Key)
    $path = Get-MigStorePath -Store $Store -Name $Name -BatchId $BatchId
    if (-not (Test-Path -LiteralPath $path)) { return @{ before = 0; after = 0; archive = $null } }
    $all = Read-MigStoreRecords -Store $Store -Name $Name -BatchId $BatchId
    $latest = Get-MigLatestByKey -Records $all -Key $Key
    if ($latest.Count -eq $all.Count) { return @{ before = $all.Count; after = $all.Count; archive = $null } }
    $archiveDir = Join-Path ([System.IO.Path]::GetDirectoryName($path)) 'archive'
    if (-not (Test-Path -LiteralPath $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
    $archive = Join-Path $archiveDir ('{0}.{1}.jsonl' -f [System.IO.Path]::GetFileNameWithoutExtension($Name), [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
    $tmp = $path + '.compact.tmp'
    $sorted = @($latest.Keys | Sort-Object)
    $w = New-Object System.IO.StreamWriter($tmp, $false, (New-Object System.Text.UTF8Encoding($false)))
    try { foreach ($k in $sorted) { $w.Write((ConvertTo-MigJsonLine $latest[$k])); $w.Write("`n") } } finally { $w.Dispose() }
    [System.IO.File]::Move($path, $archive)
    [System.IO.File]::Move($tmp, $path)
    [System.IO.File]::WriteAllText($archive + '.sha256', ('{0}  {1}' -f (Get-MigFileHash -Path $archive), [System.IO.Path]::GetFileName($archive)) + "`n")
    return @{ before = $all.Count; after = $sorted.Count; archive = $archive }
}

function Get-MigLatestByKey {
    <# Folds records so the last record per key wins. Keys compare case-insensitively (NTFS semantics). #>
    param([object[]] $Records, [Parameter(Mandatory = $true)][string] $Key)
    $d = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $Records) { if ($null -ne $r[$Key]) { $d[[string]$r[$Key]] = $r } }
    return , $d
}

# ---- Manifest ------------------------------------------------------------------------------------
# Record: rel_path, kind (file|dir), batch_id, side, size_bytes, created_utc, modified_utc, attributes,
#         acl_hash, hash, hash_algo, scanned_utc, error, deleted (tombstone for delta)

function Write-MigManifest {
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId,
          [Parameter(Mandatory = $true)][ValidateSet('source', 'target')][string] $Side,
          [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Records)
    Add-MigStoreRecords -Store $Store -Name "$Side.manifest.jsonl" -BatchId $BatchId -Records $Records
}

function Read-MigManifest {
    <# Returns Dictionary[rel_path -> record], latest record wins, tombstoned entries removed. #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId,
          [Parameter(Mandatory = $true)][ValidateSet('source', 'target')][string] $Side)
    $d = Get-MigLatestByKey -Records (Read-MigStoreRecords -Store $Store -Name "$Side.manifest.jsonl" -BatchId $BatchId) -Key 'rel_path'
    foreach ($k in @($d.Keys)) { if ($d[$k]['deleted'] -eq $true) { [void]$d.Remove($k) } }
    return , $d
}

function Get-MigBatchIds {
    param([Parameter(Mandatory = $true)] $Store)
    $dir = Join-Path $Store.Root 'batches'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Directory | Sort-Object Name | ForEach-Object { $_.Name })
}

# ---- File status (pending, copied, verified, mismatch, exception) ------------------------------------

function Add-MigFileStatus {
    <# $Events: hashtables with rel_path, status, and optionally error. attempt/run_id/ts_utc are filled in. #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId,
          [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Events, [string] $RunId)
    $valid = @('pending', 'copied', 'verified', 'mismatch', 'exception')
    $ts = Get-MigUtcNow
    foreach ($e in $Events) {
        if ($valid -notcontains $e['status']) { throw "Invalid file status '$($e['status'])'." }
        if (-not $e.Contains('ts_utc')) { $e['ts_utc'] = $ts }
        if (-not $e.Contains('run_id')) { $e['run_id'] = $RunId }
    }
    Add-MigStoreRecords -Store $Store -Name 'status.events.jsonl' -BatchId $BatchId -Records $Events
}

function Get-MigFileStatus {
    <#
    Returns Dictionary[rel_path -> @{status; attempts; last_error; ts_utc}].
    attempts counts every copy attempt: 'copied' events AND failed attempts (events flagged copy_failed),
    so files that never copy successfully still reach copy.maxRetries.
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId)
    $d = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in (Read-MigStoreRecords -Store $Store -Name 'status.events.jsonl' -BatchId $BatchId)) {
        $k = [string]$e['rel_path']
        if (-not $d.ContainsKey($k)) { $d[$k] = @{ status = $null; attempts = 0; last_error = $null; ts_utc = $null } }
        $s = $d[$k]
        $s.status = $e['status']; $s.ts_utc = $e['ts_utc']
        # A compaction snapshot carries the folded attempt count; later events keep counting from it.
        if ($null -ne $e['attempts_base']) { $s.attempts = [int]$e['attempts_base'] }
        elseif ($e['status'] -eq 'copied' -or $e['copy_failed'] -eq $true) { $s.attempts++ }
        if ($e['error']) { $s.last_error = $e['error'] }
    }
    return , $d
}

# ---- Batches -----------------------------------------------------------------------------------------

function Set-MigBatchInfo {
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Data)
    Assert-MigBatchId $BatchId
    $rec = [ordered]@{ batch_id = $BatchId; ts_utc = Get-MigUtcNow }
    foreach ($k in $Data.Keys) { $rec[$k] = $Data[$k] }
    Add-MigStoreRecord -Store $Store -Name 'batches.jsonl' -Record $rec
}

function Get-MigBatches {
    <# Returns ordered Dictionary[batch_id -> merged info] (later events overwrite earlier keys). #>
    param([Parameter(Mandatory = $true)] $Store)
    $d = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in (Read-MigStoreRecords -Store $Store -Name 'batches.jsonl')) {
        $id = [string]$r['batch_id']
        if (-not $d.ContainsKey($id)) { $d[$id] = @{} }
        foreach ($k in @($r.Keys)) { $d[$id][$k] = $r[$k] }
    }
    return , $d
}

# ---- Stage runs --------------------------------------------------------------------------------------

function Add-MigStageEvent {
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $Stage, [Parameter(Mandatory = $true)][string] $Scope,
          [Parameter(Mandatory = $true)][ValidateSet('started', 'completed', 'failed')][string] $State,
          [Parameter(Mandatory = $true)][string] $RunId, [Parameter(Mandatory = $true)][string] $Operator,
          [bool] $DryRun = $false, [System.Collections.IDictionary] $Summary, [System.Collections.IDictionary] $AuditRef)
    Add-MigStoreRecord -Store $Store -Name 'stages.jsonl' -Record ([ordered]@{
        stage = $Stage; scope = $Scope; state = $State; run_id = $RunId; operator = $Operator
        dry_run = $DryRun; ts_utc = Get-MigUtcNow; summary = $Summary; audit_ref = $AuditRef
    })
}

function Get-MigLatestStageEvent {
    <#
    Latest event for (stage, scope), or $null. -CompletedOnly: only 'completed' events. -RealOnly: ignore dry runs.
    Pass -Records to reuse an already-read stages.jsonl (gate checks read it once).
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $Stage, [Parameter(Mandatory = $true)][string] $Scope,
          [switch] $CompletedOnly, [switch] $RealOnly, [object[]] $Records)
    if ($null -eq $Records) { $Records = Read-MigStoreRecords -Store $Store -Name 'stages.jsonl' }
    $latest = $null
    foreach ($r in $Records) {
        if ($r['stage'] -ne $Stage -or $r['scope'] -ne $Scope) { continue }
        if ($CompletedOnly -and $r['state'] -ne 'completed') { continue }
        if ($RealOnly -and $r['dry_run'] -eq $true) { continue }
        $latest = $r
    }
    return $latest
}

# ---- Exception register (control C-06) -------------------------------------------------------------
# Stored per batch (batches/<id>/exceptions.jsonl), latest record per id wins. A 'fingerprint'
# (batch|rel_path|category) lets stages avoid re-opening an item a person already accepted or resolved.

function Get-MigExceptionFingerprint {
    param([Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)][string] $RelPath, [Parameter(Mandatory = $true)][string] $Category)
    return ('{0}|{1}|{2}' -f $BatchId, $RelPath, $Category).ToLowerInvariant()
}

function New-MigExceptionRecord {
    param([Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)][string] $RelPath,
          [Parameter(Mandatory = $true)][string] $Category, [string] $Detail, [string] $Owner, [string] $RunId)
    $now = Get-MigUtcNow
    return [ordered]@{
        id = [guid]::NewGuid().ToString(); batch_id = $BatchId; rel_path = $RelPath; category = $Category; detail = $Detail
        fingerprint = Get-MigExceptionFingerprint -BatchId $BatchId -RelPath $RelPath -Category $Category
        owner = $Owner; status = 'open'; resolution = $null; run_id = $RunId; opened_utc = $now; ts_utc = $now
    }
}

function Add-MigException {
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)][string] $RelPath,
          [Parameter(Mandatory = $true)][string] $Category, [string] $Detail, [string] $Owner, [string] $RunId)
    $rec = New-MigExceptionRecord -BatchId $BatchId -RelPath $RelPath -Category $Category -Detail $Detail -Owner $Owner -RunId $RunId
    Add-MigStoreRecord -Store $Store -Name 'exceptions.jsonl' -BatchId $BatchId -Record $rec
    return $rec['id']
}

function Add-MigExceptions {
    <#
    Bulk open: one write + one flush for many exceptions in a batch. Items whose fingerprint already exists in
    ANY status (open, accepted, resolved) are skipped - a closed decision is never silently re-opened.
    $Items: hashtables with rel_path, category, detail. Returns the records actually opened.
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId,
          [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Items, [string] $Owner, [string] $RunId)
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in (Get-MigExceptions -Store $Store -BatchId $BatchId)) { [void]$known.Add([string]$e['fingerprint']) }
    $new = New-Object System.Collections.Generic.List[object]
    foreach ($i in $Items) {
        $fp = Get-MigExceptionFingerprint -BatchId $BatchId -RelPath ([string]$i['rel_path']) -Category ([string]$i['category'])
        if (-not $known.Add($fp)) { continue }
        $new.Add((New-MigExceptionRecord -BatchId $BatchId -RelPath ([string]$i['rel_path']) -Category ([string]$i['category']) -Detail ([string]$i['detail']) -Owner $Owner -RunId $RunId))
    }
    Add-MigStoreRecords -Store $Store -Name 'exceptions.jsonl' -BatchId $BatchId -Records $new.ToArray()
    return $new.ToArray()
}

function Update-MigException {
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $Id, [string] $BatchId,
          [ValidateSet('open', 'resolved', 'accepted')][string] $Status, [string] $Resolution, [string] $Owner, [string] $By)
    $current = (Get-MigExceptions -Store $Store -BatchId $BatchId) | Where-Object { $_['id'] -eq $Id } | Select-Object -First 1
    if (-not $current) { throw "Exception '$Id' not found." }
    $rec = [ordered]@{}
    foreach ($k in @($current.Keys)) { $rec[$k] = $current[$k] }
    if (-not $rec.Contains('fingerprint') -or -not $rec['fingerprint']) { $rec['fingerprint'] = Get-MigExceptionFingerprint -BatchId $rec['batch_id'] -RelPath $rec['rel_path'] -Category $rec['category'] }
    if ($Status) { $rec['status'] = $Status }
    if ($Resolution) { $rec['resolution'] = $Resolution }
    if ($Owner) { $rec['owner'] = $Owner }
    if ($By) { $rec['updated_by'] = $By }
    $rec['ts_utc'] = Get-MigUtcNow
    Add-MigStoreRecord -Store $Store -Name 'exceptions.jsonl' -BatchId ([string]$rec['batch_id']) -Record $rec
}

function Get-MigExceptions {
    <# Latest state of each exception. With -BatchId reads one batch; without, every batch (plus a legacy global file). #>
    param([Parameter(Mandatory = $true)] $Store, [string] $BatchId, [string] $Status)
    $records = New-Object System.Collections.Generic.List[object]
    if ($BatchId) {
        foreach ($r in (Read-MigStoreRecords -Store $Store -Name 'exceptions.jsonl' -BatchId $BatchId)) { $records.Add($r) }
    } else {
        foreach ($r in (Read-MigStoreRecords -Store $Store -Name 'exceptions.jsonl')) { $records.Add($r) }
        foreach ($b in (Get-MigBatchIds -Store $Store)) { foreach ($r in (Read-MigStoreRecords -Store $Store -Name 'exceptions.jsonl' -BatchId $b)) { $records.Add($r) } }
    }
    $d = Get-MigLatestByKey -Records $records.ToArray() -Key 'id'
    $out = foreach ($v in $d.Values) {
        if ($BatchId -and $v['batch_id'] -ne $BatchId) { continue }
        if ($Status -and $v['status'] -ne $Status) { continue }
        $v
    }
    return @($out)
}
