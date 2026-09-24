# Report provider 'html': one self-contained HTML file (<base>.html): inline CSS, no scripts, no external assets.
# Every value is HTML-encoded. Sections: status banner, run details, totals, then every table of the report in a
# fixed order (acceptance, batches, pilot estimate, governance, mismatches, issues, exceptions, HTML findings,
# gates, audit/robocopy logs, manifests, evidence manifest), then any other table.
# Tables show at most report.htmlMaxRows rows (default 2000) plus a "N more rows in <csv>" note.

function ConvertTo-MigHtmlEncoded {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode((Format-MigRptCell $Value))
}

function Format-MigHtmlBytes {
    param($Bytes)
    if ($null -eq $Bytes -or [string]$Bytes -eq '') { return '' }
    $b = [double]$Bytes
    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $i = 0
    while ($b -ge 1024 -and $i -lt $units.Count - 1) { $b = $b / 1024; $i++ }
    return ('{0} {1}' -f $b.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture), $units[$i])
}

function ConvertTo-MigHtmlTable {
    <#
    One table section. At most $MaxRows rows are rendered (<= 0: all); the rest are summarised in a note that
    points to the CSV file, which always has every row.
    #>
    param([Parameter(Mandatory = $true)] $Table, [string] $Id, [int] $MaxRows = 0, [string] $CsvName, [bool] $CsvWritten = $true)
    $sb = New-Object System.Text.StringBuilder
    $rows = @($Table.rows)
    [void]$sb.Append('<section id="').Append((ConvertTo-MigHtmlEncoded $Id)).Append('"><h2>').Append((ConvertTo-MigHtmlEncoded $Table.title))
    [void]$sb.Append(' <span class="count">(').Append($rows.Count).Append(')</span></h2>')
    if ($rows.Count -eq 0) { [void]$sb.Append('<p class="empty">None.</p></section>'); return $sb.ToString() }
    $shown = $rows.Count
    if ($MaxRows -gt 0 -and $shown -gt $MaxRows) { $shown = $MaxRows }
    [void]$sb.Append('<div class="scroll"><table><thead><tr>')
    foreach ($c in @($Table.columns)) { [void]$sb.Append('<th>').Append((ConvertTo-MigHtmlEncoded $c)).Append('</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    for ($i = 0; $i -lt $shown; $i++) {
        $r = $rows[$i]
        [void]$sb.Append('<tr>')
        foreach ($c in @($Table.columns)) {
            $v = [string]$r[$c]
            $cls = ''
            if ($v -eq 'false' -or $v -eq 'open' -or $v -eq 'error' -or $v -eq 'rejected' -or $v -eq 'pending') { $cls = ' class="bad"' }
            elseif ($v -eq 'true' -or $v -eq 'approved' -or $v -eq 'resolved' -or $v -eq 'accepted' -or $v -eq 'signed') { $cls = ' class="good"' }
            [void]$sb.Append('<td').Append($cls).Append('>').Append((ConvertTo-MigHtmlEncoded $v)).Append('</td>')
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    if ($shown -lt $rows.Count) {
        $more = $rows.Count - $shown
        if ($CsvWritten -and $CsvName) { $note = '{0} more rows in {1}' -f $more, $CsvName }
        else { $note = "{0} more rows not shown (add 'csv' to report.formats for the full list)" -f $more }
        [void]$sb.Append('<p class="more">').Append((ConvertTo-MigHtmlEncoded $note)).Append('</p>')
    }
    [void]$sb.Append('</section>')
    return $sb.ToString()
}

$script:MigHtmlReportCss = @'
:root { --fg:#1b1f24; --muted:#5b6570; --bg:#ffffff; --panel:#f5f7f9; --line:#d8dee4; --good:#1a7f37; --good-bg:#dafbe1; --bad:#b42318; --bad-bg:#fee4e2; --warn:#8a5a00; --warn-bg:#fff4d6; --info-bg:#e6f0ff; --info:#1f4b99; }
* { box-sizing: border-box; }
body { margin: 0; padding: 24px 16px; font: 14px/1.45 "Segoe UI", system-ui, -apple-system, Arial, sans-serif; color: var(--fg); background: var(--bg); }
main { max-width: 1200px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 12px; }
h2 { font-size: 16px; margin: 28px 0 8px; border-bottom: 1px solid var(--line); padding-bottom: 4px; }
.count, .empty, .meta dt { color: var(--muted); }
.banner { padding: 14px 18px; border-radius: 6px; font-size: 18px; font-weight: 600; margin-bottom: 16px; }
.banner.PASS { background: var(--good-bg); color: var(--good); }
.banner.FAIL { background: var(--bad-bg); color: var(--bad); }
.banner.INCOMPLETE { background: var(--warn-bg); color: var(--warn); }
.banner.PLAN { background: var(--info-bg); color: var(--info); }
.meta { display: grid; grid-template-columns: max-content 1fr; gap: 2px 16px; margin: 0; }
.meta dd { margin: 0; word-break: break-all; }
.cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 10px; }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 10px 12px; }
.card .k { color: var(--muted); font-size: 12px; }
.card .v { font-size: 18px; font-weight: 600; font-variant-numeric: tabular-nums; }
.scroll { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
th, td { border: 1px solid var(--line); padding: 4px 6px; text-align: left; vertical-align: top; }
th { background: var(--panel); position: sticky; top: 0; }
td { word-break: break-word; }
td.good { color: var(--good); font-weight: 600; }
td.bad { color: var(--bad); font-weight: 600; }
.more { color: var(--warn); font-style: italic; }
footer { margin-top: 32px; color: var(--muted); font-size: 12px; }
'@

Register-MigProvider -Kind Report -Name 'html' -ScriptBlock {
    param($Ctx, $Report, $OutDir, $BaseName)
    $e = { param($v) ConvertTo-MigHtmlEncoded $v }
    $t = $Report.totals
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.Append('<title>').Append((& $e $Report.title)).Append('</title><style>').Append($script:MigHtmlReportCss).Append('</style></head><body><main>')
    [void]$sb.Append('<h1>').Append((& $e $Report.title)).Append('</h1>')

    $status = [string]$Report.status
    $msg = switch ($status) {
        'PASS' { 'PASS: every check in this report passed.' }
        'FAIL' { 'FAIL: one or more checks did not pass. See the sections below.' }
        'INCOMPLETE' { 'INCOMPLETE: not every batch has been reconciled yet.' }
        default { 'PLAN: dry run / plan only. Nothing has been copied.' }
    }
    if ($Report.dry_run) { $msg += ' (dry run)' }
    [void]$sb.Append('<div class="banner ').Append((& $e $status)).Append('">').Append((& $e $msg)).Append('</div>')

    [void]$sb.Append('<dl class="meta">')
    foreach ($k in @('report_type', 'batch_id', 'generated_utc', 'run_id', 'operator', 'host', 'dry_run', 'module_version', 'source_root', 'target_root', 'config_path', 'config_hash')) {
        [void]$sb.Append('<dt>').Append((& $e $k)).Append('</dt><dd>').Append((& $e $Report[$k])).Append('</dd>')
    }
    [void]$sb.Append('</dl>')

    [void]$sb.Append('<h2>Totals</h2><div class="cards">')
    $cards = @(
        @('Batches', $t.batches), @('Batches reconciled', $t.batches_reconciled), @('Batches passed', $t.batches_passed),
        @('Planned files', $t.planned_files), @('Planned size', (Format-MigHtmlBytes $t.planned_bytes)),
        @('Source files', $t.source_files), @('Target files', $t.target_files),
        @('Source size', (Format-MigHtmlBytes $t.source_bytes)), @('Target size', (Format-MigHtmlBytes $t.target_bytes)),
        @('Source bytes', $t.source_bytes), @('Target bytes', $t.target_bytes),
        @('Source folders', $t.source_dirs), @('Target folders', $t.target_dirs),
        @('Missing', $t.missing), @('Extra', $t.extra), @('Hash mismatches', $t.hash_mismatch), @('Size mismatches', $t.size_mismatch),
        @('Metadata mismatches', $t.metadata_mismatch), @('Scan errors', $t.scan_errors), @('Extra outside batches', (Get-MigRptValue $t 'extra_outside_batches' '')),
        @('HTML findings (source)', $t.html_source_findings), @('HTML findings (target)', $t.html_target_findings),
        @('HTML parity differences', $t.html_parity_differences), @('Exceptions open', $t.exceptions_open), @('Exceptions total', $t.exceptions_total)
    )
    if ($Report.Contains('pilot_estimate')) { $cards += , @('Estimated remaining copy time', $Report.pilot_estimate) }
    foreach ($c in $cards) {
        [void]$sb.Append('<div class="card"><div class="k">').Append((& $e $c[0])).Append('</div><div class="v">').Append((& $e $c[1])).Append('</div></div>')
    }
    [void]$sb.Append('</div>')

    $maxRows = [int](Get-MigValue $Ctx.Config.report 'htmlMaxRows' 2000)
    $csvOn = @($Ctx.Config.report.formats) -contains 'csv'
    $order = @('acceptance', 'summary', 'pilot_estimate', 'signoff', 'freeze', 'retention', 'gate_overrides', 'orphans', 'mismatches_by_category',
        'issues', 'exceptions_summary', 'exceptions', 'html_findings_by_rule', 'html_parity', 'html_findings', 'gates', 'audit_logs', 'robocopy_logs',
        'manifest_checksums', 'evidence_manifest')
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in $order) { if ($Report.tables.Contains($name)) { $names.Add($name) } }
    foreach ($name in @($Report.tables.Keys)) { if (-not $names.Contains([string]$name)) { $names.Add([string]$name) } }
    foreach ($name in $names) {
        $tbl = $Report.tables[$name]
        $external = [bool](Get-MigRptValue $tbl 'external_csv' $false)
        $csvName = Get-MigCsvFileName -Table $tbl -Name $name -BaseName $BaseName
        [void]$sb.Append((ConvertTo-MigHtmlTable -Table $tbl -Id $name -MaxRows $maxRows -CsvName $csvName -CsvWritten ($csvOn -or $external)))
    }
    [void]$sb.Append('<footer>Generated ').Append((& $e $Report.generated_utc)).Append(' UTC by NotificationMigration ').Append((& $e $Report.module_version))
    [void]$sb.Append('. Each report file has a checksum sidecar next to it.</footer></main></body></html>')

    $path = Join-Path $OutDir ('{0}.html' -f $BaseName)
    [System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return @($path)
}
