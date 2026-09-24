#Requires -Modules Pester
# Unit tests for Stages/Report.ps1 and Providers/Report/*.ps1.
# Batch info, stage events, manifests, result files, HTML findings, exceptions and gate records are written directly
# in the formats of docs/ARCHITECTURE.md, so no other stage is needed.

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
    $script:mod = Get-Module NotificationMigration

    function New-Ctx {
        param([string] $Name, [hashtable] $Override = @{}, [string] $Operator = 'maker')
        $root = Join-Path $TestDrive $Name
        $src = Join-Path $root 'src'; $tgt = Join-Path $root 'tgt'; $work = Join-Path $root 'work'
        foreach ($d in @($src, $tgt, $work)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $path = Join-Path $root 'migration.config.json'
        if (-not (Test-Path -LiteralPath $path)) {
            $cfg = @{
                paths      = @{ sourceRoot = $src; targetRoot = $tgt; workDir = $work }
                inventory  = @{ aclReader = 'none' }
                compare    = @{ fileFields = @('exists', 'size', 'hash', 'modified'); dirFields = @('exists') }
                copy       = @{ engine = 'dotnet' }
                htmlChecks = @{ rules = @{ absoluteLinks = @{ oldHosts = @('ServerA') } } }
                report     = @{ formats = @('csv', 'html', 'json'); finalTargetSweep = $false }
            }
            [System.IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json -Depth 10))
        }
        return (& $script:mod { param($p, $o, $op) New-MigContext -ConfigPath $p -Override $o -Operator $op } $path $Override $Operator)
    }
    function Close-Ctx { param($Ctx) & $script:mod { param($c) Close-MigContext -Ctx $c } $Ctx }

    function Add-Inventory { param($Ctx, [long] $Files = 3, [long] $Bytes = 100, [string] $RunId = 'inv1', [string[]] $Affected)
        & $script:mod { param($c, $f, $b, $r, $a)
            $sum = [ordered]@{ files = $f; bytes = $b }
            if ($null -ne $a) { $sum['affected_batches'] = [string[]]$a }
            Add-MigStageEvent -Store $c.Store -Stage Inventory -Scope global -State completed -RunId $r -Operator 'maker' -Summary $sum
        } $Ctx $Files $Bytes $RunId $Affected
    }

    function Add-Plan {
        <# Batch info 'planned' + a source manifest of 3 files (100 bytes) and 1 folder. #>
        param($Ctx, [string] $BatchId = 'B1', [switch] $NoBatchInfo)
        & $script:mod { param($c, $b, $noInfo)
            if (-not $noInfo) {
                Set-MigBatchInfo -Store $c.Store -BatchId $b -Data @{ state = 'planned'; plan = @{ file_count = 3; dir_count = 1; total_bytes = 100; zero_byte_count = 0; error_count = 0 } }
            }
            Write-MigManifest -Store $c.Store -BatchId $b -Side source -Records @(
                [ordered]@{ rel_path = "$b"; kind = 'dir'; batch_id = $b; side = 'source' },
                [ordered]@{ rel_path = "$b\a.html"; kind = 'file'; batch_id = $b; side = 'source'; size_bytes = 10 },
                [ordered]@{ rel_path = "$b\b.html"; kind = 'file'; batch_id = $b; side = 'source'; size_bytes = 30 },
                [ordered]@{ rel_path = "$b\b.html"; kind = 'file'; batch_id = $b; side = 'source'; size_bytes = 40 },
                [ordered]@{ rel_path = "$b\c.html"; kind = 'file'; batch_id = $b; side = 'source'; size_bytes = 50 })
        } $Ctx $BatchId ([bool]$NoBatchInfo)
    }

    function Add-Reconciled {
        <#
        Copy -> Verify -> Reconcile -> HtmlChecks for one batch, in stage-event order, with an approved (audit-provable)
        HtmlChecks gate. An older run's issue/finding is always present and must be ignored.
        Options: Dirty (hash mismatch + open exception), NoGateApproval, HandGate (gate without audit ref),
        ParityFalse, Override (approved override gate), ExtraIssues n, ResultsFile (per-run file names), Rec (extra
        reconcile keys), NoCopySummary.
        #>
        param($Ctx, [string] $BatchId = 'B1', [hashtable] $Options = @{})
        & $script:mod { param($c, $b, $o)
            $s = $c.Store
            function Get-Opt([string] $k, $d = $null) { if ($o.ContainsKey($k)) { return $o[$k] } return $d }
            Add-MigStageEvent -Store $s -Stage Copy -Scope $b -State completed -RunId "c-$b" -Operator 'maker' -Summary ([ordered]@{ files_copied = 3; bytes_copied = 100; elapsed_sec = 2 })
            Set-MigBatchInfo -Store $s -BatchId $b -Data @{ state = 'copied'; copy = @{ files_attempted = 3; files_copied = 3; files_failed = 0; exit_codes = @(1); log_files = @('x.log') } }
            Add-MigStageEvent -Store $s -Stage Verify -Scope $b -State completed -RunId "v-$b" -Operator 'maker'
            Set-MigBatchInfo -Store $s -BatchId $b -Data @{ state = 'verified'; verify = @{ files = 3; dirs = 1; bytes = 100; errors = 0 } }
            Add-MigFileStatus -Store $s -BatchId $b -RunId "v-$b" -Events @(
                @{ rel_path = "$b\a.html"; status = 'verified' }, @{ rel_path = "$b\b.html"; status = 'verified' }, @{ rel_path = "$b\c.html"; status = 'verified' })

            Add-MigStoreRecords -Store $s -BatchId $b -Name 'reconcile.results.jsonl' -Records @(
                [ordered]@{ run_id = 'rOld'; rel_path = 'old\stale.html'; kind = 'file'; category = 'missing'; field = 'exists'; source_value = 'True'; target_value = 'False'; detail = 'old run'; ts_utc = Get-MigUtcNow })
            $resultsName = 'reconcile.results.jsonl'
            if (Get-Opt 'ResultsFile') { $resultsName = 'reconcile.results.rNew.jsonl' }
            $hm = 0; $passed = $true
            $issues = New-Object System.Collections.Generic.List[object]
            if (Get-Opt 'Dirty') {
                $hm = 1; $passed = $false
                $issues.Add([ordered]@{ run_id = 'rNew'; rel_path = '2019\01\<script>alert(1)</script>.html'; kind = 'file'; category = 'hash_mismatch'; field = 'hash'; source_value = 'AA'; target_value = '=HYPERLINK("x")'; detail = 'content differs'; ts_utc = Get-MigUtcNow })
                $null = Add-MigException -Store $s -BatchId $b -RelPath '2019\01\<script>alert(1)</script>.html' -Category 'hash_mismatch' -Detail 'retries exhausted' -RunId 'rNew'
            }
            for ($i = 0; $i -lt [int](Get-Opt 'ExtraIssues' 0); $i++) {
                $issues.Add([ordered]@{ run_id = 'rNew'; rel_path = "$b\extra$i.html"; kind = 'file'; category = 'hash_mismatch'; field = 'hash'; detail = "extra $i"; ts_utc = Get-MigUtcNow })
            }
            foreach ($m in @(Get-Opt 'MetaPaths' @())) {
                $issues.Add([ordered]@{ run_id = 'rNew'; rel_path = $m; kind = 'file'; category = 'metadata_mismatch'; field = 'modified'; detail = 'mtime differs'; ts_utc = Get-MigUtcNow })
            }
            # Extras: target-only files (25 bytes each) + an extra_on_target exception with the given status.
            $extras = Get-Opt 'Extras' @{}
            foreach ($x in @($extras.Keys)) {
                $issues.Add([ordered]@{ run_id = 'rNew'; rel_path = $x; kind = 'file'; category = 'extra'; field = 'exists'; target_value = 'file'; detail = 'file exists on target but not in the source manifest'; ts_utc = Get-MigUtcNow })
                Write-MigManifest -Store $s -BatchId $b -Side target -Records @([ordered]@{ rel_path = $x; kind = 'file'; batch_id = $b; side = 'target'; size_bytes = 25 })
                $id = Add-MigException -Store $s -BatchId $b -RelPath ([string]$extras[$x].path) -Category 'extra_on_target' -Detail 'extra' -RunId 'rNew'
                if ($extras[$x].status -ne 'open') { Update-MigException -Store $s -Id $id -BatchId $b -Status $extras[$x].status -Resolution 'approved to remain' -By 'checker' }
            }
            if ($issues.Count -gt 0) { Add-MigStoreRecords -Store $s -BatchId $b -Name $resultsName -Records $issues.ToArray() }
            Add-MigStageEvent -Store $s -Stage Reconcile -Scope $b -State completed -RunId 'rNew' -Operator 'maker'
            $rec = [ordered]@{ passed = $passed; run_id = 'rNew'; source_files = 3; target_files = 3; source_bytes = 100; target_bytes = 100
                source_dirs = 1; target_dirs = 1; missing = 0; extra = 0; size_mismatch = 0; hash_mismatch = $hm + [int](Get-Opt 'ExtraIssues' 0); metadata_mismatch = @(Get-Opt 'MetaPaths' @()).Count; scan_errors = 0; retried = 0; exceptions_opened = $hm }
            if ($extras.Count -gt 0) { $rec['extra'] = $extras.Count; $rec['target_files'] = 3 + $extras.Count; $rec['target_bytes'] = 100 + 25 * $extras.Count }
            if (Get-Opt 'ResultsFile') { $rec['results_file'] = $resultsName }
            $extra = Get-Opt 'Rec' @{}
            foreach ($k in $extra.Keys) { $rec[$k] = $extra[$k] }
            Set-MigBatchInfo -Store $s -BatchId $b -Data @{ state = 'reconciled'; reconcile = $rec }

            $srcName = 'htmlchecks.source.jsonl'; $tgtName = 'htmlchecks.target.jsonl'
            if (Get-Opt 'ResultsFile') { $srcName = 'htmlchecks.source.hNew.jsonl'; $tgtName = 'htmlchecks.target.hNew.jsonl' }
            Add-MigStoreRecords -Store $s -BatchId $b -Name 'htmlchecks.source.jsonl' -Records @(
                [ordered]@{ run_id = 'hOld'; rule = 'zeroByte'; rel_path = 'old.html'; severity = 'warning'; detail = 'old' })
            Add-MigStoreRecords -Store $s -BatchId $b -Name $srcName -Records @(
                [ordered]@{ run_id = 'hNew'; rule = 'absoluteLinks'; rel_path = '2019\01\a.html'; severity = 'warning'; code = 'old_host'; detail = "link to old host 'ServerA': http://ServerA/x" })
            Add-MigStoreRecords -Store $s -BatchId $b -Name $tgtName -Records @(
                [ordered]@{ run_id = 'hNew'; rule = 'absoluteLinks'; rel_path = '2019\01\a.html'; severity = 'warning'; code = 'old_host'; detail = "link to old host 'ServerA': http://ServerA/x" })
            Add-MigStageEvent -Store $s -Stage HtmlChecks -Scope $b -State completed -RunId 'hNew' -Operator 'maker'
            $html = [ordered]@{ parity = (-not (Get-Opt 'ParityFalse' $false)); run_id = 'hNew'; source_findings = 1; target_findings = 1; parity_differences = 0
                by_rule = @{ absoluteLinks = 2 }; by_rule_source = @{ absoluteLinks = 1 }; by_rule_target = @{ absoluteLinks = 1 } }
            if (Get-Opt 'ResultsFile') { $html['files'] = @{ source = $srcName; target = $tgtName; parity = 'htmlchecks.parity.hNew.jsonl' } }
            Set-MigBatchInfo -Store $s -BatchId $b -Data @{ htmlChecks = $html }
            if (-not (Get-Opt 'NoGateApproval' $false)) {
                $g = [ordered]@{ stage = 'HtmlChecks'; scope = $b; run_id = 'hNew'; maker = 'maker'; checker = 'checker'; decision = 'approved'; comment = 'ok <b>'
                                 override = [bool](Get-Opt 'Override' $false); ts_utc = Get-MigUtcNow }
                if (-not (Get-Opt 'HandGate' $false)) {
                    Write-MigAudit -Audit $c.Audit -Operator 'checker' -Event 'gate.decision' -Data $g
                    $g['audit_ref'] = $c.Audit.LastRef
                }
                Add-MigStoreRecord -Store $s -Name 'gates.jsonl' -Record $g
            }
        } $Ctx $BatchId $Options
    }

    function Add-Event { param($Ctx, [string] $Stage, [string] $Scope, [string] $RunId, [hashtable] $Summary)
        & $script:mod { param($c, $st, $sc, $r, $sum) Add-MigStageEvent -Store $c.Store -Stage $st -Scope $sc -State completed -RunId $r -Operator 'maker' -Summary $sum } $Ctx $Stage $Scope $RunId $Summary
    }
    function Set-Info { param($Ctx, [string] $BatchId, [hashtable] $Data)
        & $script:mod { param($c, $b, $d) Set-MigBatchInfo -Store $c.Store -BatchId $b -Data $d } $Ctx $BatchId $Data
    }
    function Add-Rec { param($Ctx, [string] $Name, [hashtable] $Record, [string] $BatchId)
        & $script:mod { param($c, $n, $r, $b) if ($b) { Add-MigStoreRecord -Store $c.Store -BatchId $b -Name $n -Record $r } else { Add-MigStoreRecord -Store $c.Store -Name $n -Record $r } } $Ctx $Name $Record $BatchId
    }
    function Add-Exc { param($Ctx, [string] $BatchId, [string] $RelPath, [string] $Category, [string] $Status = 'open')
        & $script:mod { param($c, $b, $p, $cat, $st)
            $id = Add-MigException -Store $c.Store -BatchId $b -RelPath $p -Category $cat -Detail 'test' -RunId 'x'
            if ($st -ne 'open') { Update-MigException -Store $c.Store -Id $id -BatchId $b -Status $st -Resolution 'approved by owner' -By 'checker' }
        } $Ctx $BatchId $RelPath $Category $Status
    }

    function New-CleanFinal {
        <# Closed previous run + inventory + one clean batch, ready for a final report. #>
        param([string] $Name, [hashtable] $Override = @{}, [hashtable] $Options = @{})
        $prev = New-Ctx -Name $Name -Override $Override
        Close-Ctx $prev
        $c = New-Ctx -Name $Name -Override $Override
        Add-Inventory -Ctx $c
        Add-Plan -Ctx $c
        Add-Reconciled -Ctx $c -Options $Options
        return $c
    }

    function Invoke-Report { param($Ctx, [string] $BatchId, [switch] $Final)
        & $script:mod { param($c, $b, $f) Invoke-MigStageReport -Ctx $c -BatchId $b -Final:$f } $Ctx $BatchId ([bool]$Final)
    }
    function Get-ReportFile { param($Summary, [string] $Pattern) @($Summary.files | Where-Object { $_ -like $Pattern }) | Select-Object -First 1 }
    function Read-Json { param([string] $Path) Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    function Get-Ac { param($Summary)
        $j = Read-Json (Get-ReportFile $Summary '*.json')
        $ac = @{}; foreach ($r in $j.tables.acceptance.rows) { $ac[$r.id] = $r }
        return $ac
    }
}

