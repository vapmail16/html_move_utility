# HtmlRule 'renderSample': opens a deterministic sample of HTML files per batch and confirms they render.
# Sample: every HTML rel_path is ranked by SHA-256("<seed>|<batchId>|<lower rel_path>"); the lowest
#   max(minPerBatch, ceil(rate * n)) are taken (capped at n), in one pass (top-k, no full sort).
#   The stage computes the sample ONCE from the INTERSECTION of source and target HTML rel_paths and passes it
#   as $Options._sample, so both sides render exactly the same files: an extra or missing file on one side
#   cannot shift the sample (missing/extra files are Reconcile's job). Called without _sample (e.g. directly),
#   the rule samples its own records.
# Renderer:
#   'parse'        : readable, decodable, not binary, contains element tags, comments closed. Files above
#                    malformed.maxBytesToParse are reported as 'skipped_large' (warning), not as rendered.
#   'edgeHeadless' : msedge --headless --dump-dom (edgePath, else msedge on PATH) with timeoutSec. When Edge is
#                    not available it falls back to 'parse' with a warning, or fails when strictRenderer = true.
# Every sampled file yields a finding: 'render_ok' (info), 'render_failed' (error) or 'skipped_large' (warning).

function Test-MigHtmlParseRender {
    <# Returns $null when the read result 'renders' for the parse renderer, else a reason. $Read: Read-MigHtmlText shape (not too_large). #>
    param([Parameter(Mandatory = $true)] $Read)
    if (-not $Read.ok) { return "unreadable: $($Read.error)" }
    if ($Read.binary) { return 'binary content' }
    if ([string]::IsNullOrWhiteSpace($Read.text)) { return 'empty' }
    if (-not [regex]::IsMatch($Read.text, '<[A-Za-z][A-Za-z0-9:-]*(\s[^>]*)?/?>')) { return 'no HTML elements found' }
    $open = [regex]::Matches($Read.text, '<!--').Count
    $close = [regex]::Matches($Read.text, '-->').Count
    if ($open -gt $close) { return 'unterminated comment' }
    return $null
}

function Find-MigEdgePath {
    param($Options)
    $p = [string](Get-MigHtmlOption $Options 'edgePath' '')
    if ($p) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        return $null
    }
    $cmd = Get-Command -Name 'msedge' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-MigHtmlEdgeRender {
    <# Returns $null when Edge dumps a DOM within the timeout, else a reason. #>
    param([Parameter(Mandatory = $true)][string] $EdgePath, [Parameter(Mandatory = $true)][string] $Path, [int] $TimeoutSec = 30)
    $uri = (New-Object System.Uri((Remove-MigLongPathPrefix $Path))).AbsoluteUri
    $profileDir = Join-Path ([System.IO.Path]::GetTempPath()) ('mig-edge-' + [guid]::NewGuid().ToString('N'))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $EdgePath
    $psi.Arguments = ('--headless --disable-gpu --no-first-run --user-data-dir="{0}" --dump-dom "{1}"' -f $profileDir, $uri)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
            try { $proc.Kill() } catch { }
            return "timed out after $TimeoutSec s"
        }
        $dom = $stdout.Result
        if ($proc.ExitCode -ne 0) { return "msedge exit code $($proc.ExitCode)" }
        if ([string]::IsNullOrWhiteSpace($dom) -or $dom.IndexOf('<') -lt 0) { return 'no DOM produced' }
        return $null
    } catch {
        return "msedge failed: $($_.Exception.Message)"
    } finally {
        if ($proc) { $proc.Dispose() }
        try { if (Test-Path -LiteralPath $profileDir) { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

function Get-MigHtmlRenderSample {
    <#
    Deterministic sample of rel_paths (see header): single pass, keeps the k lowest "<rank>|<lower rel_path>" keys
    in a SortedSet (O(n log k)); duplicates differing only in case count once. Returned in rank order.
    #>
    param([string[]] $RelPaths, [double] $Rate, [int] $MinPerBatch, [string] $Seed, [string] $BatchId)
    $unique = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($RelPaths)) { if ($p -and -not $unique.ContainsKey($p)) { $unique[$p] = $p } }
    $n = $unique.Count
    if ($n -eq 0) { return @() }
    $k = [int][Math]::Ceiling($Rate * $n)
    if ($k -lt $MinPerBatch) { $k = $MinPerBatch }
    if ($k -gt $n) { $k = $n }
    if ($k -le 0) { return @() }
    $top = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    $byKey = @{}
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $utf8 = [System.Text.Encoding]::UTF8
        foreach ($p in $unique.Keys) {
            # Same value as Get-MigHtmlStableRank, with one hash instance for the whole pass.
            $rank = ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes(('{0}|{1}|{2}' -f $Seed, $BatchId, $p.ToLowerInvariant()))))).Replace('-', '')
            $key = $rank + '|' + $p.ToLowerInvariant()
            if ($top.Count -lt $k) {
                [void]$top.Add($key); $byKey[$key] = $p
            } elseif ([string]::CompareOrdinal($key, $top.Max) -lt 0) {
                $drop = $top.Max
                [void]$top.Remove($drop); $byKey.Remove($drop)
                [void]$top.Add($key); $byKey[$key] = $p
            }
        }
    } finally { $sha.Dispose() }
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $top) { $out.Add([string]$byKey[$key]) }
    return $out.ToArray()
}

