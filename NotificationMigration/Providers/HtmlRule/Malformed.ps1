# HtmlRule 'malformed': for HTML files (htmlChecks.fileExtensions)
#   unreadable      -> error      (cannot be opened or decoded)
#   skipped_large   -> warning    (larger than maxBytesToParse; not parsed)
#   empty           -> warning    (0 bytes / whitespace only)
#   binary          -> error      (NUL characters after decoding)
#   missing_tag     -> warning    (a tag from requireTags is absent)
# Text comes from Get-MigHtmlContent (shared per-side read cache when run by the stage).

Register-MigProvider -Kind HtmlRule -Name 'malformed' -ScriptBlock {
    param($Ctx, $BatchId, $Side, $Root, $Records, $Options)
    $max = [long](Get-MigHtmlOption $Options 'maxBytesToParse' 0)
    $tags = @(Get-MigHtmlOption $Options 'requireTags' @() | Where-Object { $_ })
    $tagRx = @{}
    foreach ($t in $tags) { $tagRx[[string]$t] = New-Object regex(('<' + [regex]::Escape([string]$t) + '(?=[\s>/])'), 'IgnoreCase') }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in (Get-MigHtmlFileRecords -Ctx $Ctx -Records $Records)) {
        $rel = [string]$r['rel_path']
        $read = Get-MigHtmlContent -Ctx $Ctx -Root $Root -RelPath $rel -MaxBytes $max -Options $Options
        if ($read.too_large) {
            $out.Add((New-MigHtmlSkippedLarge -Rule 'malformed' -RelPath $rel -Size $read.size -MaxBytes $max))
            continue
        }
        if (-not $read.ok) {
            $out.Add((New-MigHtmlFinding -Rule 'malformed' -RelPath $rel -Severity 'error' -Code 'unreadable' -Detail ("unreadable: {0}" -f $read.error)))
            continue
        }
        if ($read.binary) {
            $out.Add((New-MigHtmlFinding -Rule 'malformed' -RelPath $rel -Severity 'error' -Code 'binary' -Detail ("binary-looking content (NUL characters), decoded as {0}" -f $read.encoding)))
            continue
        }
        if ([string]::IsNullOrWhiteSpace($read.text)) {
            $out.Add((New-MigHtmlFinding -Rule 'malformed' -RelPath $rel -Severity 'warning' -Code 'empty' -Detail 'no content'))
            continue
        }
        foreach ($t in $tags) {
            if (-not $tagRx[[string]$t].IsMatch($read.text)) {
                $out.Add((New-MigHtmlFinding -Rule 'malformed' -RelPath $rel -Severity 'warning' -Code 'missing_tag' -Detail ("required tag <{0}> not found" -f $t) -ParityFact ([string]$t)))
            }
        }
    }
    return , $out.ToArray()
}
