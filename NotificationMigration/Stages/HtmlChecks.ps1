# Stage: HtmlChecks (per batch). Runs every enabled HtmlRule provider (htmlChecks.rules.<name>.enabled) on the
# source (source manifest + sourceRoot) and on the target (target manifest + targetRoot), then compares the
# findings for parity. Read-only on both roots; results go to the store only (nothing at all in dry run).
#
# Parity (100%): two findings are "the same" when their parity_key matches (rule|code|rel_path|fact,
# case-insensitive). EVERY finding is compared, including longPath (a path too long on one side only is a
# difference; its parity record names both full lengths). Only rel_paths present in BOTH manifests are
# compared (missing/extra files belong to Reconcile). The renderSample sample is computed ONCE from the
# intersection of source and target HTML rel_paths and rendered on both sides.
#
# Scale: rules that read HTML contents ($script:MigHtmlContentRules) run per chunk of htmlChecks.chunkSize HTML
# files (the same rel_paths on both sides, so each chunk is compared on its own and memory stays bounded).
# Each HTML file is read and decoded ONCE per side per chunk (shared cache, see HtmlRuleCommon.ps1). Other
# rules (fileName, longPath, zeroByte, ...) run once over all records. Findings are written once per chunk.
#
# Output (per run): htmlchecks.source.<runId>.jsonl, htmlchecks.target.<runId>.jsonl,
# htmlchecks.parity.<runId>.jsonl; batch info htmlChecks (with files = @{ source; target; parity }).
# With htmlChecks.requireSourceTargetParity every rel_path with differences gets ONE 'html_parity' exception,
# opened in bulk with Add-MigExceptions (never re-opens an accepted or resolved item), plus one audit event.

function Get-MigHtmlEnabledRules {
    <# Enabled rules in config order as @{ name; options }. Unknown names fail fast via Get-MigProvider. #>
    param([Parameter(Mandatory = $true)] $Config)
    $rules = Get-MigHtmlOption (Get-MigHtmlOption $Config 'htmlChecks') 'rules'
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -eq $rules) { return @() }
    foreach ($name in @($rules.Keys)) {
        $opt = $rules[$name]
        if (-not [bool](Get-MigHtmlOption $opt 'enabled' $false)) { continue }
        $null = Get-MigProvider -Kind HtmlRule -Name $name
        $out.Add(@{ name = [string]$name; options = $opt })
    }
    return $out.ToArray()   # callers wrap in @()
}

function Invoke-MigHtmlRules {
    <#
    Runs the given rules for one side. Returns the findings (ordered hashtables).
    $Extra: run-time keys added to a shallow copy of each rule's options (_htmlCache, _knownPaths, _sample).
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId,
          [Parameter(Mandatory = $true)][ValidateSet('source', 'target')][string] $Side,
          [Parameter(Mandatory = $true)][string] $Root, [AllowEmptyCollection()][object[]] $Records, [object[]] $Rules,
          [hashtable] $Extra)
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($rule in @($Rules)) {
        $sb = Get-MigProvider -Kind HtmlRule -Name $rule.name
        $opt = $rule.options
        if ($Extra -and $Extra.Count -gt 0) {
            $opt = @{}
            if ($null -ne $rule.options) { foreach ($k in @($rule.options.Keys)) { $opt[$k] = $rule.options[$k] } }
            foreach ($k in $Extra.Keys) { $opt[$k] = $Extra[$k] }
        }
        try {
            $found = & $sb $Ctx $BatchId $Side $Root $Records $opt
        } catch {
            throw "HtmlRule '$($rule.name)' failed on $Side for batch '$BatchId': $($_.Exception.Message)"
        }
        foreach ($f in $found) {
            if ($null -eq $f) { continue }
            if (-not $f.Contains('parity_key') -or -not $f['parity_key']) {
                $f['parity_key'] = ('{0}|{1}|{2}|{3}' -f $f['rule'], $f['code'], $f['rel_path'], $f['detail']).ToLowerInvariant()
            }
            if (-not $f.Contains('side_specific')) { $f['side_specific'] = $false }
            $all.Add($f)
        }
    }
    return , $all.ToArray()
}

