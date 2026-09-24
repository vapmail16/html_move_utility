# HtmlRule 'zeroByte': every file whose size is 0 (all files, not only HTML). Counts must match on both sides.

Register-MigProvider -Kind HtmlRule -Name 'zeroByte' -ScriptBlock {
    param($Ctx, $BatchId, $Side, $Root, $Records, $Options)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Records)) {
        if ($null -eq $r -or $r['kind'] -ne 'file') { continue }
        $size = $r['size_bytes']
        if ($null -ne $size -and [long]$size -eq 0) {
            $out.Add((New-MigHtmlFinding -Rule 'zeroByte' -RelPath ([string]$r['rel_path']) -Severity 'warning' -Code 'zero_byte' -Detail 'file is 0 bytes'))
        }
    }
    return , $out.ToArray()
}
