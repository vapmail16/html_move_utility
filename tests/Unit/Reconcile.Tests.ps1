BeforeDiscovery {
    Import-Module "$PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1" -Force -DisableNameChecking
}

# Fault injection (spec test plan): corrupt, delete, add extra, change timestamp -> Reconcile catches each;
# auto-retry repairs what it can and exhausted retries end in the exception register.
InModuleScope NotificationMigration {
    Describe 'Invoke-MigStageReconcile' {
        BeforeAll {
            # Test batch strategy: 'yyyy\mm\...' -> 'yyyy-mm', anything else -> UNBATCHED.
            Register-MigProvider -Kind Batch -Name 'testmonth' -ScriptBlock {
                param($RelPath, $Record, $Options)
                $m = [regex]::Match($RelPath, '^(\d{4})\\(\d{2})(\\|$)')
                if ($m.Success) { return ('{0}-{1}' -f $m.Groups[1].Value, $m.Groups[2].Value) }
                return 'UNBATCHED'
            }
            # Copy provider that always fails (fault injection).
            Register-MigProvider -Kind Copy -Name 'testfail' -ScriptBlock {
                param($Ctx, $BatchId, $Plan)
                $f = @(foreach ($r in @($Plan.RelPaths)) { @{ rel_path = $r; error = 'injected failure' } })
                return @{ exit_code = 8; succeeded = $false; copied = @(); failed = $f; log_path = $null }
            }
            function New-TestCtx {
                param([string] $Name = ([guid]::NewGuid().ToString('N').Substring(0, 8)), [hashtable] $Override = @{}, [switch] $DryRun)
                $root = Join-Path $TestDrive $Name
                $cfgPath = Join-Path $root 'migration.config.json'
                if (-not (Test-Path -LiteralPath $cfgPath)) {
                    $src = Join-Path $root 'src'; $tgt = Join-Path $root 'tgt'; $work = Join-Path $root 'work'
                    New-Item -ItemType Directory -Force -Path $src, $tgt, $work | Out-Null
                    $cfg = [ordered]@{
                        paths     = @{ sourceRoot = $src; targetRoot = $tgt; workDir = $work }
                        inventory = @{ aclReader = 'none'; threads = 2; chunkSize = 3 }
                        batching  = @{ strategy = 'testmonth' }
                        copy      = @{ engine = 'dotnet'; maxRetries = 2; chunkSize = 2 }
                        compare   = @{ fileFields = @('exists', 'size', 'hash', 'created', 'modified', 'attributes'); dirFields = @('exists', 'modified') }
                    }
                    ConvertTo-Json $cfg -Depth 6 | Set-Content -LiteralPath $cfgPath
                }
                return New-MigContext -ConfigPath $cfgPath -Override $Override -DryRun:$DryRun -Operator 'maker'
            }
            function New-SrcFile {
                param($Ctx, [string] $Rel, [string] $Content = $null)
                if ($null -eq $Content -or $Content -eq '') { $Content = "<html><body>$Rel</body></html>" }
                $p = Join-MigPath -Root $Ctx.Config.paths.sourceRoot -RelPath $Rel
                New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($p)) | Out-Null
                [IO.File]::WriteAllText($p, $Content)
                [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::SpecifyKind([DateTime]'2019-03-15T08:30:00', 'Utc'))
            }
            function Write-TestSourceManifest {
                param($Ctx, [string] $BatchId)
                $entries = @(Get-MigTreeEntries -Root $Ctx.Config.paths.sourceRoot)
                $recs = @(Get-MigScanRecords -Ctx $Ctx -Side source -Entries $entries)
                $bp = Get-MigProvider -Kind Batch -Name 'testmonth'
                $mine = @(foreach ($r in $recs) { if ((& $bp $r.rel_path $r $null) -eq $BatchId) { $r.batch_id = $BatchId; $r } })
                Write-MigManifest -Store $Ctx.Store -BatchId $BatchId -Side source -Records $mine
                return $mine
            }
            function Get-TreeFingerprint {
                param([string] $Root)
                @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
                    $h = ''
                    if (-not $_.PSIsContainer) { $h = Get-MigFileHash -Path $_.FullName }
                    '{0}|{1}|{2}' -f $_.FullName, $_.LastWriteTimeUtc.Ticks, $h
                }) -join "`n"
            }
            function New-Batch0319 {
                param($Ctx)
                New-SrcFile $Ctx '2019\03\01\a.html'
                New-SrcFile $Ctx '2019\03\01\b.html'
                New-SrcFile $Ctx '2019\03\02\c.html'
                New-SrcFile $Ctx '2019\03\02\zero.html' -Content ' '
                New-SrcFile $Ctx '2019\03\top.html'
                New-Item -ItemType Directory -Force -Path (Join-MigPath -Root $Ctx.Config.paths.sourceRoot -RelPath '2019\03\empty') | Out-Null
                New-SrcFile $Ctx '2019\04\other.html'
                New-SrcFile $Ctx 'readme.txt'
                return Write-TestSourceManifest $Ctx '2019-03'
            }
        }

        BeforeAll {
            function New-CopiedBatch {
                param($Ctx)
                [void](New-Batch0319 $Ctx)
                [void](Invoke-MigStageCopy -Ctx $Ctx -BatchId '2019-03' 3>$null)
                [void](Invoke-MigStageVerify -Ctx $Ctx -BatchId '2019-03')
            }
            function Get-TgtPath { param($Ctx, [string] $Rel) Join-MigPath -Root $Ctx.Config.paths.targetRoot -RelPath $Rel }
            function Get-SrcPath { param($Ctx, [string] $Rel) Join-MigPath -Root $Ctx.Config.paths.sourceRoot -RelPath $Rel }
            function Set-Corrupt {
                <# Same size, same timestamps, different bytes: only the hash can catch it. #>
                param($Ctx, [string] $Rel)
                $p = Get-TgtPath $Ctx $Rel
                $mt = [IO.File]::GetLastWriteTimeUtc($p)
                $bytes = [IO.File]::ReadAllBytes($p)
                $bytes[0] = [byte](($bytes[0] + 1) % 256)
                [IO.File]::WriteAllBytes($p, $bytes)
                [IO.File]::SetLastWriteTimeUtc($p, $mt)
            }
            function Get-Results {
                <# Issues of one run, read from that run's own results file (reconcile.results.<runId>.jsonl). #>
                param($Ctx, [string] $RunId)
                $p = Get-MigStorePath -Store $Ctx.Store -Name ('reconcile.results.{0}.jsonl' -f $RunId) -BatchId '2019-03'
                if (-not (Test-Path -LiteralPath $p)) { return @() }
                @(Read-MigStoreRecords -Store $Ctx.Store -Name ('reconcile.results.{0}.jsonl' -f $RunId) -BatchId '2019-03' | Where-Object { $_['run_id'] -eq $RunId })
            }
            function Get-AuditEvents { param($Ctx) @([IO.File]::ReadAllLines($Ctx.Audit.Path) | ForEach-Object { (ConvertFrom-Json $_).event }) }
            function New-ExhaustedBatch {
                <# a.html corrupted + c.html timestamp changed, every re-copy fails: two open exceptions. Returns the data name. #>
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                Set-Corrupt $ctx '2019\03\01\a.html'
                [IO.File]::SetLastWriteTimeUtc((Get-TgtPath $ctx '2019\03\02\c.html'), [DateTime]::SpecifyKind([DateTime]'2021-01-01T00:00:00', 'Utc'))
                $ctx = New-RunCtx $n
                $ctx.Config.copy.engine = 'testfail'
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                [void](Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03')
                Close-MigContext $ctx
                return $n
            }
            function Get-Exception1 {
                param($Ctx, [string] $Rel)
                @(Get-MigExceptions -Store $Ctx.Store -BatchId '2019-03' | Where-Object { $_['rel_path'] -eq $Rel })
            }
            function New-RunCtx {
                <# Fresh context (new run id) on the same data, e.g. after fault injection. #>
                param([string] $Name, [hashtable] $Override = @{})
                return New-TestCtx -Name $Name -Override $Override
            }
            function New-Name { 'r' + [guid]::NewGuid().ToString('N').Substring(0, 6) }
        }

        It 'passes a clean batch: totals match, every entry verified, state reconciled' {
            $ctx = New-TestCtx
            New-CopiedBatch $ctx
            $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
            $s.passed | Should -BeTrue
            $s.source_files | Should -Be 5
            $s.target_files | Should -Be 5
            $s.source_bytes | Should -Be $s.target_bytes
            $s.source_bytes | Should -BeGreaterThan 0
            $s.source_dirs | Should -Be 4
            $s.target_dirs | Should -Be 4
            foreach ($k in @('missing', 'extra', 'size_mismatch', 'hash_mismatch', 'metadata_mismatch', 'scan_errors', 'retried', 'exceptions_opened')) { $s[$k] | Should -Be 0 -Because $k }
            $st = Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03'
            foreach ($k in @('2019\03\01\a.html', '2019\03\top.html', '2019\03\empty')) { $st[$k].status | Should -Be 'verified' }
            $b = (Get-MigBatches -Store $ctx.Store)['2019-03']
            $b.state | Should -Be 'reconciled'
            $b.reconcile.passed | Should -BeTrue
            $b.reconcile.run_id | Should -Be $ctx.RunId
            foreach ($k in @('source_files', 'target_files', 'source_bytes', 'target_bytes', 'source_dirs', 'target_dirs', 'missing', 'extra', 'size_mismatch', 'hash_mismatch', 'metadata_mismatch', 'scan_errors', 'retried', 'exceptions_opened')) {
                $b.reconcile.Contains($k) | Should -BeTrue -Because $k
            }
            @(Get-Results $ctx $ctx.RunId).Count | Should -Be 0
            Close-MigContext $ctx
        }

        Context 'fault injection with reconcile.autoRetry = false (detection only)' {
            It 'catches a corrupted target file as hash_mismatch' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                Set-Corrupt $ctx '2019\03\01\a.html'
                $ctx = New-RunCtx $n @{ reconcile = @{ autoRetry = $false } }
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.passed | Should -BeFalse
                $s.hash_mismatch | Should -Be 1
                $s.size_mismatch | Should -Be 0
                $s.metadata_mismatch | Should -Be 0
                $s.retried | Should -Be 0
                $r = @(Get-Results $ctx $ctx.RunId)
                $r.Count | Should -Be 1
                $r[0]['category'] | Should -Be 'hash_mismatch'
                $r[0]['rel_path'] | Should -Be '2019\03\01\a.html'
                $r[0]['field'] | Should -Be 'hash'
                $r[0]['source_value'] | Should -Not -Be $r[0]['target_value']
                (Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03')['2019\03\01\a.html'].status | Should -Be 'mismatch'
                (Get-MigBatches -Store $ctx.Store)['2019-03'].state | Should -Be 'mismatch'
                Close-MigContext $ctx
            }

            It 'catches a deleted target file as missing' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                Remove-Item -LiteralPath (Get-TgtPath $ctx '2019\03\02\c.html')
                $ctx = New-RunCtx $n @{ reconcile = @{ autoRetry = $false } }
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.passed | Should -BeFalse
                $s.missing | Should -Be 1
                $s.target_files | Should -Be 4
                $r = @(Get-Results $ctx $ctx.RunId)
                @($r | Where-Object { $_['category'] -eq 'missing' })[0]['rel_path'] | Should -Be '2019\03\02\c.html'
                Close-MigContext $ctx
            }

            It 'catches a changed timestamp as metadata_mismatch' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                [IO.File]::SetLastWriteTimeUtc((Get-TgtPath $ctx '2019\03\top.html'), [DateTime]::SpecifyKind([DateTime]'2021-01-01T00:00:00', 'Utc'))
                $ctx = New-RunCtx $n @{ reconcile = @{ autoRetry = $false } }
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.metadata_mismatch | Should -Be 1
                $s.hash_mismatch | Should -Be 0
                $r = @(Get-Results $ctx $ctx.RunId)
                $r[0]['category'] | Should -Be 'metadata_mismatch'
                $r[0]['field'] | Should -Be 'modified'
                Close-MigContext $ctx
            }

            It 'honours compare.timestampToleranceSec' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                $p = Get-TgtPath $ctx '2019\03\top.html'
                [IO.File]::SetLastWriteTimeUtc($p, [IO.File]::GetLastWriteTimeUtc($p).AddSeconds(1))
                $ctx = New-RunCtx $n @{ reconcile = @{ autoRetry = $false }; compare = @{ timestampToleranceSec = 2 } }
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.metadata_mismatch | Should -Be 0
                $s.passed | Should -BeTrue
                Close-MigContext $ctx
            }

            It 'catches a truncated file as size_mismatch (and hash_mismatch)' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                $p = Get-TgtPath $ctx '2019\03\01\b.html'
                $mt = [IO.File]::GetLastWriteTimeUtc($p)
                [IO.File]::WriteAllText($p, '<html>')
                [IO.File]::SetLastWriteTimeUtc($p, $mt)
                $ctx = New-RunCtx $n @{ reconcile = @{ autoRetry = $false } }
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.size_mismatch | Should -Be 1
                $s.hash_mismatch | Should -Be 1
                $s.source_bytes | Should -Not -Be $s.target_bytes
                Close-MigContext $ctx
            }
        }

        Context 'extras' {
            It 'reports an extra target file, opens extra_on_target and never deletes it' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                $x = Get-TgtPath $ctx '2019\03\01\intruder.html'
                [IO.File]::WriteAllText($x, 'not from source')
                $ctx = New-RunCtx $n
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.passed | Should -BeFalse
                $s.extra | Should -Be 1
                # Adding a file bumps the parent directory's mtime: that dir mismatch is repaired by auto-retry.
                $s.metadata_mismatch | Should -Be 0
                $s.exceptions_opened | Should -Be 1
                Test-Path -LiteralPath $x | Should -BeTrue
                $ex = @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' -Status open)
                $ex.Count | Should -Be 1
                $ex[0]['category'] | Should -Be 'extra_on_target'
                $ex[0]['rel_path'] | Should -Be '2019\03\01\intruder.html'
                @(Get-Results $ctx $ctx.RunId | Where-Object { $_['category'] -eq 'extra' }).Count | Should -Be 1
                Close-MigContext $ctx

                # Re-running does not open a duplicate exception.
                $ctx = New-RunCtx $n
                $s2 = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s2.exceptions_opened | Should -Be 0
                @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03').Count | Should -Be 1
                Close-MigContext $ctx
            }
        }

        Context 'auto-retry (reconcile.autoRetry = true)' {
            It 'repairs corruption, deletion and a changed timestamp in one run' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                Set-Corrupt $ctx '2019\03\01\a.html'
                Remove-Item -LiteralPath (Get-TgtPath $ctx '2019\03\02\c.html')
                [IO.File]::SetLastWriteTimeUtc((Get-TgtPath $ctx '2019\03\top.html'), [DateTime]::SpecifyKind([DateTime]'2021-01-01T00:00:00', 'Utc'))
                $ctx = New-RunCtx $n
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03' 3>$null
                # 3 files + the parent directory of the deleted file (its mtime changed on the target).
                $s.initial_issue_paths | Should -Be 4
                $s.retried | Should -Be 4
                $s.passed | Should -BeTrue
                $s.hash_mismatch + $s.missing + $s.metadata_mismatch | Should -Be 0
                foreach ($rel in @('2019\03\01\a.html', '2019\03\02\c.html', '2019\03\top.html')) {
                    (Get-MigFileHash (Get-TgtPath $ctx $rel)) | Should -Be (Get-MigFileHash (Get-SrcPath $ctx $rel))
                    [IO.File]::GetLastWriteTimeUtc((Get-TgtPath $ctx $rel)) | Should -Be ([IO.File]::GetLastWriteTimeUtc((Get-SrcPath $ctx $rel)))
                }
                $st = Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03'
                $st['2019\03\01\a.html'].status | Should -Be 'verified'
                $st['2019\03\01\a.html'].attempts | Should -Be 2
                # The target manifest was refreshed by the retry rescan.
                $tm = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side target
                $sm = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source
                $tm['2019\03\01\a.html']['hash'] | Should -Be $sm['2019\03\01\a.html']['hash']
                $tm.ContainsKey('2019\03\02\c.html') | Should -BeTrue
                $events = @([IO.File]::ReadAllLines($ctx.Audit.Path) | ForEach-Object { (ConvertFrom-Json $_).event })
                $events | Should -Contain 'reconcile.retry'
                (Get-MigBatches -Store $ctx.Store)['2019-03'].state | Should -Be 'reconciled'
                Close-MigContext $ctx
            }

            It 'opens an exception (category = mismatch category) when retries are exhausted' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                Set-Corrupt $ctx '2019\03\01\a.html'
                [IO.File]::SetLastWriteTimeUtc((Get-TgtPath $ctx '2019\03\02\c.html'), [DateTime]::SpecifyKind([DateTime]'2021-01-01T00:00:00', 'Utc'))
                $ctx = New-RunCtx $n
                $ctx.Config.copy.engine = 'testfail'     # every re-copy fails
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.passed | Should -BeFalse
                $s.retried | Should -Be 2
                $s.retry_rounds | Should -Be 1           # maxRetries = 2 and the initial copy was attempt 1
                $s.hash_mismatch | Should -Be 1
                $s.metadata_mismatch | Should -Be 1
                $s.exceptions_opened | Should -Be 2
                $ex = @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' -Status open | Sort-Object { $_['rel_path'] })
                $ex.Count | Should -Be 2
                $ex[0]['rel_path'] | Should -Be '2019\03\01\a.html'
                $ex[0]['category'] | Should -Be 'hash_mismatch'
                $ex[1]['rel_path'] | Should -Be '2019\03\02\c.html'
                $ex[1]['category'] | Should -Be 'metadata_mismatch'
                $st = Get-MigCopyState -Store $ctx.Store -BatchId '2019-03'
                $st['2019\03\01\a.html'].status | Should -Be 'exception'
                $st['2019\03\01\a.html'].attempts | Should -Be 2
                (Get-MigBatches -Store $ctx.Store)['2019-03'].reconcile.passed | Should -BeFalse
                Close-MigContext $ctx

                # A later run neither retries again nor duplicates the exceptions; the batch stays failed.
                $ctx = New-RunCtx $n
                $s2 = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s2.retried | Should -Be 0
                $s2.exceptions_opened | Should -Be 0
                $s2.passed | Should -BeFalse
                Close-MigContext $ctx
            }

            It 'keeps the batch failed while an exception is open even if the files now match' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx
                [void](Add-MigException -Store $ctx.Store -BatchId '2019-03' -RelPath '2019\03\top.html' -Category 'hash_mismatch' -Detail 'earlier' -RunId 'old')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.issues | Should -Be 0
                $s.open_exceptions | Should -Be 1
                $s.passed | Should -BeFalse
                (Get-MigBatches -Store $ctx.Store)['2019-03'].state | Should -Be 'mismatch'
                Close-MigContext $ctx
            }
        }

        Context 'scan errors and dry run' {
            It 'registers a source scan error without retrying it' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx
                Write-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source -Records @(
                    [ordered]@{ rel_path = '2019\03\locked.html'; kind = 'file'; batch_id = '2019-03'; side = 'source'; scanned_utc = Get-MigUtcNow; error = 'Access denied' })
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.scan_errors | Should -Be 1
                $s.retried | Should -Be 0
                $s.passed | Should -BeFalse
                $ex = @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' -Status open)
                $ex[0]['category'] | Should -Be 'scan_error'
                Close-MigContext $ctx
            }

            It 'writes nothing in dry run' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                Set-Corrupt $ctx '2019\03\01\a.html'
                $ctx = New-RunCtx $n
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $before = [IO.File]::ReadAllBytes((Get-TgtPath $ctx '2019\03\01\a.html'))
                $ctx.DryRun = $true
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.dry_run | Should -BeTrue
                $s.hash_mismatch | Should -Be 1
                $s.retried | Should -Be 0
                [IO.File]::ReadAllBytes((Get-TgtPath $ctx '2019\03\01\a.html')) | Should -Be $before
                @(Get-Results $ctx $ctx.RunId).Count | Should -Be 0
                @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03').Count | Should -Be 0
                (Get-MigBatches -Store $ctx.Store)['2019-03'].Contains('reconcile') | Should -BeFalse
                Close-MigContext $ctx
            }
        }
        Context 'exception register rules (accepted, resolved, bulk)' {
            It 'opens exceptions in bulk with ONE audit summary event, and never one per file' {
                $n = New-ExhaustedBatch
                $ctx = New-RunCtx $n
                $open = @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' -Status open)
                $open.Count | Should -Be 2
                $lines = @(Get-Content -LiteralPath (Get-MigStorePath -Store $ctx.Store -Name 'exceptions.jsonl' -BatchId '2019-03'))
                $lines.Count | Should -Be 2
                Close-MigContext $ctx
                # The audit log of the reconcile run that opened them has exactly one summary event.
                $logs = @(Get-ChildItem -LiteralPath $ctx.Config._resolved.logDir -Filter '*.jsonl' -Recurse | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) } | ForEach-Object { ConvertFrom-Json $_ })
                @($logs | Where-Object { $_.event -eq 'reconcile.exceptions_opened' }).Count | Should -Be 1
                @($logs | Where-Object { $_.event -eq 'exception.opened' }).Count | Should -Be 0
                (@($logs | Where-Object { $_.event -eq 'reconcile.exceptions_opened' })[0]).data.count | Should -Be 2
            }

            It 'passes when every remaining issue is covered by an ACCEPTED exception, and never re-opens it' {
                $n = New-ExhaustedBatch
                $ctx = New-RunCtx $n
                foreach ($e in @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' -Status open)) {
                    Update-MigException -Store $ctx.Store -BatchId '2019-03' -Id $e['id'] -Status accepted -Resolution 'business accepts the difference' -By 'checker'
                }
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.issues | Should -Be 2
                $s.accepted_issues | Should -Be 2
                $s.open_exceptions | Should -Be 0
                $s.exceptions_opened | Should -Be 0
                $s.retried | Should -Be 0
                $s.passed | Should -BeTrue
                $b = (Get-MigBatches -Store $ctx.Store)['2019-03']
                $b.state | Should -Be 'reconciled'
                $b.reconcile.accepted_issues | Should -Be 2
                $b.reconcile.open_exceptions | Should -Be 0
                @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03').Count | Should -Be 2
                @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' -Status accepted).Count | Should -Be 2
                @(Get-Results $ctx $ctx.RunId | Where-Object { $_['accepted'] -eq $true }).Count | Should -Be 2
                Close-MigContext $ctx
            }

            It 'does not pass when an accepted exception covers a different category than the issue' {
                $n = New-ExhaustedBatch
                $ctx = New-RunCtx $n
                $a = @(Get-Exception1 $ctx '2019\03\01\a.html')[0]
                Update-MigException -Store $ctx.Store -BatchId '2019-03' -Id $a['id'] -Status accepted -By 'checker'
                $c = @(Get-Exception1 $ctx '2019\03\02\c.html')[0]
                Update-MigException -Store $ctx.Store -BatchId '2019-03' -Id $c['id'] -Status accepted -By 'checker'
                # c.html now also has a size problem: its primary category changes, the acceptance does not cover it.
                $p = Get-TgtPath $ctx '2019\03\02\c.html'
                [IO.File]::WriteAllText($p, 'x')
                $ctx.Config.copy.engine = 'testfail'
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.passed | Should -BeFalse
                $s.exceptions_opened | Should -Be 1
                @(Get-Exception1 $ctx '2019\03\02\c.html' | Where-Object { $_['status'] -eq 'open' })[0]['category'] | Should -Be 'size_mismatch'
                Close-MigContext $ctx
            }

            It 're-checks a RESOLVED item: verified when the target was fixed' {
                $n = New-ExhaustedBatch
                $ctx = New-RunCtx $n
                # Someone fixes a.html on the target and resolves its exception.
                $rel = '2019\03\01\a.html'
                Copy-Item -LiteralPath (Get-SrcPath $ctx $rel) -Destination (Get-TgtPath $ctx $rel) -Force
                [IO.File]::SetLastWriteTimeUtc((Get-TgtPath $ctx $rel), [IO.File]::GetLastWriteTimeUtc((Get-SrcPath $ctx $rel)))
                [IO.Directory]::SetLastWriteTimeUtc((Get-TgtPath $ctx '2019\03\01'), [IO.Directory]::GetLastWriteTimeUtc((Get-SrcPath $ctx '2019\03\01')))
                $a = @(Get-Exception1 $ctx $rel)[0]
                Update-MigException -Store $ctx.Store -BatchId '2019-03' -Id $a['id'] -Status resolved -Resolution 'copied by hand' -By 'owner'
                (Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03')[$rel].status | Should -Be 'exception'
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.rechecked_resolved | Should -Be 1
                (Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03')[$rel].status | Should -Be 'verified'
                @(Get-Exception1 $ctx $rel).Count | Should -Be 1
                @(Get-Exception1 $ctx $rel)[0]['status'] | Should -Be 'resolved'
                $s.passed | Should -BeFalse           # c.html is still open
                Close-MigContext $ctx
            }

            It 're-checks a RESOLVED item: opens a NEW exception with the same category when it still mismatches' {
                $n = New-ExhaustedBatch
                $ctx = New-RunCtx $n
                $rel = '2019\03\02\c.html'
                $c = @(Get-Exception1 $ctx $rel)[0]
                $c['category'] | Should -Be 'metadata_mismatch'
                Update-MigException -Store $ctx.Store -BatchId '2019-03' -Id $c['id'] -Status resolved -Resolution 'said fixed, was not' -By 'owner'
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s.exceptions_opened | Should -Be 1
                $s.exceptions_reopened | Should -Be 1
                $all = @(Get-Exception1 $ctx $rel)
                $all.Count | Should -Be 2
                @($all | Where-Object { $_['status'] -eq 'resolved' }).Count | Should -Be 1
                $new = @($all | Where-Object { $_['status'] -eq 'open' })
                $new.Count | Should -Be 1
                $new[0]['category'] | Should -Be 'metadata_mismatch'
                $new[0]['id'] | Should -Not -Be $c['id']
                $s.passed | Should -BeFalse
                Close-MigContext $ctx

                # The new exception is open now: a further run does not open a third one.
                $ctx = New-RunCtx $n
                $s2 = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $s2.exceptions_opened | Should -Be 0
                @(Get-Exception1 $ctx $rel).Count | Should -Be 2
                Close-MigContext $ctx
            }
        }

        Context 'staleness, results file and compaction' {
            It 'records verify_run_id (latest REAL completed Verify), results_file, and clears stale' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx
                Add-MigStageEvent -Store $ctx.Store -Stage 'Verify' -Scope '2019-03' -State completed -RunId 'vreal' -Operator 'maker' -DryRun $false
                Add-MigStageEvent -Store $ctx.Store -Stage 'Verify' -Scope '2019-03' -State completed -RunId 'vdry' -Operator 'maker' -DryRun $true
                Add-MigStageEvent -Store $ctx.Store -Stage 'Verify' -Scope '2019-03' -State started -RunId 'vrunning' -Operator 'maker' -DryRun $false
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03'
                $b = (Get-MigBatches -Store $ctx.Store)['2019-03']
                $b.reconcile.verify_run_id | Should -Be 'vreal'
                $b.reconcile.stale | Should -BeFalse
                $b.reconcile.results_file | Should -Be ('reconcile.results.{0}.jsonl' -f $ctx.RunId)
                $s.results_file | Should -Be $b.reconcile.results_file
                Test-Path -LiteralPath (Get-MigStorePath -Store $ctx.Store -Name $b.reconcile.results_file -BatchId '2019-03') | Should -BeTrue
                Close-MigContext $ctx
            }

            It 'is marked stale by Verify and Copy (other keys kept) and cleared by the next Reconcile' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx
                [void](Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03')
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $b = (Get-MigBatches -Store $ctx.Store)['2019-03']
                $b.reconcile.stale | Should -BeTrue
                $b.reconcile.passed | Should -BeTrue
                $b.reconcile.run_id | Should -Be $ctx.RunId
                Close-MigContext $ctx
                $ctx = New-RunCtx $n
                [void](Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03')
                $b = (Get-MigBatches -Store $ctx.Store)['2019-03']
                $b.reconcile.stale | Should -BeFalse
                # Copy with outstanding work marks it stale again.
                Remove-Item -LiteralPath (Get-TgtPath $ctx '2019\03\top.html')
                Add-MigFileStatus -Store $ctx.Store -BatchId '2019-03' -Events @([ordered]@{ rel_path = '2019\03\top.html'; status = 'mismatch' }) -RunId 'x'
                [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null)
                $b = (Get-MigBatches -Store $ctx.Store)['2019-03']
                $b.reconcile.stale | Should -BeTrue
                $b.reconcile.passed | Should -BeTrue
                Close-MigContext $ctx
            }

            It 'compacts the target manifest (archived with a checksum) and keeps status attempts intact' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                Set-Corrupt $ctx '2019\03\01\a.html'
                $ctx = New-RunCtx $n
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $tmPath = Get-MigStorePath -Store $ctx.Store -Name 'target.manifest.jsonl' -BatchId '2019-03'
                $linesBefore = @(Get-Content -LiteralPath $tmPath).Count
                $before = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side target
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03' 3>$null
                $s.passed | Should -BeTrue
                $s.compaction.target_manifest.before | Should -BeGreaterOrEqual $linesBefore
                $s.compaction.target_manifest.after | Should -BeLessThan $linesBefore
                @(Get-Content -LiteralPath $tmPath).Count | Should -Be $s.compaction.target_manifest.after
                $after = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side target
                $after.Count | Should -Be $before.Count
                $arch = @(Get-ChildItem -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($tmPath)) 'archive') -Filter 'target.manifest.*')
                @($arch | Where-Object { $_.Name -like '*.sha256' }).Count | Should -Be 1
                $st = Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03'
                $st['2019\03\01\a.html'].attempts | Should -Be 2
                $st['2019\03\01\a.html'].status | Should -Be 'verified'
                $st['2019\03\02\c.html'].attempts | Should -Be 1
                if (-not (Test-MigStatusSnapshotSupported)) { $s.compaction.status_events | Should -BeLike 'skipped*' }
                Close-MigContext $ctx
            }

            It 'does not compact when reconcile.compactStore is false, nor in dry run' {
                $n = New-Name
                $ctx = New-TestCtx -Name $n; New-CopiedBatch $ctx; Close-MigContext $ctx
                Set-Corrupt $ctx '2019\03\01\a.html'
                $ctx = New-RunCtx $n @{ reconcile = @{ compactStore = $false } }
                [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
                $s = Invoke-MigStageReconcile -Ctx $ctx -BatchId '2019-03' 3>$null
                $s.Contains('compaction') | Should -BeFalse
                Test-Path -LiteralPath (Join-Path (Split-Path (Get-MigStorePath -Store $ctx.Store -Name 'x' -BatchId '2019-03')) 'archive') | Should -BeFalse
                Close-MigContext $ctx
            }
        }
    }
}
