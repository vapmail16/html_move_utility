# Batch strategy 'folderDepth': the first N folder segments joined with '-'.
#   depth = 2:  2019\03\a.html -> '2019-03'   2019\03\17\b.html -> '2019-03'   dir 2019\03 -> '2019-03'
# Options (batching.options):
#   depth             number of folder segments (required, >= 1)
#   unmatchedBatchId  batch for entries with fewer than N folder segments (default 'UNBATCHED')
#   parentDirBatchId  optional; directories above the batch level ('2019' at depth 2) go here when set
# For files the file name is not a segment; for directories the directory's own name is.

function New-MigBatchFolderDepthCompiled {
    param($Options)
    $depth = 0
    $raw = Get-MigBatchOption -Options $Options -Name 'depth' -Default $null
    if ($null -eq $raw -or -not [int]::TryParse([string]$raw, [ref]$depth) -or $depth -lt 1) {
        throw "Batch strategy 'folderDepth' needs batching.options.depth >= 1."
    }
    return @{ Depth = $depth; Fallback = (New-MigBatchFallbackIds -Options $Options) }
}

Register-MigProvider -Kind Batch -Name 'folderDepth' -ScriptBlock {
    param($RelPath, $Record, $Options)
    $last = $script:MigBatchLast
    if ($null -ne $last -and $last.Strategy -eq 'folderDepth' -and [object]::ReferenceEquals($last.Options, $Options)) { $c = $last.Compiled }
    else { $c = Get-MigBatchCompiled -Options $Options -Strategy 'folderDepth' -Builder ${function:New-MigBatchFolderDepthCompiled} }
    $segments = ([string]$RelPath).Replace('/', '\').Split([char[]]@([char]'\'), [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($Record -is [System.Collections.IDictionary] -and $null -ne $Record['kind']) { $kind = [string]$Record['kind'] } else { $kind = Get-MigBatchRecordKind $Record }
    $n = $segments.Length
    if ($kind -eq 'file') { $n = [Math]::Max(0, $n - 1) }       # the file name is not a folder segment
    if ($n -lt $c.Depth) { return Select-MigBatchFallbackId -Fallback $c.Fallback -Kind $kind }
    $id = [string]::Join('-', $segments, 0, $c.Depth)
    if ($script:MigBatchSafeIdOk.IsMatch($id)) { return $id }
    return ConvertTo-MigSafeBatchId $id
}
