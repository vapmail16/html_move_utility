# Stage: Report (FR-09). Builds one report object from the store and hands it to every configured Report
# provider (report.formats). Output: <reportDir>/<batch-<id>|final|plan>-<utc stamp>/ plus a checksum sidecar
# (<file>.<audit.hashAlgorithm>, e.g. .sha256) for every report file.
#
# Report kinds:
#   batch  (-BatchId)   one batch: plan, copy, verify, reconcile, htmlChecks, latest-run issues/findings,
#                       exceptions and gate decisions for that batch
#   final  (-Final)     all batches + totals + acceptance-criteria checklist + audit/robocopy log evidence +
#                       evidence manifest of the store + governance (sign-off, freeze, retention, overrides, orphans)
#   plan                dry run / plan-only: nothing beyond Inventory/Batching has run for the batches covered
#   summary             no -BatchId and no -Final: all batches, without the acceptance checklist
#
# The batch list is the union of the store's batch folders and batches.jsonl (a batch folder that is missing from
# batches.jsonl is reported and fails). The pseudo-batch 'ORPHANS' (target entries outside every batch) is
# reported separately.
#
# A batch PASSES only when its state is 'reconciled', reconcile.passed is true and not stale, the reconcile run
# completed after the latest real Copy/Verify of the batch and after every real Inventory/Delta that changed the
# batch (summary.affected_batches, as in the gates; stages.jsonl file order), and no file is still pending/copied/mismatch. Each failing batch shows its reasons.
#
# Scale: the final report aggregates from batch info and counts (one batch's files in memory at a time); per-file
# detail lives in the batch reports unless report.finalIncludeDetails is set. HTML tables are capped at
# report.htmlMaxRows; the CSV files always have every row.
#
# Every table is flat (scalar cells) so CSV/HTML/JSON providers stay generic:
#   $Report.tables.<name> = @{ title; columns; rows [; csv_name; external_csv] }

$script:MigRptOrphanBatch = 'ORPHANS'
$script:MigRptSignOffRoles = @('SourceOwner', 'TargetOwner', 'ControlOwner')

function Get-MigRptValue {
    <# Safe dictionary read (StrictMode, Hashtable/OrderedDictionary/Dictionary[string,object]). #>
    param($Object, [Parameter(Mandatory = $true)][string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        # Dictionary[string,object] (PS 5.1 store records) implements Contains only explicitly; use ContainsKey there.
        if ($Object -is [System.Collections.Specialized.OrderedDictionary]) { $has = $Object.Contains($Name) } else { $has = $Object.ContainsKey($Name) }
        if ($has -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Format-MigRptCell {
    <# Converts a store value to a display/CSV string: DateTime -> ISO-8601 UTC, collections -> compact text. #>
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = foreach ($k in $Value.Keys) { '{0}={1}' -f $k, (Format-MigRptCell $Value[$k]) }
        return (@($parts) -join '; ')
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($v in $Value) { Format-MigRptCell $v }
        return (@($parts) -join '; ')
    }
    return [string]$Value
}

function New-MigRptTable {
    <#
    Flat table. -CsvName overrides the CSV file name the HTML "more rows" note points to; -ExternalCsv means the
    stage writes that CSV itself (the csv provider skips the table).
    #>
    param([Parameter(Mandatory = $true)][string] $Title, [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Columns,
          [AllowEmptyCollection()][object[]] $Rows, [string] $CsvName, [switch] $ExternalCsv)
    $flat = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $o = [ordered]@{}
        foreach ($c in $Columns) { $o[$c] = Format-MigRptCell (Get-MigRptValue $r $c) }
        $flat.Add($o)
    }
    $t = [ordered]@{ title = $Title; columns = $Columns; rows = $flat.ToArray() }
    if ($CsvName) { $t['csv_name'] = $CsvName }
    if ($ExternalCsv) { $t['external_csv'] = $true }
    return $t
}

function Get-MigRptLong { param($Object, [string] $Name) return [long](Get-MigRptValue $Object $Name 0) }

function Join-MigRptList {
    <# 'a, b, c (and 12 more)' - keeps acceptance details readable for thousands of batches. #>
    param([AllowEmptyCollection()][object[]] $Items, [int] $Max = 20, [string] $Separator = ', ')
    $all = @($Items)
    if ($all.Count -eq 0) { return 'none' }
    if ($all.Count -le $Max) { return ($all -join $Separator) }
    return ('{0}{1}(and {2} more)' -f (@($all[0..($Max - 1)]) -join $Separator), $Separator, ($all.Count - $Max))
}

# ---- Stage events and gates (read once, indexed once) ------------------------------------------------

function New-MigRptStageIndex {
    <#
    One pass over stages.jsonl. For every real (non-dry) completed run: its position in the file. Appends are
    serialised, so file order is completion order (independent of clock skew between servers).
      latest['<stage>|<scope>']          = @{ event; pos }  latest real completed run
      byRun['<stage>|<scope>|<run_id>']  = pos
      global                             = every real completed global Inventory/Delta, @{ stage; event; pos }, file order
    #>
    param([AllowEmptyCollection()][object[]] $Records)
    $latest = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $byRun = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)
    $global = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Records.Count; $i++) {
        $r = $Records[$i]
        if ($r['state'] -ne 'completed' -or $r['dry_run'] -eq $true) { continue }
        $k = '{0}|{1}' -f $r['stage'], $r['scope']
        $latest[$k] = @{ event = $r; pos = $i }
        $byRun[('{0}|{1}' -f $k, $r['run_id'])] = $i
        if ($r['scope'] -eq 'global' -and @('Inventory', 'Delta') -contains [string]$r['stage']) { $global.Add(@{ stage = [string]$r['stage']; event = $r; pos = $i }) }
    }
    return @{ records = $Records; latest = $latest; byRun = $byRun; global = $global.ToArray() }
}

function Get-MigRptLatestRun {
    <# @{ event; pos } of the latest real completed run of $Stage for $Scope, or $null. #>
    param([Parameter(Mandatory = $true)] $Index, [Parameter(Mandatory = $true)][string] $Stage, [Parameter(Mandatory = $true)][string] $Scope)
    $v = $null
    if ($Index.latest.TryGetValue(('{0}|{1}' -f $Stage, $Scope), [ref]$v)) { return $v }
    return $null
}

function Get-MigRptRunPosition {
    param([Parameter(Mandatory = $true)] $Index, [string] $Stage, [string] $Scope, [string] $RunId)
    $p = 0
    if ($RunId -and $Index.byRun.TryGetValue(('{0}|{1}|{2}' -f $Stage, $Scope, $RunId), [ref]$p)) { return $p }
    return -1
}

function New-MigRptGateIndex {
    <# Latest decision per '<stage>|<scope>|<run_id>' (one pass instead of one scan per batch). #>
    param([AllowEmptyCollection()][object[]] $Gates)
    $d = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($g in $Gates) { $d[('{0}|{1}|{2}' -f $g['stage'], $g['scope'], $g['run_id'])] = $g }
    return , $d
}

# ---- Per-batch readers -------------------------------------------------------------------------------

function Get-MigRptBatchDir {
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId)
    return (Join-Path (Join-Path $Store.Root 'batches') $BatchId)
}

function Read-MigRptRunRecords {
    <#
    Streams one run's records from a per-batch result file. Uses the per-run file named in batch info
    (e.g. reconcile.results.<runId>.jsonl) when it exists, else the legacy fixed-name file; records are always
    filtered by run_id. Optional -Category filter. Never creates folders.
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId, $PerRunFile,
          [Parameter(Mandatory = $true)][string] $LegacyFile, [string] $RunId, [string] $Category, [string] $Side)
    $rptOut = New-Object System.Collections.Generic.List[object]
    if (-not $RunId) { return , $rptOut.ToArray() }
    $dir = Get-MigRptBatchDir -Store $Store -BatchId $BatchId
    $name = $null
    if ($PerRunFile) {
        $leaf = [System.IO.Path]::GetFileName([string]$PerRunFile)
        if ($leaf -eq [string]$PerRunFile -and (Test-Path -LiteralPath (Join-Path $dir $leaf))) { $name = $leaf }
    }
    if (-not $name) { $name = $LegacyFile }
    $path = Join-Path $dir $name
    if (-not (Test-Path -LiteralPath $path)) { return , $rptOut.ToArray() }
    $rptRun = $RunId; $rptCat = $Category; $rptBatch = $BatchId; $rptSide = $Side
    Invoke-MigStoreLineBlocks -Path $path -Action {
        param($block)
        foreach ($r in $block) {
            if ([string]$r['run_id'] -ne $rptRun) { continue }
            if ($rptCat -and [string]$r['category'] -ne $rptCat) { continue }
            $r['batch_id'] = $rptBatch
            if ($rptSide -and -not $r['side']) { $r['side'] = $rptSide }
            $rptOut.Add($r)
        }
    }
    return , $rptOut.ToArray()
}

function Get-MigRptExceptionStats {
    <# Counts of one batch's exception register (+ accepted fingerprints; + rows with -KeepRows). #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId, [bool] $HasFolder, [switch] $KeepRows)
    $s = @{
        total = 0; open = 0; open_html_parity = 0
        by_cat_status = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)
        accepted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        rows = New-Object System.Collections.Generic.List[object]
    }
    if (-not $HasFolder) { return $s }
    foreach ($e in @(Get-MigExceptions -Store $Store -BatchId $BatchId)) {
        $s.total++
        $st = [string]$e['status']; $cat = [string]$e['category']
        if ($st -eq 'open') { $s.open++; if ($cat -eq 'html_parity') { $s.open_html_parity++ } }
        $k = '{0}|{1}' -f $cat, $st
        $n = 0; [void]$s.by_cat_status.TryGetValue($k, [ref]$n); $s.by_cat_status[$k] = $n + 1
        if ($st -eq 'accepted') {
            $fp = [string](Get-MigRptValue $e 'fingerprint' '')
            if (-not $fp -and $e['rel_path'] -and $cat) { $fp = Get-MigExceptionFingerprint -BatchId $BatchId -RelPath ([string]$e['rel_path']) -Category $cat }
            if ($fp) { [void]$s.accepted.Add($fp) }
        }
        if ($KeepRows) { $s.rows.Add($e) }
    }
    return $s
}