function Compare-MigHtmlFindings {
    <#
    Returns parity differences @{ rule; rel_path; detail; only_on; parity_key; severity; code } for all findings
    whose rel_path exists on both sides (side_specific is informational only and does not exclude a finding).
    #>
    param([AllowEmptyCollection()][object[]] $Source, [AllowEmptyCollection()][object[]] $Target, $SourcePaths, $TargetPaths)
    $s = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $t = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($Source)) {
        if ($null -eq $f) { continue }
        if ($null -ne $TargetPaths -and -not $TargetPaths.ContainsKey([string]$f['rel_path'])) { continue }
        $s[[string]$f['parity_key']] = $f
    }
    foreach ($f in @($Target)) {
        if ($null -eq $f) { continue }
        if ($null -ne $SourcePaths -and -not $SourcePaths.ContainsKey([string]$f['rel_path'])) { continue }
        $t[[string]$f['parity_key']] = $f
    }
    $sk = New-Object 'System.Collections.Generic.List[string]' (, [string[]]@($s.Keys)); $sk.Sort([StringComparer]::Ordinal)
    $tk = New-Object 'System.Collections.Generic.List[string]' (, [string[]]@($t.Keys)); $tk.Sort([StringComparer]::Ordinal)
    $diffs = New-Object System.Collections.Generic.List[object]
    foreach ($k in $sk) {
        if ($t.ContainsKey($k)) { continue }
        $f = $s[$k]
        $diffs.Add([ordered]@{ rule = $f['rule']; rel_path = $f['rel_path']; detail = $f['detail']; only_on = 'source'; parity_key = $k; severity = $f['severity']; code = $f['code'] })
    }
    foreach ($k in $tk) {
        if ($s.ContainsKey($k)) { continue }
        $f = $t[$k]
        $diffs.Add([ordered]@{ rule = $f['rule']; rel_path = $f['rel_path']; detail = $f['detail']; only_on = 'target'; parity_key = $k; severity = $f['severity']; code = $f['code'] })
    }
    return , $diffs.ToArray()
}

function Complete-MigHtmlChunk {
    <#
    Stores one group of findings (one write per side) and its parity differences, and updates the counters in
    $State. Nothing is written in dry run. longPath differences get a detail naming both full lengths.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)] $State,
          [AllowEmptyCollection()][object[]] $Source, [AllowEmptyCollection()][object[]] $Target, $SourcePaths, $TargetPaths)
    $ts = $State.ts
    foreach ($pair in @(@{ side = 'source'; items = $Source }, @{ side = 'target'; items = $Target })) {
        $recs = New-Object System.Collections.Generic.List[object]
        foreach ($f in @($pair.items)) {
            if ($null -eq $f) { continue }
            $n = [string]$f['rule']
            if (-not $State.by_rule.Contains($n)) { $State.by_rule[$n] = 0; $State.by_rule_source[$n] = 0; $State.by_rule_target[$n] = 0 }
            $State.by_rule[$n]++
            if ($pair.side -eq 'source') { $State.by_rule_source[$n]++; $State.source_findings++ } else { $State.by_rule_target[$n]++; $State.target_findings++ }
            if ($f['code'] -eq 'skipped_large') { $State.skipped_large++ }
            if ($State.dry) { continue }
            $r = [ordered]@{ run_id = $Ctx.RunId; batch_id = $BatchId; side = $pair.side }
            foreach ($k in $f.Keys) { $r[$k] = $f[$k] }
            $r['ts_utc'] = $ts
            $recs.Add($r)
        }
        if (-not $State.dry -and $recs.Count -gt 0) {
            Add-MigStoreRecords -Store $Ctx.Store -Name $State.files[$pair.side] -BatchId $BatchId -Records $recs.ToArray()
        }
    }

    $diffs = Compare-MigHtmlFindings -Source $Source -Target $Target -SourcePaths $SourcePaths -TargetPaths $TargetPaths
    if ($diffs.Count -eq 0) { return }
    $parityRecs = New-Object System.Collections.Generic.List[object]
    foreach ($d in $diffs) {
        if ($d['rule'] -eq 'longPath') {
            $rel = [string]$d['rel_path']
            $d['detail'] = 'full path length {0} on source, {1} on target; maxLength {2} (rel_path length {3})' -f `
                (Get-MigHtmlFullPathLength -Root $State.source_root -RelPath $rel), (Get-MigHtmlFullPathLength -Root $State.target_root -RelPath $rel), `
                $State.long_path_max, $rel.Length
        }
        $State.diffs.Add($d)
        if ($State.dry) { continue }
        $r = [ordered]@{ run_id = $Ctx.RunId; batch_id = $BatchId }
        foreach ($k in $d.Keys) { $r[$k] = $d[$k] }
        $r['ts_utc'] = $ts
        $parityRecs.Add($r)
    }
    if ($parityRecs.Count -gt 0) {
        Add-MigStoreRecords -Store $Ctx.Store -Name $State.files['parity'] -BatchId $BatchId -Records $parityRecs.ToArray()
    }
}

