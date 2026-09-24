BeforeDiscovery {
    Import-Module "$PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1" -Force -DisableNameChecking
}

InModuleScope NotificationMigration {
    Describe 'Invoke-MigStageCopy (dotnet engine)' {
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

        It 'copies every file of the batch with timestamps, records status and batch info, and never touches the source' {
            $ctx = New-TestCtx
            [void](New-Batch0319 $ctx)
            $before = Get-TreeFingerprint $ctx.Config.paths.sourceRoot
            $s = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null
            $s.files_planned | Should -Be 5
            $s.files_copied | Should -Be 5
            $s.files_failed | Should -Be 0
            $s.nothing_to_do | Should -BeFalse
            $s.files | Should -Be 5
            $sum = [int64]0
            foreach ($r in (Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source).Values) { if ($r['kind'] -eq 'file') { $sum += [int64]$r['size_bytes'] } }
            $s.bytes | Should -Be $sum
            $s.bytes_copied | Should -Be $sum
            $s.files_copied | Should -Be 5
            (Get-MigBatches -Store $ctx.Store)['2019-03'].copy.bytes_copied | Should -Be $sum
            $s.bytes | Should -BeGreaterThan 0
            (Get-TreeFingerprint $ctx.Config.paths.sourceRoot) | Should -Be $before

            $tgt = $ctx.Config.paths.targetRoot
            foreach ($rel in @('2019\03\01\a.html', '2019\03\01\b.html', '2019\03\02\c.html', '2019\03\02\zero.html', '2019\03\top.html')) {
                $sp = Join-MigPath -Root $ctx.Config.paths.sourceRoot -RelPath $rel
                $tp = Join-MigPath -Root $tgt -RelPath $rel
                Test-Path -LiteralPath $tp | Should -BeTrue -Because $rel
                (Get-MigFileHash $tp) | Should -Be (Get-MigFileHash $sp)
                [IO.File]::GetLastWriteTimeUtc($tp) | Should -Be ([IO.File]::GetLastWriteTimeUtc($sp))
            }
            Test-Path -LiteralPath (Join-MigPath -Root $tgt -RelPath '2019\03\empty') -PathType Container | Should -BeTrue
            Test-Path -LiteralPath (Join-MigPath -Root $tgt -RelPath '2019\04\other.html') | Should -BeFalse
            Test-Path -LiteralPath (Join-MigPath -Root $tgt -RelPath 'readme.txt') | Should -BeFalse
            # Directory timestamps are restored after the files were written.
            $sd = Join-MigPath -Root $ctx.Config.paths.sourceRoot -RelPath '2019\03\01'
            $td = Join-MigPath -Root $tgt -RelPath '2019\03\01'
            [IO.Directory]::GetLastWriteTimeUtc($td) | Should -Be ([IO.Directory]::GetLastWriteTimeUtc($sd))

            $st = Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03'
            $st['2019\03\01\a.html'].status | Should -Be 'copied'
            $st['2019\03\01\a.html'].attempts | Should -Be 1
            $b = (Get-MigBatches -Store $ctx.Store)['2019-03']
            $b.state | Should -Be 'copied'
            $b.copy.files_copied | Should -Be 5
            $b.copy.files_failed | Should -Be 0
            $b.copy.files_attempted | Should -Be 5
            $events = @([IO.File]::ReadAllLines($ctx.Audit.Path) | ForEach-Object { (ConvertFrom-Json $_).event })
            $events | Should -Contain 'copy.started'
            $events | Should -Contain 'copy.finished'
            Close-MigContext $ctx
        }

        It 'warns once per run that dotnet is not the production engine' {
            $ctx = New-TestCtx
            [void](New-Batch0319 $ctx)
            $w = @(Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $w.Count | Should -Be 1
            $w[0].Message | Should -Match 'robocopy'
            Close-MigContext $ctx
        }

        It 'is idempotent: verified and exception files are not re-planned' {
            $ctx = New-TestCtx
            $recs = New-Batch0319 $ctx
            $events = @(foreach ($r in $recs) { if ($r.kind -ne 'error') { [ordered]@{ rel_path = $r.rel_path; status = 'verified' } } })
            $events[0]['status'] = 'exception'
            Add-MigFileStatus -Store $ctx.Store -BatchId '2019-03' -Events $events -RunId 'earlier'
            $s = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null
            $s.nothing_to_do | Should -BeTrue
            $s.files_attempted | Should -Be 0
            $s.message | Should -Match 'Nothing to copy'
            @(Get-ChildItem -LiteralPath $ctx.Config.paths.targetRoot -Recurse -File).Count | Should -Be 0
            Close-MigContext $ctx
        }

        It 'only re-copies what is still outstanding after a partial run (resume)' {
            $ctx = New-TestCtx
            [void](New-Batch0319 $ctx)
            Add-MigFileStatus -Store $ctx.Store -BatchId '2019-03' -Events @(
                [ordered]@{ rel_path = '2019\03\01\a.html'; status = 'verified' },
                [ordered]@{ rel_path = '2019\03\01\b.html'; status = 'verified' }) -RunId 'earlier'
            $s = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null
            $s.files_planned | Should -Be 3
            $s.skipped_verified | Should -Be 2
            Test-Path -LiteralPath (Join-MigPath -Root $ctx.Config.paths.targetRoot -RelPath '2019\03\01\a.html') | Should -BeFalse
            Test-Path -LiteralPath (Join-MigPath -Root $ctx.Config.paths.targetRoot -RelPath '2019\03\02\c.html') | Should -BeTrue
            Close-MigContext $ctx
        }

        It 'dry run plans only: nothing written to target, no status, no batch info' {
            $ctx = New-TestCtx -DryRun
            [void](New-Batch0319 $ctx)
            $s = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null
            $s.dry_run | Should -BeTrue
            $s.files_planned | Should -Be 5
            @(Get-ChildItem -LiteralPath $ctx.Config.paths.targetRoot -Recurse).Count | Should -Be 0
            (Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03').Count | Should -Be 0
            (Get-MigBatches -Store $ctx.Store).ContainsKey('2019-03') | Should -BeFalse
            Close-MigContext $ctx
        }

        It 'records failures as pending and opens copy_failed exceptions once maxRetries is reached' {
            $name = 'fail' + [guid]::NewGuid().ToString('N').Substring(0, 6)
            $ctx = New-TestCtx -Name $name
            [void](New-Batch0319 $ctx)
            $ctx.Config.copy.engine = 'testfail'
            $s1 = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03'
            $s1.files_failed | Should -Be 5
            $s1.exceptions_opened | Should -Be 0
            $st = Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03'
            $st['2019\03\top.html'].status | Should -Be 'pending'
            $st['2019\03\top.html'].last_error | Should -Match 'injected failure'
            (Get-MigBatches -Store $ctx.Store)['2019-03'].state | Should -Be 'copying'
            Close-MigContext $ctx

            $ctx = New-TestCtx -Name $name
            $ctx.Config.copy.engine = 'testfail'
            $s2 = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03'
            $s2.exceptions_opened | Should -Be 5
            $st = Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03'
            $st['2019\03\top.html'].status | Should -Be 'exception'
            $ex = @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' -Status open)
            $ex.Count | Should -Be 5
            $ex[0]['category'] | Should -Be 'copy_failed'
            $ex[0]['detail'] | Should -Match '2 attempt'
            # Bulk: one append for the five exceptions and ONE audit summary event (never one per file).
            @(Get-Content -LiteralPath (Get-MigStorePath -Store $ctx.Store -Name 'exceptions.jsonl' -BatchId '2019-03')).Count | Should -Be 5
            $audit = @([IO.File]::ReadAllLines($ctx.Audit.Path) | ForEach-Object { ConvertFrom-Json $_ })
            @($audit | Where-Object { $_.event -eq 'copy.exceptions_opened' }).Count | Should -Be 1
            @($audit | Where-Object { $_.event -eq 'copy.exceptions_opened' })[0].data.count | Should -Be 5
            @($audit | Where-Object { $_.event -eq 'exception.opened' }).Count | Should -Be 0
            @($audit | Where-Object { $_.event -eq 'copy.failures' }).Count | Should -Be 1
            Close-MigContext $ctx

            # Third run: everything is in the exception register, nothing left to do, no duplicate exceptions.
            $ctx = New-TestCtx -Name $name
            $ctx.Config.copy.engine = 'testfail'
            $s3 = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03'
            $s3.files_planned | Should -Be 0
            @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03').Count | Should -Be 5
            Close-MigContext $ctx
        }

        It 'throws when the batch has no source manifest' {
            $ctx = New-TestCtx
            { Invoke-MigStageCopy -Ctx $ctx -BatchId '2001-01' } | Should -Throw '*no source manifest*'
            Close-MigContext $ctx
        }

        It 'overwrites a read-only target copy of a planned file' {
            $ctx = New-TestCtx
            [void](New-Batch0319 $ctx)
            $tp = Join-MigPath -Root $ctx.Config.paths.targetRoot -RelPath '2019\03\top.html'
            New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($tp)) | Out-Null
            [IO.File]::WriteAllText($tp, 'stale')
            [IO.File]::SetAttributes($tp, [IO.FileAttributes]::ReadOnly)
            $s = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null
            $s.files_failed | Should -Be 0
            [IO.File]::ReadAllText($tp) | Should -Be '<html><body>2019\03\top.html</body></html>'
            Close-MigContext $ctx
        }
        It 'never re-plans an ACCEPTED copy_failed item; re-plans a RESOLVED one and re-opens it if it fails again' {
            $name = 'acc' + [guid]::NewGuid().ToString('N').Substring(0, 6)
            $ctx = New-TestCtx -Name $name
            [void](New-Batch0319 $ctx)
            $ctx.Config.copy.engine = 'testfail'
            [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03')
            [void](Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03')
            $ex = @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' -Status open | Sort-Object { $_['rel_path'] })
            $ex.Count | Should -Be 5
            $acc = $ex[0]; $res = $ex[1]
            Update-MigException -Store $ctx.Store -BatchId '2019-03' -Id $acc['id'] -Status accepted -By 'checker'
            Update-MigException -Store $ctx.Store -BatchId '2019-03' -Id $res['id'] -Status resolved -Resolution 'lock released' -By 'owner'
            Close-MigContext $ctx

            $ctx = New-TestCtx -Name $name
            $ctx.Config.copy.engine = 'testfail'
            $s = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03'
            $s.files_planned | Should -Be 1
            $s.rechecked_resolved | Should -Be 1
            $s.skipped_exception | Should -Be 4
            $s.files_failed | Should -Be 1
            $s.exceptions_opened | Should -Be 1
            $mine = @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' | Where-Object { $_['rel_path'] -eq $res['rel_path'] })
            $mine.Count | Should -Be 2
            @($mine | Where-Object { $_['status'] -eq 'open' -and $_['category'] -eq 'copy_failed' }).Count | Should -Be 1
            @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' | Where-Object { $_['rel_path'] -eq $acc['rel_path'] }).Count | Should -Be 1
            Close-MigContext $ctx

            # A resolved item that now copies fine is simply copied.
            $ctx = New-TestCtx -Name $name
            $open = @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03' -Status open | Where-Object { $_['rel_path'] -eq $res['rel_path'] })[0]
            Update-MigException -Store $ctx.Store -BatchId '2019-03' -Id $open['id'] -Status resolved -By 'owner'
            $s = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03' 3>$null
            $s.files_copied | Should -Be 1
            $s.exceptions_opened | Should -Be 0
            (Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03')[$res['rel_path']].status | Should -Be 'copied'
            Close-MigContext $ctx
        }

        Context 'Get-MigCopyChunks (folder chunking)' {
            It 'packs whole folders and never splits a folder that is only somewhat larger than chunkSize' {
                $rels = @('a\1', 'a\2', 'a\3', 'b\1', 'c\1', 'c\2', 'd\1', 'd\2', 'd\3', 'd\4', 'd\5')
                $r = Get-MigCopyChunks -RelPaths $rels -ChunkSize 2 -SplitFactor 3
                $chunks = @($r.Chunks)
                # a (3, alone: over chunkSize but not split) | b | c | d (5 <= 2*3, whole)
                $chunks.Count | Should -Be 4
                ($chunks[0] -join ',') | Should -Be 'a\1,a\2,a\3'
                ($chunks[3] -join ',') | Should -Be 'd\1,d\2,d\3,d\4,d\5'
                $r.SplitDirs.Count | Should -Be 0
                foreach ($c in $chunks) { @($c | ForEach-Object { Get-MigParentRelPath $_ } | Select-Object -Unique).Count | Should -BeLessOrEqual 2 }
            }
            It 'combines small folders up to chunkSize' {
                $r = Get-MigCopyChunks -RelPaths @('a\1', 'b\1', 'c\1', 'd\1', 'e\1') -ChunkSize 2 -SplitFactor 10
                @($r.Chunks).Count | Should -Be 3
                (@($r.Chunks)[0] -join ',') | Should -Be 'a\1,b\1'
            }
            It 'splits a folder only when it exceeds chunkSize * splitFolderFactor, and reports it' {
                $rels = @(1..7 | ForEach-Object { 'big\{0}' -f $_ }) + @('small\1')
                $r = Get-MigCopyChunks -RelPaths $rels -ChunkSize 2 -SplitFactor 3
                @($r.Chunks).Count | Should -Be 5          # big: 2+2+2+1, small: 1
                $r.SplitDirs.Contains('big') | Should -BeTrue
                $r.SplitDirs.Contains('small') | Should -BeFalse
            }
        }
    }
}