function Get-MigRptFileStatusCounts {
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId, [bool] $HasFolder)
    $c = [ordered]@{ pending = 0; copied = 0; mismatch = 0; verified = 0; exception = 0 }
    if (-not $HasFolder) { return $c }
    foreach ($v in (Get-MigFileStatus -Store $Store -BatchId $BatchId).Values) {
        $st = [string]$v.status
        if ($c.Contains($st)) { $c[$st]++ }
    }
    return $c
}

function Get-MigRptMetadataCoverage {
    <#
    AC-4: every metadata_mismatch issue of the latest reconcile run must be covered by an ACCEPTED exception with
    the same fingerprint (batch|rel_path|category). Returns @{ total; covered; uncovered; sample }.
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId, $Rec, $Accepted)
    $out = @{ total = 0; covered = 0; uncovered = 0; sample = New-Object System.Collections.Generic.List[string] }
    if (-not $Rec) { return $out }
    $expected = Get-MigRptLong $Rec 'metadata_mismatch'
    if ($expected -le 0) { return $out }
    $recs = Read-MigRptRunRecords -Store $Store -BatchId $BatchId -PerRunFile (Get-MigRptValue $Rec 'results_file') -LegacyFile 'reconcile.results.jsonl' `
        -RunId ([string](Get-MigRptValue $Rec 'run_id' '')) -Category 'metadata_mismatch'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $recs) {
        $fp = Get-MigExceptionFingerprint -BatchId $BatchId -RelPath ([string]$i['rel_path']) -Category 'metadata_mismatch'
        if (-not $seen.Add($fp)) { continue }
        $out.total++
        if ($Accepted -and $Accepted.Contains($fp)) { $out.covered++ }
        else { $out.uncovered++; if ($out.sample.Count -lt 5) { $out.sample.Add([string]$i['rel_path']) } }
    }
    if ($out.total -eq 0) {
        # The count says there are mismatches but the per-file results cannot be read: nothing can be proven covered.
        $out.total = $expected; $out.uncovered = $expected; $out.sample.Add('(reconcile results file missing)')
    }
    return $out
}

function Get-MigRptAcceptedExtras {
    <#
    Extras of the latest reconcile run (category 'extra') covered by an ACCEPTED exception with the same fingerprint
    (batch|rel_path|extra_on_target). The tool never deletes from the target, so these are excluded from the
    count/bytes comparison (AC-1/AC-2) and from "zero extra" (AC-3), and listed in the detail. Sizes come from the
    target manifest (latest record per path). Open or resolved extras are NOT excluded.
    Returns @{ count; files; bytes; paths }.
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId, $Rec, $Accepted)
    $out = @{ count = 0; files = 0; bytes = [long]0; paths = New-Object System.Collections.Generic.List[string] }
    if (-not $Rec -or (Get-MigRptLong $Rec 'extra') -le 0 -or -not $Accepted -or $Accepted.Count -eq 0) { return $out }
    $recs = Read-MigRptRunRecords -Store $Store -BatchId $BatchId -PerRunFile (Get-MigRptValue $Rec 'results_file') -LegacyFile 'reconcile.results.jsonl' `
        -RunId ([string](Get-MigRptValue $Rec 'run_id' '')) -Category 'extra'
    $rptWanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $recs) {
        $rel = [string]$i['rel_path']
        if (-not $Accepted.Contains((Get-MigExceptionFingerprint -BatchId $BatchId -RelPath $rel -Category 'extra_on_target'))) { continue }
        if ($rptWanted.Add($rel)) { $out.count++; $out.paths.Add($rel) }
    }
    if ($rptWanted.Count -eq 0) { return $out }
    $path = Join-Path (Get-MigRptBatchDir -Store $Store -BatchId $BatchId) 'target.manifest.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return $out }
    $rptSizes = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::OrdinalIgnoreCase)
    Invoke-MigStoreLineBlocks -Path $path -Action {
        param($block)
        foreach ($r in $block) {
            $rel = [string]$r['rel_path']
            if (-not $rptWanted.Contains($rel)) { continue }
            $sz = [long]-1
            if ($r['kind'] -eq 'file' -and $r['deleted'] -ne $true) { $sz = 0; if ($null -ne $r['size_bytes']) { $sz = [long]$r['size_bytes'] } }
            $rptSizes[$rel] = $sz
        }
    }
    foreach ($v in $rptSizes.Values) { if ($v -ge 0) { $out.files++; $out.bytes += $v } }
    return $out
}

function Get-MigRptBatchVerdict {
    <# Item C1: may this batch count as passed? Returns @{ passed; reasons; status_counts; reconcile_pos }. #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, $Info, [bool] $Planned, [bool] $HasFolder,
          [Parameter(Mandatory = $true)] $Index)
    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $Planned) { $reasons.Add('batch folder exists in the store but the batch is not in batches.jsonl') }
    $state = [string](Get-MigRptValue $Info 'state' '')
    if ($state -ne 'reconciled') { $reasons.Add("state is '$state', not 'reconciled'") }
    $rec = Get-MigRptValue $Info 'reconcile'
    $pos = -1
    if (-not $rec) { $reasons.Add('not reconciled') }
    else {
        if ((Get-MigRptValue $rec 'passed' $false) -ne $true) { $reasons.Add('reconcile did not pass') }
        if ((Get-MigRptValue $rec 'stale' $false) -eq $true) { $reasons.Add('reconcile is stale (data changed after it; re-run Verify and Reconcile)') }
        $run = [string](Get-MigRptValue $rec 'run_id' '')
        $pos = Get-MigRptRunPosition -Index $Index -Stage 'Reconcile' -Scope $BatchId -RunId $run
        if ($pos -lt 0) { $reasons.Add("reconcile run '$run' has no completed real Reconcile stage event") }
        else {
            foreach ($st in @('Copy', 'Verify')) {
                $l = Get-MigRptLatestRun -Index $Index -Stage $st -Scope $BatchId
                if ($l -and $l.pos -gt $pos) { $reasons.Add(("{0} run {1} completed after reconcile run {2}" -f $st, $l.event['run_id'], $run)) }
            }
            # Same rule as the gates: a later Inventory/Delta invalidates the reconcile only if it changed this batch
            # (summary.affected_batches; a summary without that list affects every batch). Every later event counts,
            # not just the latest, so an older Delta that touched the batch cannot be hidden by a newer one.
            foreach ($m in @($Index.global)) {
                if ($m.pos -le $pos -or -not (Test-MigEventAffectsBatch -Event $m.event -BatchId $BatchId)) { continue }
                $reasons.Add(("{0} run {1} completed after reconcile run {2} and changed this batch" -f $m.stage, $m.event['run_id'], $run))
            }
        }
    }
    $counts = Get-MigRptFileStatusCounts -Store $Ctx.Store -BatchId $BatchId -HasFolder $HasFolder
    $notDone = $counts.pending + $counts.copied + $counts.mismatch
    if ($notDone -gt 0) { $reasons.Add(('{0} file(s) not verified (pending {1}, copied {2}, mismatch {3})' -f $notDone, $counts.pending, $counts.copied, $counts.mismatch)) }
    return @{ passed = ($reasons.Count -eq 0); reasons = $reasons.ToArray(); status_counts = $counts; reconcile_pos = $pos }
}

function Get-MigRptHtmlVerdict {
    <#
    AC-5 for one batch: the latest real HtmlChecks run is the one in batch info, is newer than the latest
    Copy/Verify, is approved (provably, via the audit log), and has parity=true or an approved override;
    no open html_parity exceptions. Independent of whether HtmlChecks is listed in pipeline.gates.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, $Info, [Parameter(Mandatory = $true)] $Index,
          [Parameter(Mandatory = $true)] $GateIndex, [int] $OpenParity)
    $reasons = New-Object System.Collections.Generic.List[string]
    $override = $false
    $html = Get-MigRptValue $Info 'htmlChecks'
    if (-not $html) { $reasons.Add('HTML checks not run') }
    else {
        $l = Get-MigRptLatestRun -Index $Index -Stage 'HtmlChecks' -Scope $BatchId
        if (-not $l) { $reasons.Add('no completed real HtmlChecks run') }
        else {
            $hrun = [string]$l.event['run_id']
            $infoRun = [string](Get-MigRptValue $html 'run_id' '')
            if ($infoRun -ne $hrun) { $reasons.Add("batch info shows HTML run '$infoRun' but the latest HtmlChecks run is '$hrun'") }
            foreach ($st in @('Copy', 'Verify')) {
                $c = Get-MigRptLatestRun -Index $Index -Stage $st -Scope $BatchId
                if ($c -and $c.pos -gt $l.pos) { $reasons.Add(("{0} run {1} completed after HtmlChecks run {2}" -f $st, $c.event['run_id'], $hrun)) }
            }
            $g = $null
            [void]$GateIndex.TryGetValue(('HtmlChecks|{0}|{1}' -f $BatchId, $hrun), [ref]$g)
            if (-not $g -or $g['decision'] -ne 'approved') { $reasons.Add("HtmlChecks run $hrun is not approved") }
            elseif (-not (Test-MigAuditReference -LogDir $Ctx.Config._resolved.logDir -Ref $g['audit_ref'] -Event 'gate.decision')) {
                $reasons.Add("approval of HtmlChecks run $hrun has no matching audit-log entry")
            } else { $override = ($g['override'] -eq $true) }
            if ((Get-MigRptValue $html 'parity' $false) -ne $true -and -not $override) { $reasons.Add('parity=false (source/target HTML findings differ) and no approved override') }
        }
    }
    if ($OpenParity -gt 0) { $reasons.Add("$OpenParity open html_parity exception(s)") }
    return @{ passed = ($reasons.Count -eq 0); reasons = $reasons.ToArray(); override = $override }
}