Describe 'Invoke-MigStageReport: basics' {
    AfterEach { if ($script:ctx) { Close-Ctx $script:ctx; $script:ctx = $null } }

    It 'plan-only report (dry run: only Inventory/Batching ran) writes every format with checksum sidecars' {
        $script:ctx = New-Ctx -Name 'plan'
        Add-Inventory -Ctx $script:ctx
        Add-Plan -Ctx $script:ctx
        $s = Invoke-Report -Ctx $script:ctx -Final
        $s.report_type | Should -Be 'plan'
        $s.status | Should -Be 'PLAN'
        $s.final | Should -BeFalse
        $s.passed | Should -BeFalse
        $s.report_dir | Should -BeLike (Join-Path $script:ctx.Config._resolved.reportDir 'plan-*')
        $base = @($s.files | Where-Object { $_ -notlike '*.sha256' })
        foreach ($n in @('plan.summary.csv', 'plan.issues.csv', 'plan.exceptions.csv', 'plan.html_findings.csv', 'plan.html', 'plan.json')) {
            @($base | ForEach-Object { Split-Path $_ -Leaf }) | Should -Contain $n
        }
        foreach ($f in $base) {
            $side = "$f.sha256"
            $s.files | Should -Contain $side
            $want = ((Get-Content -LiteralPath $side -Raw).Trim() -split '\s+')[0]
            $want | Should -Be (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        }
        $j = Read-Json (Get-ReportFile $s '*.json')
        $j.totals.planned_files | Should -Be 3
        $j.totals.planned_bytes | Should -Be 100
        $j.pilot_estimate | Should -Be 'no throughput data yet'
        ($j.tables.pilot_estimate.rows | Where-Object { $_.metric -eq 'remaining_files' }).value | Should -Be '3'
        (Get-Content -LiteralPath (Get-ReportFile $s '*.html') -Raw) | Should -Match 'PLAN: dry run'
    }

    It 'batch report: latest-run issues and findings only, FAIL on mismatches, HTML-encoded, CSV-safe' {
        $script:ctx = New-Ctx -Name 'batchdirty'
        Add-Inventory -Ctx $script:ctx
        Add-Plan -Ctx $script:ctx
        Add-Reconciled -Ctx $script:ctx -Options @{ Dirty = $true }
        $s = Invoke-Report -Ctx $script:ctx -BatchId 'B1'
        $s.report_type | Should -Be 'batch'
        $s.status | Should -Be 'FAIL'
        $s.passed | Should -BeFalse
        $s.Contains('final') | Should -BeFalse
        $s.report_dir | Should -BeLike '*batch-B1-*'

        $j = Read-Json (Get-ReportFile $s '*.json')
        @($j.tables.issues.rows).Count | Should -Be 1
        $j.tables.issues.rows[0].category | Should -Be 'hash_mismatch'
        @($j.tables.html_findings.rows).Count | Should -Be 2
        @($j.tables.html_findings.rows | Where-Object { $_.rel_path -eq 'old.html' }).Count | Should -Be 0
        @($j.tables.exceptions.rows).Count | Should -Be 1
        $j.mismatches_by_category.hash_mismatch | Should -Be 1
        @($j.tables.gates.rows).Count | Should -Be 1
        $j.tables.summary.rows[0].fail_reasons | Should -Match 'reconcile did not pass'

        $html = Get-Content -LiteralPath (Get-ReportFile $s '*.html') -Raw
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $html | Should -Match 'ok &lt;b&gt;'
        $html | Should -Match 'class="banner FAIL"'
        $html | Should -Not -Match '<link|<script|src=|@import|url\('
        $html | Should -Match '<style>'

        $csv = Get-Content -LiteralPath (Get-ReportFile $s '*.issues.csv') -Raw
        $csv | Should -Match ([regex]::Escape('"''=HYPERLINK(""x"")"'))
        $rows = Import-Csv -LiteralPath (Get-ReportFile $s '*.issues.csv')
        @($rows).Count | Should -Be 1
        $rows[0].rel_path | Should -Be '2019\01\<script>alert(1)</script>.html'
        (Import-Csv -LiteralPath (Get-ReportFile $s '*.summary.csv'))[0].hash_mismatch | Should -Be '1'
    }

    It 'batch report passes when reconcile passed and is current, parity holds and no exception is open' {
        $script:ctx = New-Ctx -Name 'batchclean'
        Add-Inventory -Ctx $script:ctx
        Add-Plan -Ctx $script:ctx
        Add-Reconciled -Ctx $script:ctx
        $s = Invoke-Report -Ctx $script:ctx -BatchId 'B1'
        $s.status | Should -Be 'PASS'
        $s.passed | Should -BeTrue
    }

    It 'reads per-run result files named in batch info (reconcile.results_file, htmlChecks.files)' {
        $script:ctx = New-Ctx -Name 'perrun'
        Add-Inventory -Ctx $script:ctx
        Add-Plan -Ctx $script:ctx
        Add-Reconciled -Ctx $script:ctx -Options @{ Dirty = $true; ResultsFile = $true }
        $s = Invoke-Report -Ctx $script:ctx -BatchId 'B1'
        $j = Read-Json (Get-ReportFile $s '*.json')
        @($j.tables.issues.rows).Count | Should -Be 1
        $j.tables.issues.rows[0].category | Should -Be 'hash_mismatch'
        @($j.tables.html_findings.rows).Count | Should -Be 2
        @($j.tables.html_findings.rows | Where-Object { $_.side -eq 'target' }).Count | Should -Be 1
    }

    It 'unknown batch id fails clearly' {
        $script:ctx = New-Ctx -Name 'unknown'
        Add-Plan -Ctx $script:ctx
        { Invoke-Report -Ctx $script:ctx -BatchId 'NOPE' } | Should -Throw '*unknown batch*'
    }

    It 'writes only the configured formats' {
        $script:ctx = New-Ctx -Name 'formats' -Override @{ report = @{ formats = @('json') } }
        Add-Plan -Ctx $script:ctx
        $s = Invoke-Report -Ctx $script:ctx
        @($s.files | Where-Object { $_ -notlike '*.sha256' }).Count | Should -Be 1
        $s.files[0] | Should -BeLike '*.json'
    }

    It 'refuses to write reports under sourceRoot' {
        $script:ctx = New-Ctx -Name 'safety'
        Add-Plan -Ctx $script:ctx
        $script:ctx.Config._resolved.reportDir = Join-Path $script:ctx.Config.paths.sourceRoot 'reports'
        { Invoke-Report -Ctx $script:ctx } | Should -Throw '*SAFETY*'
        Test-Path -LiteralPath (Join-Path $script:ctx.Config.paths.sourceRoot 'reports') | Should -BeFalse
    }

    It 'caps HTML tables at report.htmlMaxRows with a note; the CSV keeps every row' {
        $script:ctx = New-Ctx -Name 'rowcap' -Override @{ report = @{ htmlMaxRows = 2 } }
        Add-Inventory -Ctx $script:ctx
        Add-Plan -Ctx $script:ctx
        Add-Reconciled -Ctx $script:ctx -Options @{ ExtraIssues = 5 }
        $s = Invoke-Report -Ctx $script:ctx -BatchId 'B1'
        $html = Get-Content -LiteralPath (Get-ReportFile $s '*.html') -Raw
        $sec = [regex]::Match($html, '<section id="issues">.*?</section>').Value
        $sec | Should -Match '\(5\)'
        ([regex]::Matches($sec, '<tr>')).Count | Should -Be 3   # header + 2 rows
        $sec | Should -Match '3 more rows in batch-B1\.issues\.csv'
        @(Import-Csv -LiteralPath (Get-ReportFile $s '*.issues.csv')).Count | Should -Be 5
    }

    It 'config defaults: htmlMaxRows 2000, finalIncludeDetails false, finalTargetSweep true' {
        $script:ctx = New-Ctx -Name 'defaults'
        $d = & $script:mod { Get-Content -LiteralPath (Join-Path $script:MigModuleRoot 'config/defaults.json') -Raw | ConvertFrom-Json }
        $d.report.htmlMaxRows | Should -Be 2000
        $d.report.finalIncludeDetails | Should -BeFalse
        $d.report.finalTargetSweep | Should -BeTrue
    }
}

Describe 'Invoke-MigStageReport -Final: acceptance' {
    AfterEach { if ($script:ctx) { Close-Ctx $script:ctx; $script:ctx = $null } }

    It 'clean migration: every criterion true, final=true, passed=true, governance and evidence present' {
        $script:ctx = New-CleanFinal -Name 'finalclean'
        & $script:mod { param($c) Add-MigStoreRecord -Store $c.Store -Name 'manifest.checksums.jsonl' -Record ([ordered]@{ batch_id = 'B1'; file = 'batches/B1/source.manifest.jsonl'; sha256 = 'ABC' }) } $script:ctx
        $s = Invoke-Report -Ctx $script:ctx -Final
        $s.report_type | Should -Be 'final'
        $s.final | Should -BeTrue
        $s.passed | Should -BeTrue
        $s.status | Should -Be 'PASS'
        $j = Read-Json (Get-ReportFile $s '*.json')
        $j.final | Should -BeTrue
        @($j.tables.acceptance.rows).Count | Should -Be 7
        foreach ($r in $j.tables.acceptance.rows) { $r.passed | Should -Be 'true' -Because "$($r.id) $($r.criterion): $($r.detail)" }
        ($j.tables.acceptance.rows | Where-Object id -eq 'AC-3').detail | Should -Match ([regex]::Escape('compared fields: files [exists, size, hash, modified], dirs [exists]'))
        ($j.tables.acceptance.rows | Where-Object id -eq 'AC-4').detail | Should -Match 'compared fields'
        ($j.tables.acceptance.rows | Where-Object id -eq 'AC-1').detail | Should -Match 'matches: manifests 3 files / 100 bytes'
        @($j.tables.audit_logs.rows).Count | Should -Be 2
        @($j.tables.audit_logs.rows | Where-Object { $_.current_run -eq 'true' }).Count | Should -Be 1
        @($j.tables.audit_logs.rows | Where-Object { $_.chain_valid -ne 'true' }).Count | Should -Be 0
        @($j.tables.manifest_checksums.rows | Where-Object { $_.origin -eq 'recorded' }).Count | Should -Be 1
        @($s.files | Where-Object { $_ -like '*final.acceptance.csv' }).Count | Should -Be 1
        # scale: the final report aggregates counts, per-file detail stays in batch reports
        $j.details_included | Should -BeFalse
        $j.tables.PSObject.Properties.Name | Should -Not -Contain 'issues'
        $j.tables.PSObject.Properties.Name | Should -Contain 'exceptions_summary'
        # evidence manifest: every store file, CSV with its own sidecar, no lock files
        $ev = Get-ReportFile $s '*evidence.manifest.csv'
        $ev | Should -Not -BeNullOrEmpty
        $s.files | Should -Contain "$ev.sha256"
        $evRows = @(Import-Csv -LiteralPath $ev)
        $evRows.path | Should -Contain 'stages.jsonl'
        $evRows.path | Should -Contain 'batches/B1/source.manifest.jsonl'
        $evRows.path | Should -Contain 'auditcheck.jsonl'
        @($evRows | Where-Object { $_.path -like 'locks/*' }).Count | Should -Be 0
        ($evRows | Where-Object path -eq 'stages.jsonl').checksum | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:ctx.Store.Root 'stages.jsonl') -Algorithm SHA256).Hash
        # governance sections
        @($j.tables.signoff.rows).Count | Should -Be 3
        @($j.tables.signoff.rows | Where-Object status -eq 'pending').Count | Should -Be 3
        $j.tables.freeze.rows[0].frozen | Should -Be 'not recorded'
        $j.tables.PSObject.Properties.Name | Should -Contain 'retention'
        $j.tables.PSObject.Properties.Name | Should -Contain 'gate_overrides'
        $j.tables.PSObject.Properties.Name | Should -Contain 'orphans'
        $j.pilot_estimate | Should -Not -Be 'no throughput data yet'
    }

    It 'final with finalIncludeDetails lists per-file issues' {
        $script:ctx = New-CleanFinal -Name 'finaldetails' -Override @{ report = @{ finalIncludeDetails = $true } } -Options @{ Dirty = $true }
        $s = Invoke-Report -Ctx $script:ctx -Final
        $j = Read-Json (Get-ReportFile $s '*.json')
        $j.details_included | Should -BeTrue
        @($j.tables.issues.rows).Count | Should -Be 1
    }

    It 'fails criteria for mismatches, open exceptions, unreviewed HTML checks and a tampered log' {
        $prev = New-Ctx -Name 'finaldirty'
        Close-Ctx $prev
        $log = $prev.Audit.Path
        $text = [System.IO.File]::ReadAllText($log).Replace('"maker"', '"mallory"')
        [System.IO.File]::WriteAllText($log, $text)
        $script:ctx = New-Ctx -Name 'finaldirty'
        Add-Inventory -Ctx $script:ctx
        Add-Plan -Ctx $script:ctx
        Add-Reconciled -Ctx $script:ctx -Options @{ Dirty = $true; NoGateApproval = $true }
        $s = Invoke-Report -Ctx $script:ctx -Final
        $s.status | Should -Be 'FAIL'
        $s.final | Should -BeTrue
        $s.passed | Should -BeFalse
        $ac = Get-Ac $s
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match 'B1 \[reconcile did not pass'
        $ac['AC-3'].passed | Should -Be 'false'
        $ac['AC-5'].passed | Should -Be 'false'
        $ac['AC-5'].detail | Should -Match 'not approved'
        $ac['AC-6'].passed | Should -Be 'false'
        $ac['AC-7'].passed | Should -Be 'false'
        $j = Read-Json (Get-ReportFile $s '*.json')
        @($j.tables.audit_logs.rows | Where-Object { $_.chain_valid -eq 'false' }).Count | Should -Be 1
    }

    It 'fails AC-1 when a batch was never reconciled' {
        $script:ctx = New-Ctx -Name 'finalpartial'
        Add-Inventory -Ctx $script:ctx -Files 6 -Bytes 200
        Add-Plan -Ctx $script:ctx -BatchId 'B1'
        Add-Reconciled -Ctx $script:ctx
        Add-Plan -Ctx $script:ctx -BatchId 'B2'
        $s = Invoke-Report -Ctx $script:ctx -Final
        $ac = Get-Ac $s
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match "B2 \[state is 'planned'"
        $ac['AC-5'].detail | Should -Match 'B2 \[HTML checks not run'
    }

    It 'FALSE PASS: a Delta completed after the reconcile fails the batch' {
        $script:ctx = New-CleanFinal -Name 'deltaafter'
        Add-Event -Ctx $script:ctx -Stage Delta -Scope global -RunId 'd1' -Summary @{ new = 0; changed = 0 }
        $s = Invoke-Report -Ctx $script:ctx -Final
        $s.passed | Should -BeFalse
        $ac = Get-Ac $s
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match 'Delta run d1 completed after reconcile run rNew and changed this batch'
        $ac['AC-3'].passed | Should -Be 'false'
        $ac['AC-4'].passed | Should -Be 'false'
        (Invoke-Report -Ctx $script:ctx -BatchId 'B1').status | Should -Be 'FAIL'
    }

    It 'a Delta affecting only B2 does not fail B1, but does fail B2 (affected_batches, as in the gates)' {
        $script:ctx = New-Ctx -Name 'deltascoped'
        Close-Ctx $script:ctx
        $script:ctx = New-Ctx -Name 'deltascoped'
        Add-Inventory -Ctx $script:ctx -Files 6 -Bytes 200
        Add-Plan -Ctx $script:ctx -BatchId 'B1'
        Add-Plan -Ctx $script:ctx -BatchId 'B2'
        Add-Reconciled -Ctx $script:ctx -BatchId 'B1'
        Add-Reconciled -Ctx $script:ctx -BatchId 'B2'
        (Get-Ac (Invoke-Report -Ctx $script:ctx -Final))['AC-1'].passed | Should -Be 'true'
        Add-Event -Ctx $script:ctx -Stage Delta -Scope global -RunId 'd2' -Summary @{ new = 1; changed = 0; affected_batches = @('B2'); source_files = 6; source_bytes = 200 }
        $s = Invoke-Report -Ctx $script:ctx -Final
        $j = Read-Json (Get-ReportFile $s '*.json')
        $rows = @{}; foreach ($r in $j.tables.summary.rows) { $rows[$r.batch_id] = $r }
        $rows['B1'].passed | Should -Be 'true' -Because $rows['B1'].fail_reasons
        $rows['B2'].passed | Should -Be 'false'
        $rows['B2'].fail_reasons | Should -Match 'Delta run d2 completed after reconcile run rNew and changed this batch'
        $ac = Get-Ac $s
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match 'B2 \['
        $ac['AC-1'].detail | Should -Not -Match 'B1 \['
        (Invoke-Report -Ctx $script:ctx -BatchId 'B1').status | Should -Be 'PASS'
        (Invoke-Report -Ctx $script:ctx -BatchId 'B2').status | Should -Be 'FAIL'
    }

    It 'an older Delta that changed B1 is not hidden by a newer Delta that only changed B2' {
        $script:ctx = New-CleanFinal -Name 'deltaolder'
        Add-Event -Ctx $script:ctx -Stage Delta -Scope global -RunId 'dA' -Summary @{ new = 0; changed = 1; affected_batches = @('B1') }
        Add-Event -Ctx $script:ctx -Stage Delta -Scope global -RunId 'dB' -Summary @{ new = 0; changed = 1; affected_batches = @('B2') }
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match 'Delta run dA completed after reconcile run rNew'
        $ac['AC-1'].detail | Should -Not -Match 'Delta run dB completed after'
    }

    It 'an Inventory whose affected_batches omit B1 does not fail B1' {
        $script:ctx = New-CleanFinal -Name 'invscoped'
        Add-Inventory -Ctx $script:ctx -RunId 'inv2' -Affected @()
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-1'].passed | Should -Be 'true' -Because $ac['AC-1'].detail
        $ac['AC-1'].detail | Should -Match 'vs Inventory run inv2'
    }

    It 'cross-check is strict against the latest Delta totals; "not verifiable" only for an old Delta summary' {
        $script:ctx = New-CleanFinal -Name 'deltatotals'
        Add-Event -Ctx $script:ctx -Stage Delta -Scope global -RunId 'd1' -Summary @{ new = 0; changed = 0; affected_batches = @(); source_files = 3; source_bytes = 100 }
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-1'].passed | Should -Be 'true' -Because $ac['AC-1'].detail
        $ac['AC-1'].detail | Should -Match 'matches: manifests 3 files / 100 bytes vs Delta run d1'
        Add-Event -Ctx $script:ctx -Stage Delta -Scope global -RunId 'd2' -Summary @{ new = 1; changed = 0; affected_batches = @(); source_files = 4; source_bytes = 120 }
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match 'MISMATCH: manifests 3 files / 100 bytes vs Delta run d2: 4 files / 120 bytes'
        $ac['AC-2'].passed | Should -Be 'false'
        # an old-format Delta (no totals) that changed nothing keeps the previous reference
        Add-Event -Ctx $script:ctx -Stage Delta -Scope global -RunId 'd3' -Summary @{ new = 0; changed = 0; affected_batches = @() }
        (Get-Ac (Invoke-Report -Ctx $script:ctx -Final))['AC-1'].detail | Should -Match 'vs Delta run d2'
        # an old-format Delta that changed something: fallback, not verifiable
        Add-Event -Ctx $script:ctx -Stage Delta -Scope global -RunId 'd4' -Summary @{ new = 2; changed = 0; affected_batches = @() }
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-1'].detail | Should -Match 'not verifiable: Delta run d4 changed the manifests after Delta run d2'
    }

    It 'FALSE PASS: Copy, Verify or Inventory after the reconcile, a stale flag, or unverified files fail the batch' {
        $script:ctx = New-CleanFinal -Name 'staleness'
        Add-Event -Ctx $script:ctx -Stage Copy -Scope 'B1' -RunId 'c2'
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-1'].detail | Should -Match 'Copy run c2 completed after reconcile run rNew'
        $ac['AC-5'].detail | Should -Match 'Copy run c2 completed after HtmlChecks run hNew'
        Close-Ctx $script:ctx; $script:ctx = $null

        $script:ctx = New-CleanFinal -Name 'staleinv'
        Add-Inventory -Ctx $script:ctx -RunId 'inv2'
        (Get-Ac (Invoke-Report -Ctx $script:ctx -Final))['AC-1'].detail | Should -Match 'Inventory run inv2 completed after reconcile'
        Close-Ctx $script:ctx; $script:ctx = $null

        $script:ctx = New-CleanFinal -Name 'staleflag' -Options @{ Rec = @{ stale = $true } }
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match 'reconcile is stale'
        Close-Ctx $script:ctx; $script:ctx = $null

        $script:ctx = New-CleanFinal -Name 'pendingfile'
        & $script:mod { param($c) Add-MigFileStatus -Store $c.Store -BatchId 'B1' -RunId 'x' -Events @(@{ rel_path = 'B1\b.html'; status = 'pending' }) } $script:ctx
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match '1 file\(s\) not verified \(pending 1'
    }

    It 'FALSE PASS: a reconcile run without a real completed Reconcile stage event does not count' {
        $script:ctx = New-CleanFinal -Name 'norecevent'
        Set-Info -Ctx $script:ctx -BatchId 'B1' -Data @{ reconcile = @{ passed = $true; run_id = 'forged'; source_files = 3; target_files = 3; source_bytes = 100; target_bytes = 100 } }
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match "reconcile run 'forged' has no completed real Reconcile stage event"
    }

    It 'FALSE PASS: a batch folder that is not in batches.jsonl fails; ORPHANS is reported separately' {
        $script:ctx = New-CleanFinal -Name 'folderonly'
        Add-Plan -Ctx $script:ctx -BatchId 'B9' -NoBatchInfo
        Add-Exc -Ctx $script:ctx -BatchId 'ORPHANS' -RelPath 'stray\x.html' -Category 'extra_on_target' -Status 'accepted'
        $s = Invoke-Report -Ctx $script:ctx -Final
        $s.passed | Should -BeFalse
        $ac = Get-Ac $s
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match 'B9 \[batch folder exists in the store but the batch is not in batches.jsonl'
        $j = Read-Json (Get-ReportFile $s '*.json')
        @($j.tables.summary.rows.batch_id) | Should -Not -Contain 'ORPHANS'
        @($j.tables.summary.rows.batch_id) | Should -Contain 'B9'
        @($j.tables.orphans.rows).Count | Should -Be 1
        $j.tables.orphans.rows[0].rel_path | Should -Be 'stray\x.html'
    }

    It 'FALSE PASS: manifest totals that differ from the latest Inventory summary fail AC-1 and AC-2' {
        $script:ctx = New-ctx -Name 'crosscheck'
        Close-Ctx $script:ctx
        $script:ctx = New-Ctx -Name 'crosscheck'
        Add-Inventory -Ctx $script:ctx -Files 5 -Bytes 180
        Add-Plan -Ctx $script:ctx
        Add-Reconciled -Ctx $script:ctx
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-1'].passed | Should -Be 'false'
        $ac['AC-1'].detail | Should -Match 'MISMATCH: manifests 3 files / 100 bytes vs Inventory run inv1: 5 files / 180 bytes'
        $ac['AC-2'].passed | Should -Be 'false'
    }

    It 'AC-4: a metadata mismatch needs an ACCEPTED exception with the same fingerprint' {
        $script:ctx = New-CleanFinal -Name 'meta' -Options @{ MetaPaths = @('B1\a.html') }
        # an accepted exception for ANOTHER path and a resolved (not accepted) one for the same path do not excuse it
        Add-Exc -Ctx $script:ctx -BatchId 'B1' -RelPath 'B1\other.html' -Category 'metadata_mismatch' -Status 'accepted'
        Add-Exc -Ctx $script:ctx -BatchId 'B1' -RelPath 'B1\a.html' -Category 'metadata_mismatch' -Status 'resolved'
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-4'].passed | Should -Be 'false'
        $ac['AC-4'].detail | Should -Match ([regex]::Escape('B1 (1: B1\a.html)'))
        # accepted, same fingerprint: covered
        $id = @(& $script:mod { param($c) Get-MigExceptions -Store $c.Store -BatchId 'B1' | Where-Object { $_['rel_path'] -eq 'B1\a.html' } } $script:ctx)[0]['id']
        & $script:mod { param($c, $i) Update-MigException -Store $c.Store -Id $i -BatchId 'B1' -Status accepted -Resolution 'owner accepts mtime drift' -By 'checker' } $script:ctx $id
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-4'].passed | Should -Be 'true' -Because $ac['AC-4'].detail
        $ac['AC-4'].detail | Should -Match 'metadata mismatches 1; covered by accepted exceptions 1'
    }

    It 'AC-1/2/3: an extra covered by an ACCEPTED exception is excluded and listed; open, resolved or other-path ones still fail' {
        $script:ctx = New-CleanFinal -Name 'extraacc' -Options @{ Extras = @{ 'B1\zz-extra.html' = @{ path = 'B1\zz-extra.html'; status = 'accepted' } } }
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        foreach ($k in @('AC-1', 'AC-2', 'AC-3')) { $ac[$k].passed | Should -Be 'true' -Because $ac[$k].detail }
        $ac['AC-1'].detail | Should -Match ([regex]::Escape('overall 3 / 3 (+1 accepted extra: B1\zz-extra.html)'))
        $ac['AC-2'].detail | Should -Match ([regex]::Escape('overall 100 / 100 bytes (+1 accepted extra'))
        $ac['AC-3'].detail | Should -Match 'extra 0 \(\+1 accepted extra'
        Close-Ctx $script:ctx; $script:ctx = $null

        foreach ($case in @(@{ n = 'extrares'; path = 'B1\zz-extra.html'; status = 'resolved' }, @{ n = 'extraopen'; path = 'B1\zz-extra.html'; status = 'open' },
                            @{ n = 'extraother'; path = 'B1\other.html'; status = 'accepted' })) {
            $script:ctx = New-CleanFinal -Name $case.n -Options @{ Extras = @{ 'B1\zz-extra.html' = @{ path = $case.path; status = $case.status } } }
            $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
            $ac['AC-1'].passed | Should -Be 'false' -Because $case.n
            $ac['AC-1'].detail | Should -Match 'overall 3 / 4; batches differing: B1'
            $ac['AC-2'].passed | Should -Be 'false' -Because $case.n
            $ac['AC-3'].passed | Should -Be 'false' -Because $case.n
            $ac['AC-3'].detail | Should -Match 'extra 1,'
            Close-Ctx $script:ctx; $script:ctx = $null
        }
    }

    It 'AC-5: parity=false fails; an approved override accepts it; a hand-written approval does not count' {
        $script:ctx = New-CleanFinal -Name 'parityfalse' -Options @{ ParityFalse = $true }
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-5'].passed | Should -Be 'false'
        $ac['AC-5'].detail | Should -Match 'parity=false'
        Close-Ctx $script:ctx; $script:ctx = $null

        $script:ctx = New-CleanFinal -Name 'parityoverride' -Options @{ ParityFalse = $true; Override = $true }
        $s = Invoke-Report -Ctx $script:ctx -Final
        $ac = Get-Ac $s
        $ac['AC-5'].passed | Should -Be 'true' -Because $ac['AC-5'].detail
        $ac['AC-5'].detail | Should -Match 'parity accepted by approved override: B1'
        $j = Read-Json (Get-ReportFile $s '*.json')
        @($j.tables.gate_overrides.rows).Count | Should -Be 1
        $j.tables.gate_overrides.rows[0].comment | Should -Be 'ok <b>'
        Close-Ctx $script:ctx; $script:ctx = $null

        $script:ctx = New-CleanFinal -Name 'handgate' -Options @{ HandGate = $true }
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-5'].passed | Should -Be 'false'
        $ac['AC-5'].detail | Should -Match 'no matching audit-log entry'
    }

    It 'AC-5 does not depend on HtmlChecks being listed in pipeline.gates' {
        $script:ctx = New-CleanFinal -Name 'nohtmlgate' -Override @{ pipeline = @{ gates = @('Inventory') } } -Options @{ NoGateApproval = $true }
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-5'].passed | Should -Be 'false'
        $ac['AC-5'].detail | Should -Match 'HtmlChecks run hNew is not approved'
    }

    It 'AC-5 fails on an open html_parity exception' {
        $script:ctx = New-CleanFinal -Name 'openparity'
        Add-Exc -Ctx $script:ctx -BatchId 'B1' -RelPath 'B1\a.html' -Category 'html_parity'
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-5'].detail | Should -Match '1 open html_parity exception'
        $ac['AC-5'].passed | Should -Be 'false'
    }
}

