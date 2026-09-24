# Batch strategies 'yearMonth' ('2019-03') and 'year' ('2019'), derived from a timestamp of the entry.
# Options (batching.options):
#   dateField         'modified_utc' (default) or 'created_utc'
#   unmatchedBatchId  batch for entries without a usable timestamp, e.g. scan errors (default 'UNBATCHED')
# Note: the batch follows the file's timestamp, not its folder. A file whose timestamp changes after
# inventory (see Delta) is placed in the batch of its new timestamp. Prefer 'regex' / 'folderDepth'
# when the folder layout already encodes the period.

function New-MigBatchDateCompiled {
    param($Options)
    $field = [string](Get-MigBatchOption -Options $Options -Name 'dateField' -Default 'modified_utc')
    if (@('modified_utc', 'created_utc') -notcontains $field) {
        throw "batching.options.dateField must be 'modified_utc' or 'created_utc' (got '$field')."
    }
    return @{ Field = $field; Fallback = (New-MigBatchFallbackIds -Options $Options) }
}

function Get-MigBatchDateValue {
    <# The record's configured timestamp as a UTC DateTime, or $null. Fast path for the scanner's ISO 'o' strings. #>
    param($Record, [Parameter(Mandatory = $true)][string] $Field)
    if ($Record -is [System.Collections.IDictionary]) { $v = $Record[$Field] } else { $v = Get-MigBatchRecordValue -Record $Record -Name $Field }
    $d = [DateTime]::MinValue
    if ($v -is [string] -and [DateTime]::TryParseExact($v, 'o', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$d) -and $d.Kind -eq [DateTimeKind]::Utc) { return $d }
    return ConvertTo-MigBatchDate $v
}

# The two providers repeat a few lines instead of sharing a function: they run once per entry.
Register-MigProvider -Kind Batch -Name 'yearMonth' -ScriptBlock {
    param($RelPath, $Record, $Options)
    $last = $script:MigBatchLast
    if ($null -ne $last -and $last.Strategy -eq 'date' -and [object]::ReferenceEquals($last.Options, $Options)) { $c = $last.Compiled }
    else { $c = Get-MigBatchCompiled -Options $Options -Strategy 'date' -Builder ${function:New-MigBatchDateCompiled} }
    $d = Get-MigBatchDateValue -Record $Record -Field $c.Field
    if ($null -eq $d) { return Select-MigBatchFallbackId -Fallback $c.Fallback -Kind (Get-MigBatchRecordKind $Record) }
    return $d.ToString('yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture)
}

Register-MigProvider -Kind Batch -Name 'year' -ScriptBlock {
    param($RelPath, $Record, $Options)
    $last = $script:MigBatchLast
    if ($null -ne $last -and $last.Strategy -eq 'date' -and [object]::ReferenceEquals($last.Options, $Options)) { $c = $last.Compiled }
    else { $c = Get-MigBatchCompiled -Options $Options -Strategy 'date' -Builder ${function:New-MigBatchDateCompiled} }
    $d = Get-MigBatchDateValue -Record $Record -Field $c.Field
    if ($null -eq $d) { return Select-MigBatchFallbackId -Fallback $c.Fallback -Kind (Get-MigBatchRecordKind $Record) }
    return $d.ToString('yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
}
