# HtmlRule 'longPath': flags entries whose full path on THIS side exceeds htmlChecks.rules.longPath.maxLength.
# The finding takes part in parity: its parity_key is rule|code|rel_path (no length), so a path that is too long
# on both sides matches, while a path too long on one side only (e.g. the target root is longer) is a genuine
# parity difference. The stage names both full lengths in that difference's detail.

Register-MigProvider -Kind HtmlRule -Name 'longPath' -ScriptBlock {
    param($Ctx, $BatchId, $Side, $Root, $Records, $Options)
    $max = [int](Get-MigHtmlOption $Options 'maxLength' 0)
    if ($max -le 0) { return @() }
    $rootLen = Get-MigHtmlFullPathLength -Root $Root -RelPath ''
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Records)) {
        if ($null -eq $r) { continue }
        $kind = $r['kind']
        if ($kind -ne 'file' -and $kind -ne 'dir') { continue }
        $rel = [string]$r['rel_path']
        if (-not $rel) { continue }
        $full = $rootLen + $rel.Length
        if ($full -gt $max) {
            $out.Add((New-MigHtmlFinding -Rule 'longPath' -RelPath $rel -Severity 'warning' -Code 'path_too_long' `
                -Detail ("full path length {0} exceeds {1} on {2} (rel_path length {3})" -f $full, $max, $Side, $rel.Length)))
        }
    }
    return , $out.ToArray()
}