Register-MigProvider -Kind HtmlRule -Name 'renderSample' -ScriptBlock {
    param($Ctx, $BatchId, $Side, $Root, $Records, $Options)
    $files = Get-MigHtmlFileRecords -Ctx $Ctx -Records $Records
    $given = Get-MigHtmlOption $Options '_sample'
    if ($null -ne $given) {
        # Shared sample from the stage: render the entries present in this call's records.
        $inRecords = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $files) { [void]$inRecords.Add([string]$f['rel_path']) }
        $sample = New-Object 'System.Collections.Generic.List[string]'
        foreach ($p in @($given)) { if ($p -and $inRecords.Contains([string]$p)) { $sample.Add([string]$p) } }
        $sample = $sample.ToArray()
    } else {
        $rels = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $files) { $rels.Add([string]$f['rel_path']) }
        $sample = @(Get-MigHtmlRenderSample -RelPaths $rels.ToArray() `
            -Rate ([double](Get-MigHtmlOption $Options 'rate' 0)) -MinPerBatch ([int](Get-MigHtmlOption $Options 'minPerBatch' 0)) `
            -Seed ([string](Get-MigHtmlOption $Options 'seed' '')) -BatchId ([string]$BatchId))
    }
    if (@($sample).Count -eq 0) { return @() }

    $renderer = [string](Get-MigHtmlOption $Options 'renderer' 'parse')
    $timeout = [int](Get-MigHtmlOption $Options 'timeoutSec' 30)
    $strict = [bool](Get-MigHtmlOption $Options 'strictRenderer' $false)
    $edge = $null
    if ($renderer -eq 'edgeHeadless') {
        $edge = Find-MigEdgePath -Options $Options
        if (-not $edge) {
            if ($strict) {
                throw "renderSample: Microsoft Edge not found (htmlChecks.rules.renderSample.edgePath / PATH) and strictRenderer is true. Install Edge, set edgePath, or set strictRenderer = false to fall back to the 'parse' renderer."
            }
            Write-Warning "renderSample: Microsoft Edge not found (htmlChecks.rules.renderSample.edgePath / PATH); falling back to the 'parse' renderer."
            $renderer = 'parse'
        }
    } elseif ($renderer -ne 'parse') {
        throw "htmlChecks.rules.renderSample.renderer '$renderer' is not supported. Use 'parse' or 'edgeHeadless'."
    }
    $max = Get-MigHtmlMaxParseBytes -Ctx $Ctx

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($rel in $sample) {
        if ($renderer -eq 'edgeHeadless') {
            $why = Test-MigHtmlEdgeRender -EdgePath $edge -Path (Get-MigHtmlFullPath -Ctx $Ctx -Root $Root -RelPath $rel) -TimeoutSec $timeout
        } else {
            $read = Get-MigHtmlContent -Ctx $Ctx -Root $Root -RelPath $rel -MaxBytes $max -Options $Options
            if ($read.too_large) { $out.Add((New-MigHtmlSkippedLarge -Rule 'renderSample' -RelPath $rel -Size $read.size -MaxBytes $max)); continue }
            $why = Test-MigHtmlParseRender -Read $read
        }
        if ($null -eq $why) {
            $out.Add((New-MigHtmlFinding -Rule 'renderSample' -RelPath $rel -Severity 'info' -Code 'render_ok' -Detail ("sampled; renders ({0})" -f $renderer)))
        } else {
            $out.Add((New-MigHtmlFinding -Rule 'renderSample' -RelPath $rel -Severity 'error' -Code 'render_failed' -Detail ("sampled; does not render ({0}): {1}" -f $renderer, $why)))
        }
    }
    return , $out.ToArray()
}