function Get-MigRptBatchData {
    <# Everything the report needs for one batch. -Details also loads the latest run's issues/findings/exceptions. #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, $Info, [bool] $Planned, [bool] $HasFolder,
          [Parameter(Mandatory = $true)] $Index, [Parameter(Mandatory = $true)] $GateIndex,
          [switch] $Details, [switch] $Evaluate)
    $store = $Ctx.Store
    $plan = Get-MigRptValue $Info 'plan'
    $copy = Get-MigRptValue $Info 'copy'
    $verify = Get-MigRptValue $Info 'verify'
    $rec = Get-MigRptValue $Info 'reconcile'
    $html = Get-MigRptValue $Info 'htmlChecks'
    $recRun = [string](Get-MigRptValue $rec 'run_id' '')
    $htmlRun = [string](Get-MigRptValue $html 'run_id' '')

    $exStats = Get-MigRptExceptionStats -Store $store -BatchId $BatchId -HasFolder $HasFolder -KeepRows:$Details
    $verdict = $null; $htmlVerdict = $null; $meta = $null
    if ($Evaluate) {
        $verdict = Get-MigRptBatchVerdict -Ctx $Ctx -BatchId $BatchId -Info $Info -Planned $Planned -HasFolder $HasFolder -Index $Index
        $htmlVerdict = Get-MigRptHtmlVerdict -Ctx $Ctx -BatchId $BatchId -Info $Info -Index $Index -GateIndex $GateIndex -OpenParity $exStats.open_html_parity
        $meta = Get-MigRptMetadataCoverage -Store $store -BatchId $BatchId -Rec $rec -Accepted $exStats.accepted
    }
    $accExtras = Get-MigRptAcceptedExtras -Store $store -BatchId $BatchId -Rec $rec -Accepted $exStats.accepted

    $issues = @(); $findings = @(); $parity = @()
    if ($Details) {
        $issues = Read-MigRptRunRecords -Store $store -BatchId $BatchId -PerRunFile (Get-MigRptValue $rec 'results_file') -LegacyFile 'reconcile.results.jsonl' -RunId $recRun
        $files = Get-MigRptValue $html 'files'
        $fl = New-Object System.Collections.Generic.List[object]
        foreach ($side in @('source', 'target')) {
            $fl.AddRange([object[]](Read-MigRptRunRecords -Store $store -BatchId $BatchId -PerRunFile (Get-MigRptValue $files $side) -LegacyFile "htmlchecks.$side.jsonl" -RunId $htmlRun -Side $side))
        }
        $findings = $fl.ToArray()
        $parity = Read-MigRptRunRecords -Store $store -BatchId $BatchId -PerRunFile (Get-MigRptValue $files 'parity') -LegacyFile 'htmlchecks.parity.jsonl' -RunId $htmlRun
    }

    $recPassed = $null
    if ($rec) { $recPassed = [bool](Get-MigRptValue $rec 'passed' $false) }
    $htmlParity = $null
    if ($html) { $htmlParity = [bool](Get-MigRptValue $html 'parity' $false) }

    $row = [ordered]@{
        batch_id = $BatchId; state = Get-MigRptValue $Info 'state' ''; in_batches_file = $Planned
        passed = $null; fail_reasons = ''
        planned_files = Get-MigRptValue $plan 'file_count'; planned_dirs = Get-MigRptValue $plan 'dir_count'
        planned_bytes = Get-MigRptValue $plan 'total_bytes'; zero_byte_files = Get-MigRptValue $plan 'zero_byte_count'
        plan_errors = Get-MigRptValue $plan 'error_count'
        files_copied = Get-MigRptValue $copy 'files_copied'; files_copy_failed = Get-MigRptValue $copy 'files_failed'
        verified_files = Get-MigRptValue $verify 'files'; verified_bytes = Get-MigRptValue $verify 'bytes'
        source_files = Get-MigRptValue $rec 'source_files'; target_files = Get-MigRptValue $rec 'target_files'
        source_bytes = Get-MigRptValue $rec 'source_bytes'; target_bytes = Get-MigRptValue $rec 'target_bytes'
        source_dirs = Get-MigRptValue $rec 'source_dirs'; target_dirs = Get-MigRptValue $rec 'target_dirs'
        missing = Get-MigRptValue $rec 'missing'; extra = Get-MigRptValue $rec 'extra'
        extra_accepted = $accExtras.count; accepted_extra_files = $accExtras.files; accepted_extra_bytes = $accExtras.bytes
        size_mismatch = Get-MigRptValue $rec 'size_mismatch'; hash_mismatch = Get-MigRptValue $rec 'hash_mismatch'
        metadata_mismatch = Get-MigRptValue $rec 'metadata_mismatch'; metadata_not_accepted = $null; scan_errors = Get-MigRptValue $rec 'scan_errors'
        reconcile_passed = $recPassed; reconcile_stale = [bool](Get-MigRptValue $rec 'stale' $false); reconcile_run_id = $recRun
        files_not_verified = $null
        html_checked = [bool]$html; html_parity = $htmlParity; html_ok = $null; html_reasons = ''
        html_source_findings = Get-MigRptValue $html 'source_findings'; html_target_findings = Get-MigRptValue $html 'target_findings'
        html_parity_differences = Get-MigRptValue $html 'parity_differences'; html_run_id = $htmlRun
        exceptions_total = $exStats.total; exceptions_open = $exStats.open
    }
    if ($Evaluate) {
        $row.passed = $verdict.passed; $row.fail_reasons = ($verdict.reasons -join '; ')
        $row.files_not_verified = $verdict.status_counts.pending + $verdict.status_counts.copied + $verdict.status_counts.mismatch
        $row.metadata_not_accepted = $meta.uncovered
        $row.html_ok = $htmlVerdict.passed; $row.html_reasons = ($htmlVerdict.reasons -join '; ')
    }
    return @{
        id = $BatchId; info = $Info; plan = $plan; copy = $copy; verify = $verify; reconcile = $rec; html = $html
        row = $row; issues = $issues; findings = $findings; parity = $parity; ex = $exStats
        verdict = $verdict; html_verdict = $htmlVerdict; metadata = $meta; accepted_extras = $accExtras
        reconciled = [bool]$rec; progressed = ([bool]$copy -or [bool]$verify -or [bool]$rec -or [bool]$html)
    }
}

# ---- Cross-checks and evidence ------------------------------------------------------------------------

function Get-MigRptManifestTotals {
    <# Files/bytes of the source manifests (latest record per rel_path, tombstones excluded), one batch in memory at a time. #>
    param([Parameter(Mandatory = $true)] $Store, [AllowEmptyCollection()][string[]] $BatchIds)
    $files = [long]0; $bytes = [long]0
    foreach ($b in $BatchIds) {
        $path = Join-Path (Get-MigRptBatchDir -Store $Store -BatchId $b) 'source.manifest.jsonl'
        if (-not (Test-Path -LiteralPath $path)) { continue }
        # rel_path -> size (-1 = not a counted file)
        $rptSizes = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::OrdinalIgnoreCase)
        Invoke-MigStoreLineBlocks -Path $path -Action {
            param($block)
            foreach ($r in $block) {
                if ($null -eq $r['rel_path']) { continue }
                $sz = [long]-1
                if ($r['kind'] -eq 'file' -and $r['deleted'] -ne $true) { $sz = 0; if ($null -ne $r['size_bytes']) { $sz = [long]$r['size_bytes'] } }
                $rptSizes[[string]$r['rel_path']] = $sz
            }
        }
        foreach ($v in $rptSizes.Values) { if ($v -ge 0) { $files++; $bytes += $v } }
    }
    return @{ files = $files; bytes = $bytes }
}

function Get-MigRptInventoryCrossCheck {
    <#
    C2: total source files/bytes in the manifests must equal the reference totals, so a batch lost from both the
    store and batches.jsonl cannot silently drop out. The reference is the LATEST real completed Inventory/Delta
    that carries totals (Inventory: files/bytes; Delta: source_files/source_bytes = totals after the Delta).
    A later Delta without totals that changed nothing is skipped; one that changed something (older summary
    format) makes the check "not verifiable" (fallback only).
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [AllowEmptyCollection()][string[]] $BatchIds, [Parameter(Mandatory = $true)] $Index)
    $m = Get-MigRptManifestTotals -Store $Ctx.Store -BatchIds $BatchIds
    $out = [ordered]@{ ok = $false; verifiable = $true; manifest_files = $m.files; manifest_bytes = $m.bytes; expected_files = $null; expected_bytes = $null; basis = ''; detail = '' }
    $events = @($Index.global)
    $ref = $null; $blocker = $null
    for ($i = $events.Count - 1; $i -ge 0; $i--) {
        $g = $events[$i]; $s = $g.event['summary']
        if ($g.stage -eq 'Inventory') { $ref = @{ g = $g; files = [long](Get-MigRptValue $s 'files' 0); bytes = [long](Get-MigRptValue $s 'bytes' 0) }; break }
        if ($null -ne (Get-MigRptValue $s 'source_files') -and $null -ne (Get-MigRptValue $s 'source_bytes')) {
            $ref = @{ g = $g; files = [long](Get-MigRptValue $s 'source_files'); bytes = [long](Get-MigRptValue $s 'source_bytes') }; break
        }
        if (-not $blocker -and (Get-MigRptLong $s 'new') + (Get-MigRptLong $s 'changed') -gt 0) { $blocker = $g }
    }
    if (-not $ref) { $out.detail = 'no completed real Inventory run to cross-check against'; return $out }
    if ($blocker) {
        $out.ok = $true; $out.verifiable = $false
        $out.detail = ('not verifiable: Delta run {0} changed the manifests after {1} run {2} and its summary has no source_files/source_bytes totals (manifests: {3} files, {4} bytes)' -f $blocker.event['run_id'], $ref.g.stage, $ref.g.event['run_id'], $m.files, $m.bytes)
        return $out
    }
    $out.basis = '{0} run {1}' -f $ref.g.stage, $ref.g.event['run_id']
    $out.expected_files = $ref.files; $out.expected_bytes = $ref.bytes
    $out.ok = ($out.expected_files -eq $m.files -and $out.expected_bytes -eq $m.bytes)
    $word = 'matches'
    if (-not $out.ok) { $word = 'MISMATCH' }
    $out.detail = ('{0}: manifests {1} files / {2} bytes vs {3}: {4} files / {5} bytes' -f $word, $m.files, $m.bytes, $out.basis, $out.expected_files, $out.expected_bytes)
    return $out
}

