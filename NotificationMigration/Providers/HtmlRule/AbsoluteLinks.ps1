# HtmlRule 'absoluteLinks': REPORT ONLY (never rewrites). Finds links hard-coded to the old server, using
# only the configured lists htmlChecks.rules.absoluteLinks.oldHosts / oldUncPrefixes / oldIpAddresses
# (case-insensitive). A match counts when it is part of a link-like token (contains '/' or '\'), so plain
# text mentions of a server name are not reported. UNC prefixes also match their forward-slash form
# (file://server/share, //server/share). Files above maxBytesToParse (this rule's, else malformed's) are
# reported as 'skipped_large'. Text comes from Get-MigHtmlContent (shared per-side read cache).

Register-MigProvider -Kind HtmlRule -Name 'absoluteLinks' -ScriptBlock {
    param($Ctx, $BatchId, $Side, $Root, $Records, $Options)
    $terms = New-Object System.Collections.Generic.List[object]
    foreach ($h in @(Get-MigHtmlOption $Options 'oldHosts' @() | Where-Object { $_ })) {
        $terms.Add(@{ kind = 'host'; term = [string]$h; rx = New-Object regex(('(?<![A-Za-z0-9-])' + [regex]::Escape([string]$h) + '(?![A-Za-z0-9-])'), 'IgnoreCase') })
    }
    foreach ($ip in @(Get-MigHtmlOption $Options 'oldIpAddresses' @() | Where-Object { $_ })) {
        $terms.Add(@{ kind = 'ip'; term = [string]$ip; rx = New-Object regex(('(?<![0-9.])' + [regex]::Escape([string]$ip) + '(?![0-9])'), 'IgnoreCase') })
    }
    foreach ($u in @(Get-MigHtmlOption $Options 'oldUncPrefixes' @() | Where-Object { $_ })) {
        $parts = @(([string]$u) -split '[\\/]+' | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) })
        if ($parts.Count -eq 0) { continue }
        $terms.Add(@{ kind = 'unc'; term = [string]$u; rx = New-Object regex(('[\\/]{2}' + ($parts -join '[\\/]+')), 'IgnoreCase') })
    }
    if ($terms.Count -eq 0) { return @() }
    $max = Get-MigHtmlRuleMaxBytes -Ctx $Ctx -Options $Options
    $stops = [char[]]@(' ', "`t", "`r", "`n", '"', "'", '<', '>', '(', ')', '`')

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in (Get-MigHtmlFileRecords -Ctx $Ctx -Records $Records)) {
        $rel = [string]$r['rel_path']
        $read = Get-MigHtmlContent -Ctx $Ctx -Root $Root -RelPath $rel -MaxBytes $max -Options $Options
        if ($read.too_large) { $out.Add((New-MigHtmlSkippedLarge -Rule 'absoluteLinks' -RelPath $rel -Size $read.size -MaxBytes $max)); continue }
        if (-not $read.ok -or $read.binary) { continue }   # reported by 'malformed'
        $text = $read.text
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($t in $terms) {
            foreach ($m in $t.rx.Matches($text)) {
                $s = $text.LastIndexOfAny($stops, [Math]::Max(0, $m.Index - 1)) + 1
                if ($m.Index -eq 0) { $s = 0 }
                $e = $text.IndexOfAny($stops, $m.Index + $m.Length)
                if ($e -lt 0) { $e = $text.Length }
                $token = $text.Substring($s, $e - $s)
                if ($t.kind -ne 'unc' -and $token.IndexOfAny([char[]]@('/', '\')) -lt 0) { continue }
                if (-not $seen.Add($t.term + '|' + $token)) { continue }
                $out.Add((New-MigHtmlFinding -Rule 'absoluteLinks' -RelPath $rel -Severity 'warning' -Code ('old_' + $t.kind) `
                    -Detail ("link to old {0} '{1}': {2}" -f $t.kind, $t.term, $token) -ParityFact ($t.term + '|' + $token)))
            }
        }
    }
    return , $out.ToArray()
}
