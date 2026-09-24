# Batch strategy 'regex' (default). Batches by folder name, e.g. <root>\2019\03\... -> '2019-03'.
# Options (batching.options):
#   pattern           regex with named groups, matched against the canonical rel_path ('\' separators,
#                     no leading '\'), case-insensitive. Example: ^(?<y>\d{4})[\\/](?<m>\d{2})
#   template          batch id built from the groups: '{y}-{m}' ({1}-style numbered groups also work)
#   unmatchedBatchId  batch for entries the pattern does not match (default 'UNBATCHED')
#   parentDirBatchId  optional; see Providers/Batch/BatchCommon.ps1
# Directories: a directory belongs to the batch its own path matches (e.g. '2019\03' -> '2019-03').
# Directories above the batch level ('2019') do not match, so they go to parentDirBatchId when set,
# otherwise to unmatchedBatchId.

# Options are compiled once per stage run (see Get-MigBatchCompiled): pattern, template parts, fallbacks.

function New-MigBatchRegexCompiled {
    param($Options)
    $pattern = [string](Get-MigBatchOption -Options $Options -Name 'pattern' -Default '')
    $template = [string](Get-MigBatchOption -Options $Options -Name 'template' -Default '')
    if ([string]::IsNullOrWhiteSpace($pattern)) { throw "Batch strategy 'regex' needs batching.options.pattern." }
    if ([string]::IsNullOrWhiteSpace($template)) { throw "Batch strategy 'regex' needs batching.options.template." }
    $rx = Get-MigBatchRegex -Pattern $pattern
    return @{ Regex = $rx; Parts = (ConvertTo-MigBatchTemplateParts -Template $template -Regex $rx); Fallback = (New-MigBatchFallbackIds -Options $Options) }
}

Register-MigProvider -Kind Batch -Name 'regex' -ScriptBlock {
    param($RelPath, $Record, $Options)
    $last = $script:MigBatchLast
    if ($null -ne $last -and $last.Strategy -eq 'regex' -and [object]::ReferenceEquals($last.Options, $Options)) { $c = $last.Compiled }
    else { $c = Get-MigBatchCompiled -Options $Options -Strategy 'regex' -Builder ${function:New-MigBatchRegexCompiled} }
    $m = $c.Regex.Match(([string]$RelPath).Replace('/', '\').TrimStart('\'))
    if (-not $m.Success) { return Select-MigBatchFallbackId -Fallback $c.Fallback -Kind (Get-MigBatchRecordKind $Record) }
    $id = ''
    foreach ($p in $c.Parts) { if ($p -is [string]) { $id += $p } else { $id += $m.Groups[$p.Group].Value } }
    if ($script:MigBatchSafeIdOk.IsMatch($id)) { return $id }
    return ConvertTo-MigSafeBatchId $id
}
