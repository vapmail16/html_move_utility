# Compare providers: exists, size, hash (FR-05, C-03).
# Contract: param($Ctx, $Source, $Target, $Options) -> $null when equal, else a mismatch detail string.
# $Source / $Target are manifest records (either may be $null or a tombstone); $Options = config 'compare' section.
# Presence (missing / extra) is decided by 'exists'; the other providers return $null when a side is absent
# so a missing file is reported once, as missing.

function Test-MigRecordPresent {
    param($Record)
    if ($null -eq $Record) { return $false }
    if ($Record['deleted'] -eq $true) { return $false }
    return $true
}

Register-MigProvider -Kind Compare -Name 'exists' -ScriptBlock {
    param($Ctx, $Source, $Target, $Options)
    $s = Test-MigRecordPresent $Source
    $t = Test-MigRecordPresent $Target
    if ($s -and -not $t) { return ('{0} missing on target' -f $Source['kind']) }
    if ($t -and -not $s) { return ('{0} exists on target but not on source' -f $Target['kind']) }
    if (-not $s -and -not $t) { return $null }
    if ([string]$Source['kind'] -ne [string]$Target['kind']) {
        return ('kind differs: source is {0}, target is {1}' -f $Source['kind'], $Target['kind'])
    }
    return $null
}

Register-MigProvider -Kind Compare -Name 'size' -ScriptBlock {
    param($Ctx, $Source, $Target, $Options)
    if (-not (Test-MigRecordPresent $Source) -or -not (Test-MigRecordPresent $Target)) { return $null }
    if ($Source['kind'] -ne 'file') { return $null }
    $s = $Source['size_bytes']; $t = $Target['size_bytes']
    if ($null -eq $s -or $null -eq $t) { return ('size unknown: source={0} target={1}' -f $s, $t) }
    if ([int64]$s -ne [int64]$t) { return ('size differs: source={0} target={1} bytes' -f $s, $t) }
    return $null
}

Register-MigProvider -Kind Compare -Name 'hash' -ScriptBlock {
    param($Ctx, $Source, $Target, $Options)
    if (-not (Test-MigRecordPresent $Source) -or -not (Test-MigRecordPresent $Target)) { return $null }
    if ($Source['kind'] -ne 'file') { return $null }
    $sh = [string]$Source['hash']; $th = [string]$Target['hash']
    if (-not $sh -or -not $th) { return ('hash missing: source={0} target={1}' -f $sh, $th) }
    $sa = [string]$Source['hash_algo']; $ta = [string]$Target['hash_algo']
    if (-not $sa.Equals($ta, [StringComparison]::OrdinalIgnoreCase)) { return ('hash algorithm differs: source={0} target={1}' -f $sa, $ta) }
    if (-not $sh.Equals($th, [StringComparison]::OrdinalIgnoreCase)) { return ('{0} differs: source={1} target={2}' -f $sa, $sh, $th) }
    return $null
}