function Get-MigRptSidecar {
    <# @{ path; algorithm; hash } of <file>.sha256|.sha384|.sha512, or $null. #>
    param([Parameter(Mandatory = $true)][string] $Path)
    foreach ($a in @('sha256', 'sha384', 'sha512')) {
        $p = $Path + '.' + $a
        if (Test-Path -LiteralPath $p) {
            $h = ''
            try { $h = (([System.IO.File]::ReadAllText($p)).Trim() -split '\s+')[0] } catch { $h = '' }
            return @{ path = $p; algorithm = $a.ToUpperInvariant(); hash = $h }
        }
    }
    return $null
}

function Get-MigRptLogCache {
    <# store/auditcheck.jsonl: verified closed logs, keyed by file name + sidecar hash + length + mtime. #>
    param([Parameter(Mandatory = $true)] $Store)
    return (Get-MigLatestByKey -Records (Read-MigStoreRecords -Store $Store -Name 'auditcheck.jsonl') -Key 'key')
}

function Get-MigRptLogKey {
    param([Parameter(Mandatory = $true)] $File, [Parameter(Mandatory = $true)] $Sidecar)
    return ('{0}|{1}|{2}|{3}' -f $File.Name, $Sidecar.hash, $File.Length, $File.LastWriteTimeUtc.Ticks)
}

function Get-MigRptAuditLogs {
    <#
    Every run-*.jsonl in logDir: chain + checksum sidecar (Test-MigAuditChain). Closed logs already verified with
    the same sidecar hash/length/mtime come from the cache (store/auditcheck.jsonl); new results are added to
    $NewCache. Logs sealed after an interruption are valid but flagged 'interrupted'. The log of the run writing
    this report is still open: it is marked current_run and judged on its hash chain only.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, $Cache, [System.Collections.Generic.List[object]] $NewCache)
    $cfg = $Ctx.Config
    $dir = $cfg._resolved.logDir
    $current = ''
    if ($Ctx.Audit) { $current = [string]$Ctx.Audit.Path }
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return , $out.ToArray() }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'run-*.jsonl' -File | Sort-Object Name)) {
        $isCurrent = [string]::Equals($f.FullName, $current, [StringComparison]::OrdinalIgnoreCase)
        $side = Get-MigRptSidecar -Path $f.FullName
        $row = [ordered]@{ file = $f.Name; current_run = $isCurrent; chain_valid = $false; chained = $null; sidecar = [bool]$side
                           interrupted = $false; lines = 0; algorithm = ''; checksum = ''; cached = $false; error = $null }
        if ($side) { $row.algorithm = $side.algorithm; $row.checksum = $side.hash }
        $key = $null; $hit = $null
        if ($side -and -not $isCurrent) {
            $key = Get-MigRptLogKey -File $f -Sidecar $side
            if ($Cache -and $Cache.TryGetValue($key, [ref]$hit) -and $hit['kind'] -eq 'audit' -and $hit['valid'] -eq $true) {
                $row.chain_valid = $true; $row.chained = $hit['chained']; $row.lines = $hit['lines']; $row.interrupted = [bool]$hit['interrupted']; $row.cached = $true
                $out.Add($row); continue
            }
        }
        try {
            $t = Test-MigAuditChain -Path $f.FullName
            $row.chain_valid = [bool]$t.valid; $row.error = $t.error; $row.lines = $t.lines; $row.chained = $t.chained
            if ($isCurrent -and -not $t.valid -and -not $side -and $t.chained -eq $false) { $row.chain_valid = $true; $row.error = 'current run: not chained and not closed yet' }
            if (-not $isCurrent) { $row.interrupted = ([System.IO.File]::ReadAllText($f.FullName)).Contains('"event":"audit.sealed_after_interruption"') }
        } catch { $row.chain_valid = $false; $row.error = $_.Exception.Message }
        if ($key -and $row.chain_valid -and $null -ne $NewCache) {
            $NewCache.Add([ordered]@{ key = $key; kind = 'audit'; file = $f.Name; valid = $true; chained = $row.chained; lines = $row.lines
                                      interrupted = $row.interrupted; algorithm = $row.algorithm; checksum = $row.checksum; run_id = $Ctx.RunId; ts_utc = Get-MigUtcNow })
        }
        $out.Add($row)
    }
    return , $out.ToArray()
}

function Get-MigRptRobocopyLogs {
    <# <logDir>/robocopy/*.log: each needs a checksum sidecar whose hash matches the file (verified once, then cached). #>
    param([Parameter(Mandatory = $true)] $Ctx, $Cache, [System.Collections.Generic.List[object]] $NewCache)
    $out = New-Object System.Collections.Generic.List[object]
    $dir = Join-Path ([string]$Ctx.Config._resolved.logDir) 'robocopy'
    if (-not (Test-Path -LiteralPath $dir)) { return , $out.ToArray() }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.log' -File | Sort-Object Name)) {
        $side = Get-MigRptSidecar -Path $f.FullName
        $row = [ordered]@{ file = $f.Name; bytes = $f.Length; sidecar = [bool]$side; checksum_ok = $false; algorithm = ''; checksum = ''; cached = $false; error = $null }
        if (-not $side) { $row.error = 'no checksum sidecar'; $out.Add($row); continue }
        $row.algorithm = $side.algorithm; $row.checksum = $side.hash
        $key = Get-MigRptLogKey -File $f -Sidecar $side
        $hit = $null
        if ($Cache -and $Cache.TryGetValue($key, [ref]$hit) -and $hit['kind'] -eq 'robocopy' -and $hit['valid'] -eq $true) { $row.checksum_ok = $true; $row.cached = $true; $out.Add($row); continue }
        try {
            $row.checksum_ok = [string]::Equals((Get-MigFileHash -Path $f.FullName -Algorithm $side.algorithm), [string]$side.hash, [StringComparison]::OrdinalIgnoreCase)
            if (-not $row.checksum_ok) { $row.error = 'file checksum does not match sidecar' }
        } catch { $row.error = $_.Exception.Message }
        if ($row.checksum_ok -and $null -ne $NewCache) {
            $NewCache.Add([ordered]@{ key = $key; kind = 'robocopy'; file = $f.Name; valid = $true; algorithm = $side.algorithm; checksum = $side.hash; run_id = $Ctx.RunId; ts_utc = Get-MigUtcNow })
        }
        $out.Add($row)
    }
    return , $out.ToArray()
}

