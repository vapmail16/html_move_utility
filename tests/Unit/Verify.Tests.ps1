BeforeDiscovery {
    Import-Module "$PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1" -Force -DisableNameChecking
}

InModuleScope NotificationMigration {
    Describe 'Invoke-MigStageVerify' {
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

        It 'writes a target manifest for every source entry with hashes and batch id' {
            $ctx = New-TestCtx
            $recs = New-Batch0319 $ctx
            [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null)
            $s = Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03'
            $s.files | Should -Be 5
            $s.dirs | Should -Be 4          # 2019\03, 01, 02, empty
            $s.extras | Should -Be 0
            $s.missing | Should -Be 0
            $s.errors | Should -Be 0
            $tm = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side target
            $sm = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source
            $tm.Count | Should -Be $sm.Count
            foreach ($k in $sm.Keys) {
                $tm.ContainsKey($k) | Should -BeTrue -Because $k
                $tm[$k]['side'] | Should -Be 'target'
                $tm[$k]['batch_id'] | Should -Be '2019-03'
                if ($sm[$k]['kind'] -eq 'file') { $tm[$k]['hash'] | Should -Be $sm[$k]['hash'] }
            }
            $b = (Get-MigBatches -Store $ctx.Store)['2019-03']
            $b.verify.files | Should -Be 5
            $sum = [int64]0
            foreach ($r in $recs) { if ($r['kind'] -eq 'file') { $sum += [int64]$r['size_bytes'] } }
            $b.verify.bytes | Should -Be $sum
            $b.state | Should -Be 'verified'
            Close-MigContext $ctx
        }

        It 'detects extras that belong to this batch (including inside extra directories) but not other batches' {
            $ctx = New-TestCtx
            [void](New-Batch0319 $ctx)
            [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null)
            $tgt = $ctx.Config.paths.targetRoot
            foreach ($rel in @('2019\03\01\extra.html', '2019\03\newdir\deep\x.html', '2019\04\other-batch.html', '2019\unbatched.txt')) {
                $p = Join-MigPath -Root $tgt -RelPath $rel
                New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($p)) | Out-Null
                [IO.File]::WriteAllText($p, 'extra')
            }
            $s = Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03' 3>$null
            $s.extras | Should -Be 4   # extra.html, newdir, newdir\deep, newdir\deep\x.html
            $tm = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side target
            $tm.ContainsKey('2019\03\01\extra.html') | Should -BeTrue
            $tm.ContainsKey('2019\03\newdir') | Should -BeTrue
            $tm.ContainsKey('2019\03\newdir\deep\x.html') | Should -BeTrue
            $tm.ContainsKey('2019\04\other-batch.html') | Should -BeFalse
            $tm.ContainsKey('2019\04') | Should -BeFalse
            $tm.ContainsKey('2019\unbatched.txt') | Should -BeFalse
            Close-MigContext $ctx
        }

        It 'tombstones entries that disappeared since the previous scan' {
            $name = 'v' + [guid]::NewGuid().ToString('N').Substring(0, 6)
            $ctx = New-TestCtx -Name $name
            [void](New-Batch0319 $ctx)
            [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null)
            $tgt = $ctx.Config.paths.targetRoot
            $extra = Join-MigPath -Root $tgt -RelPath '2019\03\stale-extra.html'
            [IO.File]::WriteAllText($extra, 'x')
            [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
            Close-MigContext $ctx

            Remove-Item -LiteralPath (Join-MigPath -Root $tgt -RelPath '2019\03\02\c.html')
            Remove-Item -LiteralPath $extra
            $ctx = New-TestCtx -Name $name
            $s = Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03'
            $s.missing | Should -Be 1
            $s.extras | Should -Be 0
            $tm = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side target
            $tm.ContainsKey('2019\03\02\c.html') | Should -BeFalse
            $tm.ContainsKey('2019\03\stale-extra.html') | Should -BeFalse
            $tm.ContainsKey('2019\03\02\zero.html') | Should -BeTrue
            Close-MigContext $ctx
        }

        It 'reports a whole missing directory as missing entries' {
            $ctx = New-TestCtx
            [void](New-Batch0319 $ctx)
            $s = Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03'
            $s.files | Should -Be 0
            $s.missing | Should -Be 9
            Close-MigContext $ctx
        }

        It 'does not write anything in dry run' {
            $ctx = New-TestCtx
            [void](New-Batch0319 $ctx)
            [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null)
            $ctx.DryRun = $true
            $s = Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03'
            $s.files | Should -Be 5
            (Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side target).Count | Should -Be 0
            Close-MigContext $ctx
        }

        It 'never writes to the target (read-only scan)' {
            $ctx = New-TestCtx
            [void](New-Batch0319 $ctx)
            [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null)
            $before = Get-TreeFingerprint $ctx.Config.paths.targetRoot
            [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
            (Get-TreeFingerprint $ctx.Config.paths.targetRoot) | Should -Be $before
            Close-MigContext $ctx
        }
        It 'marks an existing reconcile as stale (other keys kept) and does not invent one' {
            $ctx = New-TestCtx
            [void](New-Batch0319 $ctx)
            [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null)
            [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
            (Get-MigBatches -Store $ctx.Store)['2019-03'].Contains('reconcile') | Should -BeFalse
            Set-MigBatchInfo -Store $ctx.Store -BatchId '2019-03' -Data @{ reconcile = @{ passed = $true; run_id = 'r1'; results_file = 'reconcile.results.r1.jsonl'; stale = $false } }
            [void](Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03')
            $r = (Get-MigBatches -Store $ctx.Store)['2019-03'].reconcile
            $r.stale | Should -BeTrue
            $r.passed | Should -BeTrue
            $r.run_id | Should -Be 'r1'
            $r.results_file | Should -Be 'reconcile.results.r1.jsonl'
            Close-MigContext $ctx
        }

        It 'stats candidate extras so date-based strategies (yearMonth) find extras of the batch' {
            $ctx = New-TestCtx -Override @{ batching = @{ strategy = 'yearMonth'; options = @{ dateField = 'modified_utc' } } }
            $srcRoot = $ctx.Config.paths.sourceRoot; $tgt = $ctx.Config.paths.targetRoot
            New-SrcFile $ctx 'notes\a.html'                     # mtime 2019-03-15 -> batch 2019-03
            New-SrcFile $ctx 'notes\b.html'
            $entries = @(foreach ($r in @('notes\a.html', 'notes\b.html')) { @{ rel_path = $r; kind = 'file'; full = (Join-MigPath -Root $srcRoot -RelPath $r) } })
            $recs = @(Get-MigScanRecords -Ctx $ctx -Side source -Entries $entries)
            foreach ($r in $recs) { $r['batch_id'] = '2019-03' }
            Write-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source -Records $recs
            [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null)
            foreach ($x in @(@('notes\same-month.html', '2019-03-20T10:00:00'), @('notes\other-month.html', '2020-01-05T10:00:00'))) {
                $p = Join-MigPath -Root $tgt -RelPath $x[0]
                [IO.File]::WriteAllText($p, 'extra')
                [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::SpecifyKind([DateTime]$x[1], 'Utc'))
            }
            $s = Invoke-MigStageVerify -Ctx $ctx -BatchId '2019-03' 3>$null
            $s.files | Should -Be 3
            $s.extras | Should -Be 1
            $tm = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side target
            $tm.ContainsKey('notes\same-month.html') | Should -BeTrue
            $tm.ContainsKey('notes\other-month.html') | Should -BeFalse
            Close-MigContext $ctx
        }

        Context 'Find-MigTargetOrphans' {
            BeforeAll {
                function New-OrphanSetup {
                    param([hashtable] $Override = @{})
                    $n = 'o' + [guid]::NewGuid().ToString('N').Substring(0, 6)
                    $ctx = New-TestCtx -Name $n
                    [void](New-Batch0319 $ctx)
                    [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null)
                    Close-MigContext $ctx
                    $tgt = $ctx.Config.paths.targetRoot
                    foreach ($rel in @('2019\03\01\extra.html', '2019\04\other.html', 'loose.txt')) {
                        $p = Join-MigPath -Root $tgt -RelPath $rel
                        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($p)) | Out-Null
                        [IO.File]::WriteAllText($p, 'orphan')
                    }
                    return (New-TestCtx -Name $n -Override $Override)
                }
            }

            It 'reports only entries of unknown batches, opens ORPHANS exceptions in bulk, deletes nothing' {
                $ctx = New-OrphanSetup
                $before = Get-TreeFingerprint $ctx.Config.paths.targetRoot
                $r = Find-MigTargetOrphans -Ctx $ctx
                $r.scanned | Should -BeGreaterThan 8
                $r.orphans | Should -Contain '2019\04\other.html'       # batch 2019-04 is not in the store
                $r.orphans | Should -Contain '2019\04'
                $r.orphans | Should -Contain 'loose.txt'                # UNBATCHED is not in the store
                # Known batch, not in its source manifest: that batch's Verify/Reconcile extra, not an orphan.
                $r.orphans | Should -Not -Contain '2019\03\01\extra.html'
                foreach ($ok in @('2019\03\01\a.html', '2019\03\02\c.html', '2019\03\top.html', '2019\03\empty', '2019\03')) { $r.orphans | Should -Not -Contain $ok }
                (Get-TreeFingerprint $ctx.Config.paths.targetRoot) | Should -Be $before
                $ex = @(Get-MigExceptions -Store $ctx.Store -BatchId 'ORPHANS' -Status open)
                $ex.Count | Should -Be $r.orphans.Count
                @($ex | Where-Object { $_['category'] -ne 'extra_on_target' }).Count | Should -Be 0
                $r.exceptions_opened | Should -Be $r.orphans.Count
                @(Get-Content -LiteralPath (Get-MigStorePath -Store $ctx.Store -Name 'exceptions.jsonl' -BatchId 'ORPHANS')).Count | Should -Be $r.orphans.Count
                @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03').Count | Should -Be 0
                $events = @([IO.File]::ReadAllLines($ctx.Audit.Path) | ForEach-Object { (ConvertFrom-Json $_).event })
                @($events | Where-Object { $_ -eq 'verify.orphans' }).Count | Should -Be 1
                @($events | Where-Object { $_ -eq 'verify.orphans_exceptions_opened' }).Count | Should -Be 1
                Close-MigContext $ctx

                # A second sweep finds the same orphans but opens nothing new; ORPHANS is never treated as a batch.
                $ctx = New-TestCtx -Name (Split-Path (Split-Path $ctx.Config.paths.targetRoot) -Leaf)
                $r2 = Find-MigTargetOrphans -Ctx $ctx
                @($r2.orphans).Count | Should -Be @($r.orphans).Count
                $r2.exceptions_opened | Should -Be 0
                Close-MigContext $ctx
            }

            It 'does not descend into a directory of a known batch with a path-based strategy (regex)' {
                $ctx = New-OrphanSetup -Override @{ batching = @{ strategy = 'regex' } }
                $ctx.DryRun = $true
                $r = Find-MigTargetOrphans -Ctx $ctx
                # Scanned: '2019', 'loose.txt', '2019\03' (known: pruned), '2019\04', '2019\04\other.html'.
                $r.scanned | Should -Be 5
                $r.pruned_dirs | Should -Be 1
                (@($r.orphans | Sort-Object) -join '|') | Should -Be '2019|2019\04|2019\04\other.html|loose.txt'
                Close-MigContext $ctx
            }

            It 'opens no exception in dry run' {
                $ctx = New-OrphanSetup
                $ctx.DryRun = $true
                $r = Find-MigTargetOrphans -Ctx $ctx
                @($r.orphans).Count | Should -BeGreaterThan 0
                $r.exceptions_opened | Should -Be 0
                @(Get-MigExceptions -Store $ctx.Store -BatchId 'ORPHANS').Count | Should -Be 0
                Close-MigContext $ctx
            }

            It 'uses the batch strategy with stat metadata (date strategy)' {
                $ctx = New-TestCtx -Override @{ batching = @{ strategy = 'yearMonth'; options = @{ dateField = 'modified_utc' } } }
                $srcRoot = $ctx.Config.paths.sourceRoot; $tgt = $ctx.Config.paths.targetRoot
                New-SrcFile $ctx 'notes\a.html'
                $recs = @(Get-MigScanRecords -Ctx $ctx -Side source -Entries @(@{ rel_path = 'notes\a.html'; kind = 'file'; full = (Join-MigPath -Root $srcRoot -RelPath 'notes\a.html') }))
                foreach ($r in $recs) { $r['batch_id'] = '2019-03' }
                Write-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source -Records $recs
                [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null)
                foreach ($x in @(@('notes\same-month.html', '2019-03-28T00:00:00'), @('notes\next-year.html', '2020-01-05T00:00:00'))) {
                    $p = Join-MigPath -Root $tgt -RelPath $x[0]
                    [IO.File]::WriteAllText($p, 'x')
                    [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::SpecifyKind([DateTime]$x[1], 'Utc'))
                }
                $ctx.DryRun = $true
                $r = Find-MigTargetOrphans -Ctx $ctx
                $r.orphans | Should -Contain 'notes\next-year.html'      # stat'ed: batch 2020-01 is unknown
                $r.orphans | Should -Not -Contain 'notes\same-month.html' # batch 2019-03 is known (an extra there)
                $r.orphans | Should -Not -Contain 'notes\a.html'
                Close-MigContext $ctx
            }
        }
    }
}
