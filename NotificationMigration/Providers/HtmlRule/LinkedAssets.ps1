# HtmlRule 'linkedAssets': for HTML files, collects references from every configured attribute (src/href),
# srcset candidates (parseSrcset) and CSS url(...) in style attributes and <style> blocks (parseCssUrls).
# It ignores configured schemes, anchors and absolute URLs, resolves relative references against the file's
# folder and reports references whose target does not exist on THIS side. Root-relative ('/img/a.png')
# references resolve against this side's root. References that climb above the root are 'outside_root'.
# Files above maxBytesToParse (this rule's, else malformed's) are reported as 'skipped_large'.
# Existence: $Options._knownPaths (all rel_paths of the side, set by the stage) or the records given,
# then a cached disk lookup (case-insensitive, NTFS semantics).

Register-MigProvider -Kind HtmlRule -Name 'linkedAssets' -ScriptBlock {
    param($Ctx, $BatchId, $Side, $Root, $Records, $Options)
    $attrs = @(Get-MigHtmlOption $Options 'attributes' @() | Where-Object { $_ })
    $ignore = @(Get-MigHtmlOption $Options 'ignoreSchemes' @() | Where-Object { $_ })
    $css = [bool](Get-MigHtmlOption $Options 'parseCssUrls' $false)
    $srcset = [bool](Get-MigHtmlOption $Options 'parseSrcset' $false)
    if ($attrs.Count -eq 0 -and -not $css -and -not $srcset) { return @() }
    $max = Get-MigHtmlRuleMaxBytes -Ctx $Ctx -Options $Options
    $spec = New-MigHtmlReferenceSpec -Attributes $attrs -ParseCssUrls $css -ParseSrcset $srcset

    $known = Get-MigHtmlOption $Options '_knownPaths'
    $exists = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $known) {
        foreach ($r in @($Records)) { if ($null -ne $r -and ($r['kind'] -eq 'file' -or $r['kind'] -eq 'dir')) { $exists[[string]$r['rel_path']] = $true } }
    }

    $resolved = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in (Get-MigHtmlFileRecords -Ctx $Ctx -Records $Records)) {
        $rel = [string]$r['rel_path']
        $read = Get-MigHtmlContent -Ctx $Ctx -Root $Root -RelPath $rel -MaxBytes $max -Options $Options
        if ($read.too_large) { $out.Add((New-MigHtmlSkippedLarge -Rule 'linkedAssets' -RelPath $rel -Size $read.size -MaxBytes $max)); continue }
        if (-not $read.ok -or $read.binary) { continue }   # reported by 'malformed'
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $baseDir = ''
        $slash = $rel.LastIndexOf('\')
        if ($slash -gt 0) { $baseDir = $rel.Substring(0, $slash) }
        foreach ($a in (Get-MigHtmlReferences -Text $read.text -Spec $spec)) {
            # Memoized per folder + reference (files in one folder usually share their assets).
            $memoKey = $baseDir + [char]0 + $a.value
            $res = $null
            if (-not $resolved.TryGetValue($memoKey, [ref]$res)) {
                $res = Resolve-MigHtmlReference -BaseRelPath $rel -Reference $a.value -IgnoreSchemes $ignore
                if ($resolved.Count -ge 100000) { $resolved.Clear() }
                $resolved[$memoKey] = $res
            }
            if ($res.kind -eq 'ignore') { continue }
            if ($res.kind -eq 'outside') {
                if ($seen.Add('outside|' + $a.value)) {
                    $out.Add((New-MigHtmlFinding -Rule 'linkedAssets' -RelPath $rel -Severity 'warning' -Code 'outside_root' `
                        -Detail ("{0}='{1}' points above the migration root; cannot be verified" -f $a.attr, $a.value) -ParityFact $a.value))
                }
                continue
            }
            $target = $res.rel_path
            $ok = $false
            if ($null -ne $known -and $known.Contains($target)) { $ok = $true }
            elseif (-not $exists.TryGetValue($target, [ref]$ok)) {
                $full = Get-MigHtmlFullPath -Ctx $Ctx -Root $Root -RelPath $target
                $ok = ([System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full))
                $exists[$target] = $ok
            }
            if (-not $ok -and $seen.Add('missing|' + $target)) {
                $out.Add((New-MigHtmlFinding -Rule 'linkedAssets' -RelPath $rel -Severity 'error' -Code 'missing_asset' `
                    -Detail ("missing asset '{0}' ({1}='{2}')" -f $target, $a.attr, $a.value) -ParityFact $target))
            }
        }
    }
    return , $out.ToArray()
}