function Get-MigRptEvidenceManifest {
    <# Checksum of EVERY file under the store dir (lock files excluded), sorted by path. #>
    param([Parameter(Mandatory = $true)] $Ctx)
    $alg = [string](Get-MigRptValue $Ctx.Config.audit 'hashAlgorithm' 'SHA256')
    $root = [string]$Ctx.Store.Root
    $rows = New-Object System.Collections.Generic.List[object]
    $paths = [System.IO.Directory]::GetFiles($root, '*', [System.IO.SearchOption]::AllDirectories)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $locks = (Join-Path $root 'locks') + [System.IO.Path]::DirectorySeparatorChar
    foreach ($p in $paths) {
        if ($p.StartsWith($locks, [StringComparison]::OrdinalIgnoreCase) -or $p.EndsWith('.lock', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $fi = New-Object System.IO.FileInfo($p)
        $rel = $p.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        $sum = ''; $err = $null
        try { $sum = Get-MigFileHash -Path $p -Algorithm $alg } catch { $err = $_.Exception.Message }
        $rows.Add([ordered]@{ path = $rel; bytes = $fi.Length; modified_utc = $fi.LastWriteTimeUtc.ToString('o'); algorithm = $alg; checksum = $sum; error = $err })
    }
    return , $rows.ToArray()
}

function Get-MigRptManifestChecksums {
    <#
    Rows from <store>/manifest.checksums.jsonl (C-01 evidence written by Inventory, passed through as recorded)
    plus the current checksum of every manifest file in the store.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [string[]] $BatchIds)
    $alg = [string](Get-MigRptValue $Ctx.Config.audit 'hashAlgorithm' 'SHA256')
    $rows = New-Object System.Collections.Generic.List[object]
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($b in @($BatchIds)) { [void]$wanted.Add($b) }
    foreach ($r in (Read-MigStoreRecords -Store $Ctx.Store -Name 'manifest.checksums.jsonl')) {
        $b = [string](Get-MigRptValue $r 'batch_id' '')
        if ($BatchIds -and $b -and -not $wanted.Contains($b)) { continue }
        $file = Get-MigRptValue $r 'file' (Get-MigRptValue $r 'path' (Get-MigRptValue $r 'name' ''))
        $hash = Get-MigRptValue $r 'hash' (Get-MigRptValue $r 'sha256' (Get-MigRptValue $r 'checksum' ''))
        $ralg = Get-MigRptValue $r 'algorithm' (Get-MigRptValue $r 'hash_algo' '')
        if (-not $ralg -and $r['sha256']) { $ralg = 'SHA256' }
        $rows.Add([ordered]@{ origin = 'recorded'; batch_id = $b; file = $file; checksum = $hash; algorithm = $ralg; ts_utc = Get-MigRptValue $r 'ts_utc' '' })
    }
    foreach ($b in @($BatchIds)) {
        foreach ($side in @('source', 'target')) {
            $p = Join-Path (Get-MigRptBatchDir -Store $Ctx.Store -BatchId $b) "$side.manifest.jsonl"
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $rows.Add([ordered]@{ origin = 'current'; batch_id = $b; file = "batches/$b/$side.manifest.jsonl"
                checksum = (Get-MigFileHash -Path $p -Algorithm $alg); algorithm = $alg; ts_utc = Get-MigUtcNow })
        }
    }
    return , $rows.ToArray()
}

# ---- Governance (final report) --------------------------------------------------------------------------

function Get-MigRptGovernance {
    <# Sign-off (3 roles, missing = pending), latest freeze record, retention records, gate overrides. #>
    param([Parameter(Mandatory = $true)] $Ctx, [AllowEmptyCollection()][object[]] $Gates)
    $store = $Ctx.Store
    $sign = @(Read-MigStoreRecords -Store $store -Name 'signoff.jsonl')
    $signRows = New-Object System.Collections.Generic.List[object]
    foreach ($role in $script:MigRptSignOffRoles) {
        $last = $null
        foreach ($s in $sign) { if ([string]$s['role'] -eq $role) { $last = $s } }
        if ($last) {
            $signRows.Add([ordered]@{ role = $role; status = 'signed'; signer = $last['signer']; report_run_id = $last['report_run_id']; comment = $last['comment']; ts_utc = $last['ts_utc'] })
        } else {
            $signRows.Add([ordered]@{ role = $role; status = 'pending'; signer = ''; report_run_id = ''; comment = ''; ts_utc = '' })
        }
    }
    $freeze = @(Read-MigStoreRecords -Store $store -Name 'freeze.jsonl')
    $freezeRows = New-Object System.Collections.Generic.List[object]
    if ($freeze.Count -gt 0) {
        $f = $freeze[$freeze.Count - 1]
        $freezeRows.Add([ordered]@{ frozen = [bool]$f['frozen']; recorded_by = $f['recorded_by']; ts_utc = $f['ts_utc']; source_root = $f['source_root']
                                    sddl_hash = $f['sddl_hash']; violations = $f['violations']; comment = $f['comment'] })
    } else {
        $freezeRows.Add([ordered]@{ frozen = 'not recorded'; recorded_by = ''; ts_utc = ''; source_root = ''; sddl_hash = ''; violations = ''; comment = 'Register-MigrationFreeze has not been run' })
    }
    $retention = @(Read-MigStoreRecords -Store $store -Name 'retention.jsonl')
    $overrides = @($Gates | Where-Object { $_['override'] -eq $true })
    return @{ signoff = $signRows.ToArray(); freeze = $freezeRows.ToArray(); retention = $retention; overrides = $overrides }
}

function Invoke-MigRptTargetSweep {
    <# report.finalTargetSweep: Find-MigTargetOrphans (Verify stage) if it exists. Returns its result or $null. #>
    param([Parameter(Mandatory = $true)] $Ctx)
    if (-not [bool](Get-MigValue $Ctx.Config.report 'finalTargetSweep' $true)) { return $null }
    $cmd = Get-Command -Name 'Find-MigTargetOrphans' -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $r = & $cmd -Ctx $Ctx
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'report.target_sweep' -Data ([ordered]@{
        scanned = Get-MigRptValue $r 'scanned' 0; orphans = @(Get-MigRptValue $r 'orphans' @()).Count; sample = @(@(Get-MigRptValue $r 'orphans' @()) | Select-Object -First 50) })
    return $r
}

# ---- Pilot estimate ---------------------------------------------------------------------------------------

function Format-MigRptDuration {
    param([double] $Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Ceiling($Seconds))
    return ('{0}d {1:00}h {2:00}m {3:00}s' -f [int][Math]::Floor($ts.TotalDays), $ts.Hours, $ts.Minutes, $ts.Seconds)
}

function Get-MigRptPilotEstimate {
    <#
    Throughput of completed real Copy runs (summary files_copied / bytes_copied over elapsed_sec) applied to the
    planned files/bytes of batches with no completed real Copy yet. The slower of the file-rate and byte-rate
    estimates is used.
    #>
    param([Parameter(Mandatory = $true)] $Index, [AllowEmptyCollection()][string[]] $BatchIds, $Infos)
    $runs = 0; $files = [long]0; $bytes = [long]0; $secs = 0.0; $bytesRuns = 0
    foreach ($e in $Index.records) {
        if ($e['stage'] -ne 'Copy' -or $e['state'] -ne 'completed' -or $e['dry_run'] -eq $true) { continue }
        $s = $e['summary']
        if ($null -eq $s -or (Get-MigRptValue $s 'nothing_to_do' $false) -eq $true) { continue }
        $el = [double](Get-MigRptValue $s 'elapsed_sec' 0)
        $fc = [long](Get-MigRptValue $s 'files_copied' 0)
        if ($el -le 0 -or $fc -le 0) { continue }
        $runs++; $files += $fc; $secs += $el
        $bc = Get-MigRptValue $s 'bytes_copied' (Get-MigRptValue $s 'bytes')
        if ($null -ne $bc) { $bytes += [long]$bc; $bytesRuns++ }
    }
    $remBatches = 0; $remFiles = [long]0; $remBytes = [long]0
    foreach ($b in $BatchIds) {
        if (Get-MigRptLatestRun -Index $Index -Stage 'Copy' -Scope $b) { continue }
        $info = $null
        if ($Infos.ContainsKey($b)) { $info = $Infos[$b] }
        $plan = Get-MigRptValue $info 'plan'
        $remBatches++; $remFiles += Get-MigRptLong $plan 'file_count'; $remBytes += Get-MigRptLong $plan 'total_bytes'
    }
    $est = $null; $estText = 'no throughput data yet'
    $fps = $null; $bps = $null
    if ($runs -gt 0 -and $secs -gt 0) {
        $fps = $files / $secs
        $est = $remFiles / $fps
        if ($bytesRuns -eq $runs -and $bytes -gt 0) { $bps = $bytes / $secs; $est = [Math]::Max($est, $remBytes / $bps) }
        $estText = Format-MigRptDuration $est
    }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $rows = @(
        [ordered]@{ metric = 'copy_runs_measured'; value = $runs }
        [ordered]@{ metric = 'files_copied'; value = $files }
        [ordered]@{ metric = 'bytes_copied'; value = $(if ($bytesRuns -gt 0) { $bytes } else { 'not reported by Copy' }) }
        [ordered]@{ metric = 'copy_elapsed_sec'; value = [Math]::Round($secs, 1) }
        [ordered]@{ metric = 'files_per_sec'; value = $(if ($null -ne $fps) { $fps.ToString('0.##', $inv) } else { '' }) }
        [ordered]@{ metric = 'mb_per_sec'; value = $(if ($null -ne $bps) { ($bps / 1MB).ToString('0.##', $inv) } else { '' }) }
        [ordered]@{ metric = 'batches_not_copied'; value = $remBatches }
        [ordered]@{ metric = 'remaining_files'; value = $remFiles }
        [ordered]@{ metric = 'remaining_bytes'; value = $remBytes }
        [ordered]@{ metric = 'estimated_remaining_duration'; value = $estText }
    )
    return @{ rows = $rows; estimate_sec = $est; text = $estText; has_data = ($null -ne $est) }
}

# ---- Acceptance criteria ----------------------------------------------------------------------------------

function Get-MigRptAcceptance {
    <# The spec's acceptance criteria, each evaluated true/false with the evidence behind it. #>
    param([Parameter(Mandatory = $true)] $Ctx, [AllowEmptyCollection()][object[]] $Batches, $Totals, $CrossCheck, $Extras,
          [int] $OpenOther, [AllowEmptyCollection()][object[]] $AuditLogs, [AllowEmptyCollection()][object[]] $RobocopyLogs, $Evidence)
    $cfg = $Ctx.Config
    $all = @($Batches)
    $any = ($all.Count -gt 0)
    $crit = New-Object System.Collections.Generic.List[object]
    $notPassed = @(foreach ($b in $all) { if (-not $b.verdict.passed) { '{0} [{1}]' -f $b.id, ($b.verdict.reasons -join '; ') } })
    $notPassedIds = @(foreach ($b in $all) { if (-not $b.verdict.passed) { $b.id } })
    $fields = 'compared fields: files [{0}], dirs [{1}]' -f (@($cfg.compare.fileFields) -join ', '), (@($cfg.compare.dirFields) -join ', ')
    $noBatches = ''
    if (-not $any) { $noBatches = 'no batches; ' }

    # Extras covered by an ACCEPTED extra_on_target exception stay on the target (never deleted): excluded from the
    # comparison and listed. Unaccepted extras still count.
    $accPaths = New-Object System.Collections.Generic.List[string]
    foreach ($b in $all) { foreach ($p in $b.accepted_extras.paths) { $accPaths.Add([string]$p) } }
    $accNote = ''
    if ($accPaths.Count -gt 0) { $accNote = ' (+{0} accepted extra: {1})' -f $accPaths.Count, (Join-MigRptList $accPaths.ToArray()) }
    $tgtFiles = $Totals.target_files - $Totals.accepted_extra_files
    $tgtBytes = $Totals.target_bytes - $Totals.accepted_extra_bytes

    $countBad = @(foreach ($b in $all) { if ($b.reconciled -and (Get-MigRptLong $b.reconcile 'source_files') -ne ((Get-MigRptLong $b.reconcile 'target_files') - $b.accepted_extras.files)) { $b.id } })
    $ok = $any -and $notPassed.Count -eq 0 -and $countBad.Count -eq 0 -and $Totals.source_files -eq $tgtFiles -and $CrossCheck.ok
    $crit.Add([ordered]@{ id = 'AC-1'; criterion = 'Source file count = target file count, per batch and overall'; passed = $ok
        detail = ('{0}overall {1} / {2}{3}; batches differing: {4}; batches not passed: {5}; inventory cross-check: {6}' -f $noBatches, $Totals.source_files, $tgtFiles, $accNote,
            (Join-MigRptList $countBad), (Join-MigRptList $notPassed -Separator ' | '), $CrossCheck.detail) })

    $bytesBad = @(foreach ($b in $all) { if ($b.reconciled -and (Get-MigRptLong $b.reconcile 'source_bytes') -ne ((Get-MigRptLong $b.reconcile 'target_bytes') - $b.accepted_extras.bytes)) { $b.id } })
    $ok = $any -and $notPassed.Count -eq 0 -and $bytesBad.Count -eq 0 -and $Totals.source_bytes -eq $tgtBytes -and $CrossCheck.ok
    $crit.Add([ordered]@{ id = 'AC-2'; criterion = 'Source total bytes = target total bytes'; passed = $ok
        detail = ('{0}overall {1} / {2} bytes{3}; batches differing: {4}; batches not passed: {5}' -f $noBatches, $Totals.source_bytes, $tgtBytes, $accNote, (Join-MigRptList $bytesBad), (Join-MigRptList $notPassedIds)) })

    $extraOpen = $Totals.extra - $Totals.extra_accepted
    $ok = $any -and $notPassed.Count -eq 0 -and $Totals.hash_mismatch -eq 0 -and $Totals.size_mismatch -eq 0 -and $Totals.missing -eq 0 -and $extraOpen -eq 0 -and $Totals.scan_errors -eq 0 -and $Extras.count -eq 0
    $crit.Add([ordered]@{ id = 'AC-3'; criterion = '100% SHA-256 match; zero missing, zero extra'; passed = $ok
        detail = ('{0}hash mismatch {1}, size mismatch {2}, missing {3}, extra {4}{5}, extra outside every batch {6} ({7}), scan errors {8}; batches not passed: {9}; {10}' -f $noBatches,
            $Totals.hash_mismatch, $Totals.size_mismatch, $Totals.missing, $extraOpen, $accNote, $Extras.count, $Extras.detail, $Totals.scan_errors, (Join-MigRptList $notPassedIds), $fields) })

    $metaTotal = 0; $metaCovered = 0; $metaBad = New-Object System.Collections.Generic.List[string]
    foreach ($b in $all) {
        $metaTotal += $b.metadata.total; $metaCovered += $b.metadata.covered
        if ($b.metadata.uncovered -gt 0) { $metaBad.Add(('{0} ({1}: {2})' -f $b.id, $b.metadata.uncovered, ($b.metadata.sample -join ', '))) }
    }
    $ok = $any -and $notPassed.Count -eq 0 -and $metaBad.Count -eq 0
    $crit.Add([ordered]@{ id = 'AC-4'; criterion = 'Timestamps, attributes and ACLs match (or approved exceptions)'; passed = $ok
        detail = ('{0}metadata mismatches {1}; covered by accepted exceptions {2}; not covered: {3}; batches not passed: {4}; {5}' -f $noBatches, $metaTotal, $metaCovered,
            (Join-MigRptList $metaBad.ToArray() -Separator ' | '), (Join-MigRptList $notPassedIds), $fields) })

    $htmlBad = @(foreach ($b in $all) { if (-not $b.html_verdict.passed) { '{0} [{1}]' -f $b.id, ($b.html_verdict.reasons -join '; ') } })
    $overrides = @(foreach ($b in $all) { if ($b.html_verdict.override) { $b.id } })
    $ok = $any -and $htmlBad.Count -eq 0
    $crit.Add([ordered]@{ id = 'AC-5'; criterion = 'HTML checks run; all findings reviewed'; passed = $ok
        detail = ('{0}batches failing: {1}; parity accepted by approved override: {2}' -f $noBatches, (Join-MigRptList $htmlBad -Separator ' | '), (Join-MigRptList $overrides)) })

    $open = $Totals.exceptions_open + $OpenOther
    $crit.Add([ordered]@{ id = 'AC-6'; criterion = 'Exception register closed'; passed = ($open -eq 0)
        detail = ('{0} open exception(s) ({1} in batches, {2} orphans/legacy) of {3}' -f $open, $Totals.exceptions_open, $OpenOther, ($Totals.exceptions_total + $Extras.exceptions_total)) })

    $closedLogs = @($AuditLogs | Where-Object { -not $_.current_run })
    $badLogs = @(foreach ($l in $closedLogs) { if (-not $l.chain_valid -or -not $l.sidecar) { '{0} ({1})' -f $l.file, $(if ($l.error) { $l.error } else { 'no checksum sidecar' }) } })
    $curBad = @(foreach ($l in $AuditLogs) { if ($l.current_run -and -not $l.chain_valid) { '{0} ({1})' -f $l.file, $l.error } })
    $interrupted = @(foreach ($l in $AuditLogs) { if ($l.interrupted) { $l.file } })
    $rcBad = @(foreach ($l in $RobocopyLogs) { if (-not $l.sidecar -or -not $l.checksum_ok) { '{0} ({1})' -f $l.file, $l.error } })
    $cachedN = @($AuditLogs | Where-Object { $_.cached }).Count
    $ok = (@($AuditLogs).Count -gt 0) -and $badLogs.Count -eq 0 -and $curBad.Count -eq 0 -and $rcBad.Count -eq 0 -and $Evidence.ok
    $crit.Add([ordered]@{ id = 'AC-7'; criterion = 'Final report and logs archived with checksums'; passed = $ok
        detail = ('{0} audit logs ({1} verified earlier, from cache); invalid or without checksum: {2}; interrupted runs (sealed, valid): {3}; {4} robocopy logs, without valid sidecar: {5}; evidence manifest: {6}. Report files are written with checksum sidecars.' -f
            @($AuditLogs).Count, $cachedN, (Join-MigRptList (@($badLogs) + @($curBad)) -Separator ' | '), (Join-MigRptList $interrupted), @($RobocopyLogs).Count, (Join-MigRptList $rcBad -Separator ' | '), $Evidence.detail) })
    return , $crit.ToArray()
}

# ---- Report object -----------------------------------------------------------------------------------------

function New-MigReportObject {
    param([Parameter(Mandatory = $true)] $Ctx, [string] $BatchId, [switch] $Final)
    $cfg = $Ctx.Config
    $store = $Ctx.Store
    $rcfg = $cfg.report
    $infos = Get-MigBatches -Store $store
    $folders = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in (Get-MigBatchIds -Store $store)) { [void]$folders.Add($f) }
    $idSet = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $infos.Keys) { [void]$idSet.Add($k) }
    foreach ($k in $folders) { [void]$idSet.Add($k) }
    [void]$idSet.Remove($script:MigRptOrphanBatch)
    if ($BatchId) {
        Assert-MigBatchId $BatchId
        if (-not $idSet.Contains($BatchId)) { throw "Report: unknown batch '$BatchId'. Run Batching first." }
        $ids = @($BatchId)
    } else {
        $ids = @($idSet)
    }
    $events = @(Read-MigStoreRecords -Store $store -Name 'stages.jsonl')
    $index = New-MigRptStageIndex -Records $events
    $gates = @(Read-MigStoreRecords -Store $store -Name 'gates.jsonl')
    $gateIndex = New-MigRptGateIndex -Gates $gates

    $progressed = $false
    foreach ($id in $ids) {
        if (-not $infos.ContainsKey($id)) { continue }
        $i = $infos[$id]
        if ((Get-MigRptValue $i 'copy') -or (Get-MigRptValue $i 'verify') -or (Get-MigRptValue $i 'reconcile') -or (Get-MigRptValue $i 'htmlChecks')) { $progressed = $true; break }
    }
    if (-not $progressed) { $kind = 'plan' } elseif ($Final) { $kind = 'final' } elseif ($BatchId) { $kind = 'batch' } else { $kind = 'summary' }
    $isFinal = ($kind -eq 'final')
    $details = (-not $isFinal) -or [bool](Get-MigValue $rcfg 'finalIncludeDetails' $false)

    # Extras outside every batch: swept now (real -Final) so AC-3 counts them.
    $sweep = $null
    if ($isFinal -and -not $Ctx.DryRun) { $sweep = Invoke-MigRptTargetSweep -Ctx $Ctx }

    $batches = New-Object System.Collections.Generic.List[object]
    $issues = New-Object System.Collections.Generic.List[object]
    $findings = New-Object System.Collections.Generic.List[object]
    $parity = New-Object System.Collections.Generic.List[object]
    $exceptions = New-Object System.Collections.Generic.List[object]
    foreach ($id in $ids) {
        $info = $null
        if ($infos.ContainsKey($id)) { $info = $infos[$id] }
        $b = Get-MigRptBatchData -Ctx $Ctx -BatchId $id -Info $info -Planned ($infos.ContainsKey($id)) -HasFolder ($folders.Contains($id)) -Index $index `
            -GateIndex $gateIndex -Details:$details -Evaluate:($kind -ne 'plan')
        $batches.Add($b)
        if ($details) {
            $issues.AddRange([object[]]@($b.issues)); $findings.AddRange([object[]]@($b.findings)); $parity.AddRange([object[]]@($b.parity))
            $exceptions.AddRange([object[]]$b.ex.rows.ToArray())
        }
    }

    # Orphans (target entries outside every batch) and the legacy global exception file.
    $orphanRows = @(); $orphanOpen = 0; $orphanTotal = 0; $legacyOpen = 0
    $orphanStats = Get-MigRptExceptionStats -Store $store -BatchId $script:MigRptOrphanBatch -HasFolder ($folders.Contains($script:MigRptOrphanBatch) -or (Test-Path -LiteralPath (Get-MigRptBatchDir -Store $store -BatchId $script:MigRptOrphanBatch))) -KeepRows
    $orphanRows = $orphanStats.rows.ToArray(); $orphanOpen = $orphanStats.open; $orphanTotal = $orphanStats.total
    if (-not $BatchId) {
        foreach ($e in (Get-MigLatestByKey -Records (Read-MigStoreRecords -Store $store -Name 'exceptions.jsonl') -Key 'id').Values) { if ($e['status'] -eq 'open') { $legacyOpen++ } }
    }
    $extras = @{ count = 0; detail = ''; exceptions_total = $orphanTotal }
    if ($sweep) {
        $unaccepted = @(foreach ($p in @(Get-MigRptValue $sweep 'orphans' @())) {
            if (-not $orphanStats.accepted.Contains((Get-MigExceptionFingerprint -BatchId $script:MigRptOrphanBatch -RelPath ([string]$p) -Category 'extra_on_target'))) { $p } })
        $extras.count = $unaccepted.Count
        $extras.detail = ('target sweep this run: {0} scanned, {1} orphan(s), {2} not accepted' -f (Get-MigRptValue $sweep 'scanned' 0), @(Get-MigRptValue $sweep 'orphans' @()).Count, $unaccepted.Count)
    } else {
        $extras.count = @($orphanRows | Where-Object { $_['status'] -eq 'open' -and $_['category'] -eq 'extra_on_target' }).Count
        $extras.detail = 'no target sweep this run; open ORPHANS extra_on_target exceptions'
    }

    $sumKeys = @('planned_files', 'planned_dirs', 'planned_bytes', 'zero_byte_files', 'plan_errors', 'files_copied', 'files_copy_failed',
        'verified_files', 'verified_bytes', 'source_files', 'target_files', 'source_bytes', 'target_bytes', 'source_dirs', 'target_dirs',
        'missing', 'extra', 'extra_accepted', 'accepted_extra_files', 'accepted_extra_bytes', 'size_mismatch', 'hash_mismatch', 'metadata_mismatch', 'scan_errors',
        'html_source_findings', 'html_target_findings', 'html_parity_differences', 'exceptions_total', 'exceptions_open')
    $totals = [ordered]@{ batches = $batches.Count }
    foreach ($k in $sumKeys) { $totals[$k] = [long]0 }
    foreach ($b in $batches) { foreach ($k in $sumKeys) { $totals[$k] += [long](Get-MigRptValue $b.row $k 0) } }
    $totals['batches_reconciled'] = @($batches | Where-Object { $_.reconciled }).Count
    $totals['batches_passed'] = @($batches | Where-Object { $_.verdict -and $_.verdict.passed }).Count
    $totals['batches_html_checked'] = @($batches | Where-Object { $_.html }).Count
    $totals['extra_outside_batches'] = $extras.count
    $totals['orphan_exceptions_open'] = $orphanOpen

    # Counts come from batch info (every report kind), so the final report never loads per-file issues.
    $byCat = [ordered]@{ missing = [long]0; extra = [long]0; size_mismatch = [long]0; hash_mismatch = [long]0; metadata_mismatch = [long]0; scan_error = [long]0 }
    foreach ($b in $batches) {
        foreach ($c in @('missing', 'extra', 'size_mismatch', 'hash_mismatch', 'metadata_mismatch')) { $byCat[$c] += Get-MigRptLong $b.reconcile $c }
        $byCat['scan_error'] += Get-MigRptLong $b.reconcile 'scan_errors'
    }
    $catRows = @(foreach ($c in $byCat.Keys) { [ordered]@{ category = $c; count = $byCat[$c] } })

    $ruleRows = [ordered]@{}
    if ($details) {
        foreach ($f in $findings) {
            $r = [string]$f['rule']
            if (-not $ruleRows.Contains($r)) { $ruleRows[$r] = [ordered]@{ rule = $r; source = 0; target = 0; errors = 0; warnings = 0; info = 0; parity_differences = 0 } }
            if ($f['side'] -eq 'target') { $ruleRows[$r].target++ } else { $ruleRows[$r].source++ }
            switch ([string]$f['severity']) { 'error' { $ruleRows[$r].errors++ } 'warning' { $ruleRows[$r].warnings++ } default { $ruleRows[$r].info++ } }
        }
        foreach ($p in $parity) {
            $r = [string]$p['rule']
            if (-not $ruleRows.Contains($r)) { $ruleRows[$r] = [ordered]@{ rule = $r; source = 0; target = 0; errors = 0; warnings = 0; info = 0; parity_differences = 0 } }
            $ruleRows[$r].parity_differences++
        }
    } else {
        foreach ($b in $batches) {
            foreach ($side in @('source', 'target')) {
                $by = Get-MigRptValue $b.html ('by_rule_' + $side)
                if (-not ($by -is [System.Collections.IDictionary])) { continue }
                foreach ($r in @($by.Keys)) {
                    if (-not $ruleRows.Contains($r)) { $ruleRows[$r] = [ordered]@{ rule = $r; source = 0; target = 0; errors = $null; warnings = $null; info = $null; parity_differences = $null } }
                    $ruleRows[$r][$side] += [long]$by[$r]
                }
            }
        }
    }
    $ruleTable = @(foreach ($k in @($ruleRows.Keys | Sort-Object)) { $ruleRows[$k] })

    $exStatus = [ordered]@{ open = 0; resolved = 0; accepted = 0 }
    $exSummary = New-Object System.Collections.Generic.List[object]
    foreach ($b in $batches) {
        foreach ($kv in $b.ex.by_cat_status.GetEnumerator()) {
            $parts = $kv.Key.Split('|')
            $st = $parts[1]
            if (-not $exStatus.Contains($st)) { $exStatus[$st] = 0 }
            $exStatus[$st] += $kv.Value
            $exSummary.Add([ordered]@{ batch_id = $b.id; category = $parts[0]; status = $st; count = $kv.Value })
        }
    }

    $acceptance = @(); $auditLogs = @(); $robocopyLogs = @(); $manifestSums = @(); $evidenceRows = @(); $governance = $null; $cross = $null
    $estimate = $null
    if ($kind -eq 'plan' -or $isFinal) { $estimate = Get-MigRptPilotEstimate -Index $index -BatchIds $ids -Infos $infos }
    if ($isFinal) {
        $cache = Get-MigRptLogCache -Store $store
        $newCache = New-Object System.Collections.Generic.List[object]
        $auditLogs = Get-MigRptAuditLogs -Ctx $Ctx -Cache $cache -NewCache $newCache
        $robocopyLogs = Get-MigRptRobocopyLogs -Ctx $Ctx -Cache $cache -NewCache $newCache
        if ($newCache.Count -gt 0 -and -not $Ctx.DryRun) { Add-MigStoreRecords -Store $store -Name 'auditcheck.jsonl' -Records $newCache.ToArray() }
        $manifestSums = Get-MigRptManifestChecksums -Ctx $Ctx -BatchIds $ids
        $cross = Get-MigRptInventoryCrossCheck -Ctx $Ctx -BatchIds $ids -Index $index
        $governance = Get-MigRptGovernance -Ctx $Ctx -Gates $gates
        $evidenceRows = Get-MigRptEvidenceManifest -Ctx $Ctx
        $evBad = @($evidenceRows | Where-Object { $_['error'] }).Count
        $evidence = @{ ok = ($evidenceRows.Count -gt 0 -and $evBad -eq 0); detail = ('{0} store files checksummed into evidence.manifest.csv, {1} unreadable' -f $evidenceRows.Count, $evBad) }
        $acceptance = Get-MigRptAcceptance -Ctx $Ctx -Batches $batches.ToArray() -Totals $totals -CrossCheck $cross -Extras $extras -OpenOther ($orphanOpen + $legacyOpen) `
            -AuditLogs $auditLogs -RobocopyLogs $robocopyLogs -Evidence $evidence
    }

    switch ($kind) {
        'plan' { $status = 'PLAN'; $passed = $null }
        'final' { $passed = (@($acceptance | Where-Object { -not $_.passed }).Count -eq 0); if ($passed) { $status = 'PASS' } else { $status = 'FAIL' } }
        default {
            $open = [long]$totals.exceptions_open
            if (@($batches | Where-Object { -not $_.reconciled -or [string](Get-MigRptValue $_.info 'state' '') -ne 'reconciled' }).Count -gt 0) { $status = 'INCOMPLETE'; $passed = $false }
            else {
                $bad = @($batches | Where-Object { -not $_.verdict.passed -or ($_.html -and $_.row.html_parity -eq $false -and -not $_.html_verdict.override) }).Count
                $passed = ($bad -eq 0 -and $open -eq 0)
                if ($passed) { $status = 'PASS' } else { $status = 'FAIL' }
            }
        }
    }

    $titles = @{ plan = 'Migration plan (dry run / plan only)'; final = 'Final reconciliation report'; batch = "Batch reconciliation report: $BatchId"; summary = 'Reconciliation summary (all batches)' }
    $summaryCols = @('batch_id', 'state')
    if ($batches.Count -gt 0) { $summaryCols = @($batches[0].row.Keys) }
    $batchRows = @(foreach ($b in $batches) { $b.row })
    $tables = [ordered]@{}
    if ($isFinal) { $tables['acceptance'] = New-MigRptTable -Title 'Acceptance criteria' -Columns @('id', 'criterion', 'passed', 'detail') -Rows $acceptance }
    $tables['summary'] = New-MigRptTable -Title 'Batches' -Columns $summaryCols -Rows $batchRows
    if ($estimate) { $tables['pilot_estimate'] = New-MigRptTable -Title 'Pilot estimate (throughput of completed Copy runs)' -Columns @('metric', 'value') -Rows $estimate.rows }
    if ($isFinal) {
        $tables['signoff'] = New-MigRptTable -Title 'Sign-off' -Columns @('role', 'status', 'signer', 'report_run_id', 'comment', 'ts_utc') -Rows $governance.signoff
        $tables['freeze'] = New-MigRptTable -Title 'Source freeze record (latest)' -Columns @('frozen', 'recorded_by', 'ts_utc', 'source_root', 'sddl_hash', 'violations', 'comment') -Rows $governance.freeze
        $tables['retention'] = New-MigRptTable -Title 'Retention' -Columns @('ticket', 'retain_until', 'recorded_by', 'comment', 'ts_utc') -Rows $governance.retention
        $tables['gate_overrides'] = New-MigRptTable -Title 'Gate overrides (approved despite a failed run)' -Columns @('stage', 'scope', 'run_id', 'maker', 'checker', 'decision', 'comment', 'ts_utc') -Rows $governance.overrides
        $tables['orphans'] = New-MigRptTable -Title 'Orphans (target entries outside every batch)' -Columns @('id', 'rel_path', 'category', 'status', 'owner', 'detail', 'resolution', 'updated_by', 'ts_utc') -Rows $orphanRows
    }
    $tables['mismatches_by_category'] = New-MigRptTable -Title 'Mismatches by category' -Columns @('category', 'count') -Rows $catRows
    if ($details) {
        $tables['issues'] = New-MigRptTable -Title 'Reconciliation issues' -Columns @('batch_id', 'category', 'rel_path', 'kind', 'field', 'source_value', 'target_value', 'detail', 'run_id', 'ts_utc') -Rows $issues.ToArray()
        $tables['exceptions'] = New-MigRptTable -Title 'Exception register' -Columns @('id', 'batch_id', 'category', 'rel_path', 'status', 'owner', 'detail', 'resolution', 'updated_by', 'opened_utc', 'ts_utc', 'run_id') -Rows $exceptions.ToArray()
    } else {
        $tables['exceptions_summary'] = New-MigRptTable -Title 'Exception register by batch (per-file detail in the batch reports)' -Columns @('batch_id', 'category', 'status', 'count') -Rows $exSummary.ToArray()
    }
    $tables['html_findings_by_rule'] = New-MigRptTable -Title 'HTML findings by rule' -Columns @('rule', 'source', 'target', 'errors', 'warnings', 'info', 'parity_differences') -Rows $ruleTable
    if ($details) {
        $tables['html_findings'] = New-MigRptTable -Title 'HTML findings' -Columns @('batch_id', 'side', 'rule', 'severity', 'code', 'rel_path', 'detail', 'side_specific', 'run_id') -Rows $findings.ToArray()
        $tables['html_parity'] = New-MigRptTable -Title 'HTML source/target parity differences' -Columns @('batch_id', 'rule', 'rel_path', 'only_on', 'detail', 'run_id') -Rows $parity.ToArray()
    }
    $gateRows = $gates
    if ($BatchId) { $gateRows = @($gates | Where-Object { [string]$_['scope'] -eq $BatchId }) }
    $tables['gates'] = New-MigRptTable -Title 'Gate decisions (maker-checker)' -Columns @('stage', 'scope', 'run_id', 'maker', 'checker', 'decision', 'override', 'comment', 'ts_utc') -Rows $gateRows
    if ($isFinal) {
        $tables['audit_logs'] = New-MigRptTable -Title 'Audit logs (hash chain + checksum)' -Columns @('file', 'current_run', 'chain_valid', 'chained', 'sidecar', 'interrupted', 'lines', 'algorithm', 'checksum', 'cached', 'error') -Rows $auditLogs
        $tables['robocopy_logs'] = New-MigRptTable -Title 'Robocopy logs (checksum sidecars)' -Columns @('file', 'bytes', 'sidecar', 'checksum_ok', 'algorithm', 'checksum', 'cached', 'error') -Rows $robocopyLogs
        $tables['manifest_checksums'] = New-MigRptTable -Title 'Manifest checksums' -Columns @('origin', 'batch_id', 'file', 'algorithm', 'checksum', 'ts_utc') -Rows $manifestSums
        $tables['evidence_manifest'] = New-MigRptTable -Title 'Evidence manifest (checksum of every store file)' -Columns @('path', 'bytes', 'modified_utc', 'algorithm', 'checksum', 'error') -Rows $evidenceRows -CsvName 'evidence.manifest.csv' -ExternalCsv
    }

    $obj = [ordered]@{
        report_type = $kind; title = $titles[$kind]; status = $status; passed = $passed; final = $isFinal
        batch_id = $BatchId; generated_utc = Get-MigUtcNow; run_id = $Ctx.RunId; operator = $Ctx.Operator
        host = [Environment]::MachineName; dry_run = [bool]$Ctx.DryRun; module_version = $script:MigModuleVersion
        config_path = $cfg._meta.configPath; config_hash = $cfg._meta.configHash
        source_root = $cfg.paths.sourceRoot; target_root = $cfg.paths.targetRoot
        details_included = $details
        totals = $totals; mismatches_by_category = $byCat; exceptions_by_status = $exStatus
        tables = $tables
    }
    if ($estimate) { $obj['pilot_estimate'] = $estimate.text }
    if ($cross) { $obj['inventory_cross_check'] = $cross }
    return $obj
}

