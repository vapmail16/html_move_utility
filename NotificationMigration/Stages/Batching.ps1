# Stage 2: Batching (FR-02 batches with ids, C-04 per-batch totals, FR-10 dry-run plan / size estimate).
# Batch ids are assigned during Inventory by the Batch provider; this stage turns each batch's source
# manifest into a plan: file/dir counts, total bytes, zero-byte files and scan errors. The plan is the
# baseline Reconcile checks the target against, and the summary is the size estimate of a dry run.
# Delta refreshes the plan of the batches it changes with the same function (Get-MigBatchPlanTotals).

function Get-MigBatchPlanTotals {
    <# The batch plan (C-04): @{ file_count; dir_count; total_bytes; zero_byte_count; error_count }. #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId)
    $t = Get-MigBatchManifestTotals -Store $Store -BatchId $BatchId
    $plan = [ordered]@{}
    foreach ($k in @('file_count', 'dir_count', 'total_bytes', 'zero_byte_count', 'error_count')) { $plan[$k] = $t[$k] }
    return $plan
}

function Get-MigBatchManifestTotals {
    <#
    Totals of one batch's source manifest (latest record per rel_path, tombstones excluded): the plan keys plus
    ok_file_count / ok_bytes (files without a scan error). The manifest is streamed block by block; only one
    packed [long] per rel_path is held:
      bits 0-1 kind (1 file, 2 dir, 3 error, 0 other)  bit 2 has error  bit 3 size known  bits 4+ size_bytes
    #>
    param([Parameter(Mandatory = $true)] $Store, [Parameter(Mandatory = $true)][string] $BatchId)
    $plan = [ordered]@{ file_count = 0; dir_count = 0; total_bytes = [long]0; zero_byte_count = 0; error_count = 0; ok_file_count = 0; ok_bytes = [long]0 }
    $path = Join-Path (Join-Path (Join-Path $Store.Root 'batches') $BatchId) 'source.manifest.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $plan }
    $latest = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::OrdinalIgnoreCase)
    Invoke-MigStoreLineBlocks -Path $path -Action {
        param($block)
        foreach ($r in $block) {
            $rel = $r['rel_path']
            if ($null -eq $rel) { continue }
            if ($r['deleted'] -eq $true) { [void]$latest.Remove([string]$rel); continue }
            $v = [long]0
            switch ([string]$r['kind']) { 'file' { $v = 1 } 'dir' { $v = 2 } 'error' { $v = 3 } }
            if ($v -eq 3 -or -not [string]::IsNullOrEmpty([string]$r['error'])) { $v = $v -bor 4 }
            if ($null -ne $r['size_bytes']) { $v = $v -bor 8 -bor ([long]$r['size_bytes'] -shl 4) }
            $latest[[string]$rel] = $v
        }
    }
    foreach ($v in $latest.Values) {
        $kind = $v -band 3
        $hasError = ($v -band 4) -ne 0
        if ($hasError) { $plan.error_count++ }
        if ($kind -eq 1) {
            $plan.file_count++
            if (-not $hasError) { $plan.ok_file_count++ }
            if (($v -band 8) -ne 0) {
                $size = $v -shr 4
                $plan.total_bytes += $size
                if (-not $hasError) { $plan.ok_bytes += $size }
                if (-not $hasError -and $size -eq 0) { $plan.zero_byte_count++ }
            }
        } elseif ($kind -eq 2) {
            $plan.dir_count++
        }
    }
    return $plan
}

function Invoke-MigStageBatching {
    param([Parameter(Mandatory = $true)] $Ctx)
    $existing = Get-MigBatches -Store $Ctx.Store
    $list = New-Object System.Collections.Generic.List[object]
    $totalFiles = 0; $totalDirs = 0; $totalBytes = [long]0; $totalErrors = 0
    # Ordinal sort of ids: '2019-03' < '2019-04' < '2020-01', i.e. oldest first for date-shaped ids (runbook: pilot oldest year first).
    $ids = [string[]]@(Get-MigBatchIds -Store $Ctx.Store | Where-Object { Test-MigInvBatchHasManifest -Store $Ctx.Store -BatchId $_ })
    [Array]::Sort($ids, [StringComparer]::Ordinal)
    $done = 0
    $started = [DateTime]::UtcNow
    foreach ($bid in $ids) {
        $plan = Get-MigBatchPlanTotals -Store $Ctx.Store -BatchId $bid
        $data = [ordered]@{ plan = $plan }
        $current = $null
        if ($existing.ContainsKey($bid) -and $existing[$bid].ContainsKey('state')) { $current = $existing[$bid]['state'] }
        # Never move a batch backwards: only (re)set 'planned' when it has not progressed yet.
        if ([string]::IsNullOrEmpty($current) -or $current -eq 'planned' -or $current -eq 'inventoried') { $data['state'] = 'planned'; $current = 'planned' }
        Set-MigBatchInfo -Store $Ctx.Store -BatchId $bid -Data $data

        $row = [ordered]@{ batch_id = $bid; state = $current }
        foreach ($k in $plan.Keys) { $row[$k] = $plan[$k] }
        $list.Add($row)
        $totalFiles += $plan.file_count; $totalDirs += $plan.dir_count; $totalBytes += $plan.total_bytes; $totalErrors += $plan.error_count
        $done++
        Write-MigProgress -Activity 'Batching' -Status "batch $bid" -Done $done -Total $ids.Count -Started $started
    }
    Write-Progress -Activity 'Batching' -Completed
    # One audit event for the stage (per-batch rows are in the store and the summary).
    Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event 'batching.planned' -Data ([ordered]@{
        batch_count = $list.Count; files = $totalFiles; dirs = $totalDirs; bytes = $totalBytes; errors = $totalErrors
        batches = @($list | Select-Object -First 50)
    })
    return [ordered]@{
        batches = $list.ToArray(); batch_count = $list.Count
        files = $totalFiles; dirs = $totalDirs; bytes = $totalBytes; errors = $totalErrors; dry_run = $Ctx.DryRun
    }
}