function Invoke-MigStageHtmlChecks {
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId)
    $cfg = $Ctx.Config
    $store = $Ctx.Store
    $dry = [bool]$Ctx.DryRun
    $hc = Get-MigHtmlOption $cfg 'htmlChecks'
    $requireParity = [bool](Get-MigHtmlOption $hc 'requireSourceTargetParity' $false)
    $chunkSize = [int](Get-MigHtmlOption $hc 'chunkSize' 5000)
    if ($chunkSize -lt 1) { $chunkSize = 5000 }
    $srcRoot = [string]$cfg.paths.sourceRoot
    $tgtRoot = [string]$cfg.paths.targetRoot

    # Checked without Get-MigStorePath, which would create the batch folder (dry run writes nothing).
    Assert-MigBatchId $BatchId
    $targetFile = Join-Path (Join-Path (Join-Path $store.Root 'batches') $BatchId) 'target.manifest.jsonl'
    if (-not (Test-Path -LiteralPath $targetFile)) {
        throw "HtmlChecks for batch '$BatchId' needs the target manifest, which does not exist yet. Run -Stage Verify for this batch first."
    }
    $src = Read-MigManifest -Store $store -BatchId $BatchId -Side source
    if ($src.Count -eq 0) { throw "HtmlChecks for batch '$BatchId': the source manifest is empty. Run Inventory and Batching first." }
    $tgt = Read-MigManifest -Store $store -BatchId $BatchId -Side target

    $rules = @(Get-MigHtmlEnabledRules -Config $cfg)
    $wholeRules = @($rules | Where-Object { $script:MigHtmlContentRules -notcontains $_.name })
    $contentRules = @($rules | Where-Object { $script:MigHtmlContentRules -contains $_.name })
    $rs = @($rules | Where-Object { $_.name -eq 'renderSample' }) | Select-Object -First 1

    # Fail before writing anything when a strict renderer cannot run.
    if ($rs -and [string](Get-MigHtmlOption $rs.options 'renderer' 'parse') -eq 'edgeHeadless' -and [bool](Get-MigHtmlOption $rs.options 'strictRenderer' $false)) {
        if (-not (Find-MigEdgePath -Options $rs.options)) {
            throw "HtmlChecks for batch '$BatchId': renderSample.renderer is 'edgeHeadless' with strictRenderer = true, but Microsoft Edge was not found (htmlChecks.rules.renderSample.edgePath / PATH)."
        }
    }

    $srcAll = @($src.Values); $tgtAll = @($tgt.Values)
    $srcHtml = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $tgtHtml = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in (Get-MigHtmlFileRecords -Ctx $Ctx -Records $srcAll)) { $srcHtml[[string]$r['rel_path']] = $r }
    foreach ($r in (Get-MigHtmlFileRecords -Ctx $Ctx -Records $tgtAll)) { $tgtHtml[[string]$r['rel_path']] = $r }

    # One sample for both sides, from the rel_paths present on both.
    $sample = $null
    $both = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $srcHtml.Keys) { if ($tgtHtml.ContainsKey($k)) { $both.Add($k) } }
    if ($rs) {
        $sample = @(Get-MigHtmlRenderSample -RelPaths $both.ToArray() `
            -Rate ([double](Get-MigHtmlOption $rs.options 'rate' 0)) -MinPerBatch ([int](Get-MigHtmlOption $rs.options 'minPerBatch' 0)) `
            -Seed ([string](Get-MigHtmlOption $rs.options 'seed' '')) -BatchId $BatchId)
    }

    $lpOpt = Get-MigHtmlOption (Get-MigHtmlOption $hc 'rules') 'longPath'
    $state = @{
        dry = $dry; ts = (Get-MigUtcNow); source_root = $srcRoot; target_root = $tgtRoot
        long_path_max = [int](Get-MigHtmlOption $lpOpt 'maxLength' 0)
        files = [ordered]@{
            source = 'htmlchecks.source.{0}.jsonl' -f $Ctx.RunId
            target = 'htmlchecks.target.{0}.jsonl' -f $Ctx.RunId
            parity = 'htmlchecks.parity.{0}.jsonl' -f $Ctx.RunId
        }
        by_rule = [ordered]@{}; by_rule_source = [ordered]@{}; by_rule_target = [ordered]@{}
        source_findings = 0; target_findings = 0; skipped_large = 0
        diffs = (New-Object System.Collections.Generic.List[object])
    }
    foreach ($rule in $rules) { $state.by_rule[$rule.name] = 0; $state.by_rule_source[$rule.name] = 0; $state.by_rule_target[$rule.name] = 0 }

    # 1. Rules over all records (names, lengths, sizes): once per side.
    if ($wholeRules.Count -gt 0) {
        $sF = Invoke-MigHtmlRules -Ctx $Ctx -BatchId $BatchId -Side source -Root $srcRoot -Records $srcAll -Rules $wholeRules
        $tF = Invoke-MigHtmlRules -Ctx $Ctx -BatchId $BatchId -Side target -Root $tgtRoot -Records $tgtAll -Rules $wholeRules
        Complete-MigHtmlChunk -Ctx $Ctx -BatchId $BatchId -State $state -Source $sF -Target $tF -SourcePaths $src -TargetPaths $tgt
        $sF = $null; $tF = $null
    }

    # 2. Content rules per chunk of HTML rel_paths (same chunk boundaries on both sides).
    $chunks = 0
    if ($contentRules.Count -gt 0 -and ($srcHtml.Count + $tgtHtml.Count) -gt 0) {
        $union = New-Object 'System.Collections.Generic.List[string]' (, [string[]]@($srcHtml.Keys))
        foreach ($k in $tgtHtml.Keys) { if (-not $srcHtml.ContainsKey($k)) { $union.Add($k) } }
        $union.Sort([StringComparer]::OrdinalIgnoreCase)
        $known = @{}
        foreach ($pair in @(@{ side = 'source'; recs = $srcAll }, @{ side = 'target'; recs = $tgtAll })) {
            $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($r in $pair.recs) { if ($null -ne $r -and ($r['kind'] -eq 'file' -or $r['kind'] -eq 'dir')) { [void]$set.Add([string]$r['rel_path']) } }
            $known[$pair.side] = $set
        }
        $readMax = Get-MigHtmlReadMaxBytes -Ctx $Ctx -Rules $contentRules
        $started = [DateTime]::UtcNow
        for ($i = 0; $i -lt $union.Count; $i += $chunkSize) {
            $chunks++
            $n = [Math]::Min($chunkSize, $union.Count - $i)
            $sRecs = New-Object System.Collections.Generic.List[object]
            $tRecs = New-Object System.Collections.Generic.List[object]
            $rec = $null
            foreach ($rel in $union.GetRange($i, $n)) {
                if ($srcHtml.TryGetValue($rel, [ref]$rec)) { $sRecs.Add($rec) }
                if ($tgtHtml.TryGetValue($rel, [ref]$rec)) { $tRecs.Add($rec) }
            }
            $sExtra = @{ _htmlCache = (New-MigHtmlTextCache -MaxBytes $readMax); _knownPaths = $known['source'] }
            $tExtra = @{ _htmlCache = (New-MigHtmlTextCache -MaxBytes $readMax); _knownPaths = $known['target'] }
            if ($null -ne $sample) { $sExtra['_sample'] = $sample; $tExtra['_sample'] = $sample }
            $sF = Invoke-MigHtmlRules -Ctx $Ctx -BatchId $BatchId -Side source -Root $srcRoot -Records $sRecs.ToArray() -Rules $contentRules -Extra $sExtra
            $tF = Invoke-MigHtmlRules -Ctx $Ctx -BatchId $BatchId -Side target -Root $tgtRoot -Records $tRecs.ToArray() -Rules $contentRules -Extra $tExtra
            Complete-MigHtmlChunk -Ctx $Ctx -BatchId $BatchId -State $state -Source $sF -Target $tF -SourcePaths $src -TargetPaths $tgt
            $sF = $null; $tF = $null; $sExtra = $null; $tExtra = $null
            if ($union.Count -gt $chunkSize) {
                Write-MigProgress -Activity "HtmlChecks $BatchId" -Status 'HTML files' -Done ($i + $n) -Total $union.Count -Started $started
            }
        }
    }

    # 3. Exceptions: one per rel_path with differences, bulk-opened (accepted/resolved items are never re-opened).
    $diffs = $state.diffs
    $opened = 0; $wouldOpen = 0
    if ($requireParity -and $diffs.Count -gt 0) {
        $byPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        $order = New-Object 'System.Collections.Generic.List[string]'
        foreach ($d in $diffs) {
            $rel = [string]$d['rel_path']
            if (-not $byPath.ContainsKey($rel)) { $byPath[$rel] = New-Object 'System.Collections.Generic.List[string]'; $order.Add($rel) }
            $byPath[$rel].Add(('{0}: {1} (only on {2})' -f $d['rule'], $d['detail'], $d['only_on']))
        }
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($rel in $order) {
            $detail = $byPath[$rel].ToArray() -join '; '
            if ($detail.Length -gt 4000) { $detail = $detail.Substring(0, 4000) + ' ...' }
            $items.Add(@{ rel_path = $rel; category = 'html_parity'; detail = $detail })
        }
        if ($dry) {
            $knownFp = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($e in (Get-MigExceptions -Store $store -BatchId $BatchId)) { [void]$knownFp.Add([string]$e['fingerprint']) }
            foreach ($it in $items) { if (-not $knownFp.Contains((Get-MigExceptionFingerprint -BatchId $BatchId -RelPath $it.rel_path -Category 'html_parity'))) { $wouldOpen++ } }
        } else {
            $new = @(Add-MigExceptions -Store $store -BatchId $BatchId -Items $items.ToArray() -RunId $Ctx.RunId)
            $opened = $new.Count
            if ($opened -gt 0) {
                Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Level warn -Event 'htmlchecks.parity_exceptions' -Data ([ordered]@{
                    batch_id = $BatchId; opened = $opened; rel_paths_with_differences = $items.Count
                    first_paths = @($new | Select-Object -First 50 | ForEach-Object { $_['rel_path'] }) })
            }
        }
    }

    $parity = ($diffs.Count -eq 0)
    $info = [ordered]@{
        parity = $parity; run_id = $Ctx.RunId
        source_findings = $state.source_findings; target_findings = $state.target_findings; parity_differences = $diffs.Count
        by_rule = $state.by_rule; by_rule_source = $state.by_rule_source; by_rule_target = $state.by_rule_target
        rules = @($rules | ForEach-Object { $_.name }); exceptions_opened = $opened
        html_files_source = $srcHtml.Count; html_files_target = $tgtHtml.Count; html_files_compared = $both.Count
        sample_size = $(if ($null -eq $sample) { 0 } else { $sample.Count }); skipped_large = $state.skipped_large; chunks = $chunks
        files = $state.files
    }
    if ($dry) {
        $info['files'] = $null
        $info['dry_run'] = $true
        $info['exceptions_would_open'] = $wouldOpen
    } else {
        Set-MigBatchInfo -Store $store -BatchId $BatchId -Data @{ htmlChecks = $info }
    }
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'htmlchecks.completed' -Data ([ordered]@{
        batch_id = $BatchId; dry_run = $dry; parity = $parity; source_findings = $state.source_findings; target_findings = $state.target_findings
        parity_differences = $diffs.Count; exceptions_opened = $opened; skipped_large = $state.skipped_large })

    $summary = [ordered]@{ batch_id = $BatchId }
    foreach ($k in $info.Keys) { $summary[$k] = $info[$k] }
    return $summary
}