function Write-MigRptSidecar {
    <# Writes <file>.<alg> ('<hash>  <name>') and returns its path. #>
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Algorithm)
    $h = Get-MigFileHash -Path $Path -Algorithm $Algorithm
    $side = $Path + '.' + $Algorithm.ToLowerInvariant()
    [System.IO.File]::WriteAllText($side, ('{0}  {1}' -f $h, [System.IO.Path]::GetFileName($Path)) + "`n")
    return $side
}

function Invoke-MigStageReport {
    param([Parameter(Mandatory = $true)] $Ctx, [string] $BatchId, [switch] $Final)
    $cfg = $Ctx.Config
    $report = New-MigReportObject -Ctx $Ctx -BatchId $BatchId -Final:$Final

    $reportDir = $cfg._resolved.reportDir
    if ([string]::IsNullOrWhiteSpace($reportDir)) { throw 'Report: paths.reportDir is not configured.' }
    switch ($report.report_type) {
        'batch' { $base = "batch-$BatchId" }
        'plan' { if ($BatchId) { $base = "plan-$BatchId" } else { $base = 'plan' } }
        'final' { $base = 'final' }
        default { $base = 'summary' }
    }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $outDir = Join-Path $reportDir ('{0}-{1}' -f $base, $stamp)
    if (Test-Path -LiteralPath $outDir) { $outDir = '{0}-{1}' -f $outDir, $Ctx.RunId }
    Assert-MigPathNotUnderSource -Path $outDir -SourceRoot $cfg.paths.sourceRoot
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $alg = [string](Get-MigRptValue $cfg.audit 'hashAlgorithm' 'SHA256')
    $written = New-Object System.Collections.Generic.List[string]
    foreach ($fmt in @($cfg.report.formats)) {
        $sb = Get-MigProvider -Kind Report -Name ([string]$fmt)
        foreach ($p in @(& $sb $Ctx $report $outDir $base)) {
            if (-not $p) { continue }
            Assert-MigPathNotUnderSource -Path $p -SourceRoot $cfg.paths.sourceRoot
            $written.Add($p); $written.Add((Write-MigRptSidecar -Path $p -Algorithm $alg))
        }
    }
    # Tables whose CSV the stage owns (evidence manifest): written whatever report.formats says.
    foreach ($name in @($report.tables.Keys)) {
        $t = $report.tables[$name]
        if (-not (Get-MigRptValue $t 'external_csv' $false)) { continue }
        $p = Join-Path $outDir ([string]$t['csv_name'])
        Assert-MigPathNotUnderSource -Path $p -SourceRoot $cfg.paths.sourceRoot
        Write-MigCsvTable -Table $t -Path $p
        $written.Add($p); $written.Add((Write-MigRptSidecar -Path $p -Algorithm $alg))
    }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'report.written' -Data ([ordered]@{
        report_type = $report.report_type; batch_id = $BatchId; status = $report.status; passed = $report.passed; dir = $outDir; files = $written.ToArray() })
    $summary = [ordered]@{
        report_type = $report.report_type; status = $report.status; passed = $report.passed
        report_dir = $outDir; files = $written.ToArray()
    }
    if ($Final) {
        $summary['final'] = [bool]$report.final
        $summary['passed'] = ($report.final -and $report.passed -eq $true)
        $summary['acceptance'] = [ordered]@{}
        if ($report.tables.Contains('acceptance')) { foreach ($r in $report.tables.acceptance.rows) { $summary['acceptance'][$r['id']] = ($r['passed'] -eq 'true') } }
    }
    return $summary
}