Describe 'Invoke-MigStageReport -Final: AC-7 evidence' {
    AfterEach { if ($script:ctx) { Close-Ctx $script:ctx; $script:ctx = $null } }

    It 'FALSE PASS: a robocopy log without a checksum sidecar (or with a wrong one) fails AC-7' {
        $script:ctx = New-CleanFinal -Name 'rclog'
        $rdir = Join-Path $script:ctx.Config._resolved.logDir 'robocopy'
        New-Item -ItemType Directory -Path $rdir -Force | Out-Null
        $good = Join-Path $rdir 'B1-good.log'; $bad = Join-Path $rdir 'B1-nosidecar.log'
        Set-Content -LiteralPath $good -Value 'robocopy output'
        Set-Content -LiteralPath $bad -Value 'robocopy output 2'
        "$((Get-FileHash -LiteralPath $good -Algorithm SHA256).Hash)  B1-good.log" | Set-Content -LiteralPath "$good.sha256"
        $s = Invoke-Report -Ctx $script:ctx -Final
        $ac = Get-Ac $s
        $ac['AC-7'].passed | Should -Be 'false'
        $ac['AC-7'].detail | Should -Match 'B1-nosidecar.log \(no checksum sidecar\)'
        $ac['AC-7'].detail | Should -Not -Match 'B1-good.log'
        $j = Read-Json (Get-ReportFile $s '*.json')
        @($j.tables.robocopy_logs.rows).Count | Should -Be 2

        "$((Get-FileHash -LiteralPath $bad -Algorithm SHA256).Hash)  B1-nosidecar.log" | Set-Content -LiteralPath "$bad.sha256"
        (Get-Ac (Invoke-Report -Ctx $script:ctx -Final))['AC-7'].passed | Should -Be 'true'

        Add-Content -LiteralPath $bad -Value 'tampered'
        $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
        $ac['AC-7'].passed | Should -Be 'false'
        $ac['AC-7'].detail | Should -Match 'does not match sidecar'
    }

    It 'lists logs sealed after an interruption as interrupted runs (still valid)' {
        $root = Join-Path $TestDrive 'interrupted'
        $prev = New-Ctx -Name 'interrupted'
        Close-Ctx $prev
        & $script:mod { param($dir)
            $a = New-MigAuditLog -LogDir $dir -RunId 'killed'
            Write-MigAudit -Audit $a -Event 'run.started' -Data @{ x = 1 }
            $a.Lock.Dispose()
        } $prev.Config._resolved.logDir
        $script:ctx = New-Ctx -Name 'interrupted'   # seals the orphaned log
        Add-Inventory -Ctx $script:ctx
        Add-Plan -Ctx $script:ctx
        Add-Reconciled -Ctx $script:ctx
        $s = Invoke-Report -Ctx $script:ctx -Final
        $ac = Get-Ac $s
        $ac['AC-7'].passed | Should -Be 'true' -Because $ac['AC-7'].detail
        $ac['AC-7'].detail | Should -Match 'interrupted runs \(sealed, valid\): run-.*-killed\.jsonl'
        $j = Read-Json (Get-ReportFile $s '*.json')
        @($j.tables.audit_logs.rows | Where-Object interrupted -eq 'true').Count | Should -Be 1
    }

    It 'caches verification of closed logs in store/auditcheck.jsonl and re-verifies a changed log' {
        $script:ctx = New-CleanFinal -Name 'auditcache'
        $s1 = Invoke-Report -Ctx $script:ctx -Final
        (Read-Json (Get-ReportFile $s1 '*.json')).tables.audit_logs.rows | Where-Object current_run -eq 'false' | ForEach-Object { $_.cached | Should -Be 'false' }
        Test-Path -LiteralPath (Join-Path $script:ctx.Store.Root 'auditcheck.jsonl') | Should -BeTrue
        $s2 = Invoke-Report -Ctx $script:ctx -Final
        $rows = @((Read-Json (Get-ReportFile $s2 '*.json')).tables.audit_logs.rows | Where-Object current_run -eq 'false')
        $rows.Count | Should -Be 1
        $rows[0].cached | Should -Be 'true'
        (Get-Ac $s2)['AC-7'].passed | Should -Be 'true'
        # tamper with the closed log: the cache key (sidecar hash + length + mtime) no longer matches -> re-verified -> invalid
        $log = Join-Path $script:ctx.Config._resolved.logDir $rows[0].file
        [System.IO.File]::AppendAllText($log, "{`"seq`":99}`n")
        $s3 = Invoke-Report -Ctx $script:ctx -Final
        $r3 = @((Read-Json (Get-ReportFile $s3 '*.json')).tables.audit_logs.rows | Where-Object file -eq $rows[0].file)[0]
        $r3.cached | Should -Be 'false'
        $r3.chain_valid | Should -Be 'false'
        (Get-Ac $s3)['AC-7'].passed | Should -Be 'false'
    }
}

Describe 'Invoke-MigStageReport -Final: governance, sweep and estimate' {
    AfterEach { if ($script:ctx) { Close-Ctx $script:ctx; $script:ctx = $null } }

    It 'shows sign-offs (missing roles pending), the latest freeze record and retention' {
        $script:ctx = New-CleanFinal -Name 'governance'
        Add-Rec -Ctx $script:ctx -Name 'signoff.jsonl' -Record ([ordered]@{ role = 'SourceOwner'; signer = 'alice'; report_run_id = 'r0'; comment = 'ok'; ts_utc = '2026-01-01T00:00:00Z' })
        Add-Rec -Ctx $script:ctx -Name 'freeze.jsonl' -Record ([ordered]@{ frozen = $false; recorded_by = 'bob'; sddl_hash = 'H1'; comment = 'first'; ts_utc = '2026-01-01T00:00:00Z' })
        Add-Rec -Ctx $script:ctx -Name 'freeze.jsonl' -Record ([ordered]@{ frozen = $true; recorded_by = 'bob'; sddl_hash = 'H2'; comment = 'frozen now'; ts_utc = '2026-01-02T00:00:00Z' })
        Add-Rec -Ctx $script:ctx -Name 'retention.jsonl' -Record ([ordered]@{ ticket = 'CHG-1'; retain_until = '2027-01-01T00:00:00Z'; recorded_by = 'bob'; comment = 'keep'; ts_utc = '2026-01-03T00:00:00Z' })
        $s = Invoke-Report -Ctx $script:ctx -Final
        $j = Read-Json (Get-ReportFile $s '*.json')
        $so = @{}; foreach ($r in $j.tables.signoff.rows) { $so[$r.role] = $r }
        $so['SourceOwner'].status | Should -Be 'signed'
        $so['SourceOwner'].signer | Should -Be 'alice'
        $so['TargetOwner'].status | Should -Be 'pending'
        $so['ControlOwner'].status | Should -Be 'pending'
        @($j.tables.freeze.rows).Count | Should -Be 1
        $j.tables.freeze.rows[0].frozen | Should -Be 'true'
        $j.tables.freeze.rows[0].sddl_hash | Should -Be 'H2'
        $j.tables.retention.rows[0].ticket | Should -Be 'CHG-1'
        $html = Get-Content -LiteralPath (Get-ReportFile $s '*.html') -Raw
        $html | Should -Match '<section id="signoff">'
        $html | Should -Match '<td class="bad">pending</td>'
    }

    It 'finalTargetSweep: orphans outside every batch fail AC-3 unless accepted' {
        $script:ctx = New-CleanFinal -Name 'sweep' -Override @{ report = @{ finalTargetSweep = $true } }
        $exists = & $script:mod { [bool](Get-Command Find-MigTargetOrphans -ErrorAction SilentlyContinue) }
        if ($exists) {
            Mock -ModuleName NotificationMigration Find-MigTargetOrphans { @{ scanned = 10; orphans = @('stray\a.html', 'stray\b.html') } }
        } else {
            & $script:mod { function script:Find-MigTargetOrphans { param($Ctx) @{ scanned = 10; orphans = @('stray\a.html', 'stray\b.html') } } }
        }
        try {
            Add-Exc -Ctx $script:ctx -BatchId 'ORPHANS' -RelPath 'stray\a.html' -Category 'extra_on_target' -Status 'accepted'
            $ac = Get-Ac (Invoke-Report -Ctx $script:ctx -Final)
            $ac['AC-3'].passed | Should -Be 'false'
            $ac['AC-3'].detail | Should -Match 'extra outside every batch 1 \(target sweep this run: 10 scanned, 2 orphan\(s\), 1 not accepted\)'
        } finally {
            if (-not $exists) { & $script:mod { Remove-Item -LiteralPath function:script:Find-MigTargetOrphans } }
        }
    }

    It 'pilot estimate uses completed real Copy throughput for batches not yet copied' {
        $script:ctx = New-Ctx -Name 'estimate'
        Add-Inventory -Ctx $script:ctx -Files 6 -Bytes 200
        Add-Plan -Ctx $script:ctx -BatchId 'B1'
        Add-Plan -Ctx $script:ctx -BatchId 'B2'
        Add-Reconciled -Ctx $script:ctx -BatchId 'B1'   # Copy: 3 files, 100 bytes in 2 s
        $s = Invoke-Report -Ctx $script:ctx -Final
        $j = Read-Json (Get-ReportFile $s '*.json')
        $m = @{}; foreach ($r in $j.tables.pilot_estimate.rows) { $m[$r.metric] = $r.value }
        $m['copy_runs_measured'] | Should -Be '1'
        $m['batches_not_copied'] | Should -Be '1'
        $m['remaining_files'] | Should -Be '3'
        $m['files_per_sec'] | Should -Be '1.5'
        $m['estimated_remaining_duration'] | Should -Be '0d 00h 00m 02s'
        $j.pilot_estimate | Should -Be '0d 00h 00m 02s'
        (Get-Content -LiteralPath (Get-ReportFile $s '*.html') -Raw) | Should -Match 'Estimated remaining copy time'
    }
}
