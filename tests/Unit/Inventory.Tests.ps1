#Requires -Modules Pester
# Unit tests: Inventory stage (FR-01 manifest, FR-07 resume, C-01 manifest checksums, scan errors).

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking

    function New-TestInventoryEnv {
        param([string] $Name, [hashtable] $Inventory = @{})
        $root = Join-Path $TestDrive $Name
        $src = Join-Path $root 'src'
        foreach ($d in @('2019/03', '2019/04')) { New-Item -ItemType Directory -Path (Join-Path $src $d) -Force | Out-Null }
        [IO.File]::WriteAllText((Join-Path $src '2019/03/a.html'), '<html>a</html>')
        [IO.File]::WriteAllText((Join-Path $src '2019/03/b.html'), '<html>bbbb</html>')
        [IO.File]::WriteAllText((Join-Path $src '2019/04/c.html'), '<html>c</html>')
        [IO.File]::WriteAllText((Join-Path $src '2019/04/zero.html'), '')
        [IO.File]::WriteAllText((Join-Path $src '2019/04/skip.tmp'), 'temp')
        $inv = @{ aclReader = 'none'; threads = 2; chunkSize = 2; excludePatterns = @('\.tmp$') }
        foreach ($k in $Inventory.Keys) { $inv[$k] = $Inventory[$k] }
        $cfg = @{
            paths     = @{ sourceRoot = $src; targetRoot = (Join-Path $root 'tgt'); workDir = (Join-Path $root 'work') }
            inventory = $inv
            compare   = @{ fileFields = @('exists', 'size', 'hash', 'created', 'modified', 'attributes') }
            copy      = @{ engine = 'dotnet' }
        }
        $cfgPath = Join-Path $root 'migration.config.json'
        [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 10))
        return @{ Root = $root; Src = $src; Config = $cfgPath }
    }
}

Describe 'Invoke-MigStageInventory' {
    Context 'first run' {
        BeforeAll {
            $script:env1 = New-TestInventoryEnv -Name 'inv1'
            $script:result = InModuleScope NotificationMigration -Parameters @{ cfg = $script:env1.Config } {
                param($cfg)
                $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
                try {
                    $s = Invoke-MigStageInventory -Ctx $ctx
                    $out = @{ Summary = $s; StoreRoot = $ctx.Store.Root; AuditPath = $ctx.Audit.Path
                              M03 = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source
                              M04 = Read-MigManifest -Store $ctx.Store -BatchId '2019-04' -Side source
                              MU  = Read-MigManifest -Store $ctx.Store -BatchId 'UNBATCHED' -Side source
                              St03 = Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03'
                              Sums = Read-MigStoreRecords -Store $ctx.Store -Name 'manifest.checksums.jsonl'
                              Info = Get-MigBatches -Store $ctx.Store }
                } finally { Close-MigContext -Ctx $ctx }
                $out
            }
        }
        It 'returns the summary counts' {
            $s = $script:result.Summary
            $s.files | Should -Be 4
            $s.dirs | Should -Be 3            # 2019, 2019\03, 2019\04
            $s.bytes | Should -Be ('<html>a</html>'.Length + '<html>bbbb</html>'.Length + '<html>c</html>'.Length)
            $s.errors | Should -Be 0
            $s.hashed | Should -Be 4
            $s.skipped_unchanged | Should -Be 0
            $s.batches | Should -Be 3
            $s.batches_new | Should -Be 3
            $s.Contains('affected_batches') | Should -BeTrue
            @($s.affected_batches) | Should -Be @('2019-03', '2019-04', 'UNBATCHED')     # new batches, ordinal order
            $s.passed | Should -BeTrue
            @($s.detect_by) | Should -Be @('size', 'modified')
        }
        It 'sets state inventoried on every new batch it wrote to' {
            $info = $script:result.Info
            foreach ($b in @('2019-03', '2019-04', 'UNBATCHED')) {
                $info.ContainsKey($b) | Should -BeTrue
                $info[$b]['state'] | Should -Be 'inventoried'
                $info[$b]['inventory']['records'] | Should -BeGreaterThan 0
            }
            $info['2019-03'].ContainsKey('reconcile') | Should -BeFalse
        }
        It 'writes manifest records with batch id, size and correct SHA-256' {
            $m = $script:result.M03
            $m.Keys | Should -Contain '2019\03\a.html'
            $r = $m['2019\03\a.html']
            $r['batch_id'] | Should -Be '2019-03'
            $r['side'] | Should -Be 'source'
            $r['kind'] | Should -Be 'file'
            $r['size_bytes'] | Should -Be 14
            $r['hash_algo'] | Should -Be 'SHA256'
            $r['hash'] | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:env1.Src '2019/03/a.html') -Algorithm SHA256).Hash
            $m['2019\03']['kind'] | Should -Be 'dir'
        }
        It 'applies excludePatterns and puts folders above batch level in the unmatched batch' {
            $script:result.M04.Keys | Should -Not -Contain '2019\04\skip.tmp'
            $script:result.MU.Keys | Should -Contain '2019'
        }
        It 'writes pending status for new files' {
            $script:result.St03['2019\03\a.html'].status | Should -Be 'pending'
            $script:result.St03.Count | Should -Be 2
        }
        It 'C-01: records the checksum (and its algorithm) of every batch manifest' {
            $sums = @($script:result.Sums)
            $sums.Count | Should -Be 3
            $s03 = $sums | Where-Object { $_['batch_id'] -eq '2019-03' }
            $file = Join-Path $script:result.StoreRoot 'batches/2019-03/source.manifest.jsonl'
            $s03['algorithm'] | Should -Be 'SHA256'
            $s03['hash'] | Should -Be (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            $s03['file'] | Should -Be 'batches/2019-03/source.manifest.jsonl'
            $s03['run_id'] | Should -Not -BeNullOrEmpty
            (Get-Content -LiteralPath $script:result.AuditPath -Raw) | Should -Match 'inventory\.manifest_checksums'
        }
    }

    Context 'resume / idempotency (FR-07)' {
        It 'skips unchanged entries and re-hashes only changed ones' {
            $env2 = New-TestInventoryEnv -Name 'inv2'
            InModuleScope NotificationMigration -Parameters @{ cfg = $env2.Config; src = $env2.Src } {
                param($cfg, $src)
                $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
                try {
                    $first = Invoke-MigStageInventory -Ctx $ctx
                    $first.hashed | Should -Be 4

                    $second = Invoke-MigStageInventory -Ctx $ctx
                    $second.hashed | Should -Be 0
                    $second.skipped_unchanged | Should -Be 7
                    $second.files | Should -Be 4
                    $second.bytes | Should -Be $first.bytes
                    $second.new_or_changed | Should -Be 0

                    # Change one file (content + size + mtime) and add one.
                    $p = Join-Path $src '2019/03/b.html'
                    [IO.File]::WriteAllText($p, '<html>changed content</html>')
                    [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddMinutes(5))
                    [IO.File]::WriteAllText((Join-Path $src '2019/03/new.html'), '<html>new</html>')
                    $third = Invoke-MigStageInventory -Ctx $ctx
                    $third.hashed | Should -Be 2
                    $third.new_or_changed | Should -BeGreaterOrEqual 2

                    $m = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source
                    $m['2019\03\b.html']['size_bytes'] | Should -Be '<html>changed content</html>'.Length
                    $m['2019\03\new.html']['hash'] | Should -Not -BeNullOrEmpty
                    # Status events: 2 initial + 1 changed + 1 new; unchanged files were not re-queued.
                    @(Read-MigStoreRecords -Store $ctx.Store -Name 'status.events.jsonl' -BatchId '2019-03').Count | Should -Be 4
                } finally { Close-MigContext -Ctx $ctx }
            }
        }

        It 'with skipUnchanged=false re-hashes everything but does not re-queue unchanged files' {
            $env3 = New-TestInventoryEnv -Name 'inv3' -Inventory @{ skipUnchanged = $false }
            InModuleScope NotificationMigration -Parameters @{ cfg = $env3.Config } {
                param($cfg)
                $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
                try {
                    [void](Invoke-MigStageInventory -Ctx $ctx)
                    $again = Invoke-MigStageInventory -Ctx $ctx
                    $again.hashed | Should -Be 4
                    $again.skipped_unchanged | Should -Be 0
                    $again.new_or_changed | Should -Be 0
                    @(Read-MigStoreRecords -Store $ctx.Store -Name 'status.events.jsonl' -BatchId '2019-03').Count | Should -Be 2
                } finally { Close-MigContext -Ctx $ctx }
            }
        }

        It 'works in DryRun (read-only on source)' {
            $env4 = New-TestInventoryEnv -Name 'inv4'
            $before = @(Get-ChildItem -LiteralPath $env4.Src -Recurse | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.LastWriteTimeUtc.Ticks, $(if ($_.PSIsContainer) { 0 } else { $_.Length }) })
            InModuleScope NotificationMigration -Parameters @{ cfg = $env4.Config } {
                param($cfg)
                $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker' -DryRun
                try { (Invoke-MigStageInventory -Ctx $ctx).files | Should -Be 4 } finally { Close-MigContext -Ctx $ctx }
            }
            $after = @(Get-ChildItem -LiteralPath $env4.Src -Recurse | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.LastWriteTimeUtc.Ticks, $(if ($_.PSIsContainer) { 0 } else { $_.Length }) })
            $after | Should -Be $before
        }
    }

    Context 'scan errors' {
        It 'opens a scan_error exception for an unreadable file and directory, once' -Skip:(([System.IO.Path]::DirectorySeparatorChar -eq [char]'\') -or ([Environment]::UserName -eq 'root')) {
            $env5 = New-TestInventoryEnv -Name 'inv5'
            $locked = Join-Path $env5.Src '2019/03/locked.html'
            $lockedDir = Join-Path $env5.Src '2019/04/private'
            [IO.File]::WriteAllText($locked, 'secret')
            New-Item -ItemType Directory -Path $lockedDir | Out-Null
            & chmod 000 $locked
            & chmod 000 $lockedDir
            try {
                InModuleScope NotificationMigration -Parameters @{ cfg = $env5.Config } {
                    param($cfg)
                    $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
                    try {
                        $s = Invoke-MigStageInventory -Ctx $ctx
                        $s.errors | Should -Be 2
                        $s.exceptions_opened | Should -Be 2
                        $ex = @(Get-MigExceptions -Store $ctx.Store -Status open)
                        $ex.Count | Should -Be 2
                        @($ex | ForEach-Object { $_['category'] } | Select-Object -Unique) | Should -Be @('scan_error')
                        ($ex | Where-Object { $_['rel_path'] -eq '2019\03\locked.html' })['batch_id'] | Should -Be '2019-03'
                        ($ex | Where-Object { $_['rel_path'] -eq '2019\04\private' })['batch_id'] | Should -Be '2019-04'
                        $m = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source
                        $m['2019\03\locked.html']['error'] | Should -Not -BeNullOrEmpty
                        $m['2019\03\locked.html']['hash'] | Should -BeNullOrEmpty
                        (Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03').ContainsKey('2019\03\locked.html') | Should -BeFalse

                        # Re-run: errored entries are retried (never skipped) but no duplicate exception is opened.
                        $again = Invoke-MigStageInventory -Ctx $ctx
                        $again.errors | Should -Be 2
                        $again.exceptions_opened | Should -Be 0
                        @(Get-MigExceptions -Store $ctx.Store -Status open).Count | Should -Be 2
                    } finally { Close-MigContext -Ctx $ctx }
                }
            } finally {
                & chmod 755 $lockedDir
                & chmod 644 $locked
            }
        }
    }

    It 'fails clearly when the source root does not exist' {
        $env6 = New-TestInventoryEnv -Name 'inv6'
        Remove-Item -LiteralPath $env6.Src -Recurse -Force
        InModuleScope NotificationMigration -Parameters @{ cfg = $env6.Config } {
            param($cfg)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try { { Invoke-MigStageInventory -Ctx $ctx } | Should -Throw '*sourceRoot*' } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'assigns batches with a date strategy' {
        $env7 = New-TestInventoryEnv -Name 'inv7'
        Get-ChildItem -LiteralPath $env7.Src -Recurse -File | ForEach-Object { [IO.File]::SetLastWriteTimeUtc($_.FullName, [DateTime]'2018-06-15T00:00:00Z') }
        InModuleScope NotificationMigration -Parameters @{ cfg = $env7.Config } {
            param($cfg)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker' -Override @{ batching = @{ strategy = 'yearMonth'; options = @{ dateField = 'modified_utc' } }; inventory = @{ includeDirectories = $false } }
            try {
                $s = Invoke-MigStageInventory -Ctx $ctx
                $s.batches | Should -Be 1
                (Read-MigManifest -Store $ctx.Store -BatchId '2018-06' -Side source).Count | Should -Be 4
                # Second run: stat -> same batch -> unchanged
                (Invoke-MigStageInventory -Ctx $ctx).skipped_unchanged | Should -Be 4
            } finally { Close-MigContext -Ctx $ctx }
        }
    }
}

Describe 'Inventory batch state (final-report false-pass guard)' {
    It 'marks an existing batch with new or changed files delta_pending + reconcile.stale, and leaves unchanged batches untouched' {
        $e = New-TestInventoryEnv -Name 'invState'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                Set-MigBatchInfo -Store $ctx.Store -BatchId '2019-03' -Data @{ state = 'reconciled'; reconcile = @{ passed = $true; run_id = 'r1'; missing = 0 } }
                Set-MigBatchInfo -Store $ctx.Store -BatchId '2019-04' -Data @{ state = 'reconciled'; reconcile = @{ passed = $true; run_id = 'r1' } }
                $events04 = @(Read-MigStoreRecords -Store $ctx.Store -Name 'batches.jsonl' | Where-Object { $_['batch_id'] -eq '2019-04' }).Count

                [IO.File]::WriteAllText((Join-Path $src '2019/03/added.html'), '<html>added</html>')
                $s = Invoke-MigStageInventory -Ctx $ctx
                $s.batches_changed | Should -Be 1          # 2019-03 (new file + its folder's mtime); 2019-04 and UNBATCHED unchanged
                @($s.affected_batches) | Should -Be @('2019-03')
                $info = Get-MigBatches -Store $ctx.Store
                $info['2019-03']['state'] | Should -Be 'delta_pending'
                $info['2019-03']['reconcile']['stale'] | Should -BeTrue
                $info['2019-03']['reconcile']['passed'] | Should -BeTrue      # merged, not replaced
                $info['2019-03']['reconcile']['run_id'] | Should -Be 'r1'
                $info['2019-04']['state'] | Should -Be 'reconciled'
                @(Read-MigStoreRecords -Store $ctx.Store -Name 'batches.jsonl' | Where-Object { $_['batch_id'] -eq '2019-04' }).Count | Should -Be $events04
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'does not touch batch info on a re-run without changes (skipUnchanged=false re-hash)' {
        $e = New-TestInventoryEnv -Name 'invState2' -Inventory @{ skipUnchanged = $false }
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config } {
            param($cfg)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                $before = @(Read-MigStoreRecords -Store $ctx.Store -Name 'batches.jsonl').Count
                $again = Invoke-MigStageInventory -Ctx $ctx
                $again.hashed | Should -Be 4
                $again.batches_changed | Should -Be 0
                $again.batches_new | Should -Be 0
                $again.Contains('affected_batches') | Should -BeTrue      # present and empty: no batch is invalidated
                @($again.affected_batches).Count | Should -Be 0
                @(Read-MigStoreRecords -Store $ctx.Store -Name 'batches.jsonl').Count | Should -Be $before
            } finally { Close-MigContext -Ctx $ctx }
        }
    }
}

Describe 'Inventory detectBy (config)' {
    It 'uses inventory.detectBy for the resume check: a modified-only change is ignored with detectBy size' {
        $e = New-TestInventoryEnv -Name 'invDetect1' -Inventory @{ detectBy = @('size') }
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                [IO.File]::SetLastWriteTimeUtc((Join-Path $src '2019/03/a.html'), [DateTime]::UtcNow.AddDays(2))
                $s = Invoke-MigStageInventory -Ctx $ctx
                $s.hashed | Should -Be 0
                $s.new_or_changed | Should -Be 0
                @($s.detect_by) | Should -Be @('size')
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'the default (size, modified) picks up the same modified-only change' {
        $e = New-TestInventoryEnv -Name 'invDetect2'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                [IO.File]::SetLastWriteTimeUtc((Join-Path $src '2019/03/a.html'), [DateTime]::UtcNow.AddDays(2))
                $s = Invoke-MigStageInventory -Ctx $ctx
                $s.hashed | Should -Be 1
                $s.new_or_changed | Should -Be 1
                (Get-MigBatches -Store $ctx.Store)['2019-03']['state'] | Should -Be 'delta_pending'
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'with hash in detectBy re-hashes every file and catches a same-size same-mtime edit' {
        $e = New-TestInventoryEnv -Name 'invDetect3' -Inventory @{ detectBy = @('size', 'modified', 'hash') }
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                $p = Join-Path $src '2019/03/a.html'
                $t = [IO.File]::GetLastWriteTimeUtc($p)
                [IO.File]::WriteAllText($p, '<html>X</html>')
                [IO.File]::SetLastWriteTimeUtc($p, $t)
                $s = Invoke-MigStageInventory -Ctx $ctx
                $s.hashed | Should -Be 4
                $s.skipped_unchanged | Should -Be 3        # the directories
                $s.new_or_changed | Should -Be 1
                (Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source)['2019\03\a.html']['hash'] | Should -Be (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'rejects an unknown detectBy field with a clear error (at config load, before any stage runs)' {
        $e = New-TestInventoryEnv -Name 'invDetect4' -Inventory @{ detectBy = @('size', 'colour') }
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config } {
            param($cfg)
            { New-MigContext -ConfigPath $cfg -Operator 'maker' } | Should -Throw "*inventory.detectBy*colour*"
        }
    }
}

Describe 'Inventory case-only duplicates' {
    It 'opens a scan_error exception for the duplicate and keeps the first entry in the manifest' {
        $e = New-TestInventoryEnv -Name 'invCase'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config } {
            param($cfg)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                $real = @(Get-MigTreeEntries -Root $ctx.Config.paths.sourceRoot -ExcludePatterns @('\.tmp$') -UseLongPath $false)
                $dup = @{ rel_path = '2019\03\A.HTML'; kind = 'error'; error = 'case_duplicate_of:a.html' }
                Mock Get-MigInvWalk { $real; $dup }
                $s = Invoke-MigStageInventory -Ctx $ctx
                $s.errors | Should -Be 1
                $s.passed | Should -BeFalse
                $s.exceptions_opened | Should -Be 1
                $ex = @(Get-MigExceptions -Store $ctx.Store -BatchId '2019-03')
                $ex.Count | Should -Be 1
                $ex[0]['category'] | Should -Be 'scan_error'
                $ex[0]['detail'] | Should -Be 'case_duplicate_of:a.html'
                $m = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source
                $m['2019\03\a.html']['kind'] | Should -Be 'file'
                $m['2019\03\a.html']['error'] | Should -BeNullOrEmpty
                $m['2019\03\a.html']['hash'] | Should -Not -BeNullOrEmpty
            } finally { Close-MigContext -Ctx $ctx }
        }
    }
}

Describe 'Inventory checksums and CSV export (C-01)' {
    It 'uses inventory.hash.algorithm for manifest checksums' {
        $e = New-TestInventoryEnv -Name 'invAlg' -Inventory @{ hash = @{ algorithm = 'SHA512' } }
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config } {
            param($cfg)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                $r = @(Read-MigStoreRecords -Store $ctx.Store -Name 'manifest.checksums.jsonl' | Where-Object { $_['batch_id'] -eq '2019-04' })[0]
                $r['algorithm'] | Should -Be 'SHA512'
                $r['hash'] | Should -Be (Get-FileHash -LiteralPath (Get-MigStorePath -Store $ctx.Store -Name 'source.manifest.jsonl' -BatchId '2019-04') -Algorithm SHA512).Hash
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'only re-records checksums for batches written in the run (plus batches without one)' {
        $e = New-TestInventoryEnv -Name 'invSums'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                [IO.File]::WriteAllText((Join-Path $src '2019/04/more.html'), 'more')
                $s = Invoke-MigStageInventory -Ctx $ctx
                $s.manifest_checksums | Should -Be 1
                $all = @(Read-MigStoreRecords -Store $ctx.Store -Name 'manifest.checksums.jsonl')
                $last04 = @($all | Where-Object { $_['batch_id'] -eq '2019-04' })[-1]
                $last04['run_id'] | Should -Be $ctx.RunId
                $last04['hash'] | Should -Be (Get-FileHash -LiteralPath (Get-MigStorePath -Store $ctx.Store -Name 'source.manifest.jsonl' -BatchId '2019-04') -Algorithm SHA256).Hash
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'exports a batch manifest as formula-safe UTF-8 BOM CSV with a checksum sidecar and an audit event' {
        $e = New-TestInventoryEnv -Name 'invCsv'
        [IO.File]::WriteAllText((Join-Path $e.Src '2019/03/=cmd.html'), 'x')
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config } {
            param($cfg)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                $r = Export-MigManifestCsv -Ctx $ctx -BatchId '2019-03'
                $r.path | Should -BeLike (Join-Path (Join-Path $ctx.Config._resolved.reportDir 'manifests') '2019-03.source.manifest.*.csv')
                $r.rows | Should -Be 4                    # 2019\03, a, b, =cmd
                $bytes = [IO.File]::ReadAllBytes($r.path)
                @($bytes[0..2]) | Should -Be @(0xEF, 0xBB, 0xBF)
                $rows = @(Import-Csv -LiteralPath $r.path)
                $rows.Count | Should -Be 4
                @($rows | ForEach-Object { $_.rel_path }) | Should -Be @('2019\03', '2019\03\=cmd.html', '2019\03\a.html', '2019\03\b.html')
                ($rows | Where-Object { $_.rel_path -eq '2019\03\a.html' }).hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $ctx.Config.paths.sourceRoot '2019/03/a.html') -Algorithm SHA256).Hash
                $r.checksum_path | Should -Be ($r.path + '.sha256')
                (Get-Content -LiteralPath $r.checksum_path -Raw).Trim() | Should -Be ('{0}  {1}' -f (Get-FileHash -LiteralPath $r.path -Algorithm SHA256).Hash, [IO.Path]::GetFileName($r.path))
                (Get-Content -LiteralPath $ctx.Audit.Path -Raw) | Should -Match 'inventory\.manifest_exported'
                { Export-MigManifestCsv -Ctx $ctx -BatchId 'NOPE' } | Should -Throw '*no source manifest*'
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'CSV cells neutralise spreadsheet formulas but keep numbers' {
        InModuleScope NotificationMigration {
            ConvertTo-MigInvCsvCell '=1+2' | Should -Be '"''=1+2"'
            ConvertTo-MigInvCsvCell '@SUM(A1)' | Should -Be '"''@SUM(A1)"'
            ConvertTo-MigInvCsvCell '+x' | Should -Be '"''+x"'
            ConvertTo-MigInvCsvCell '-5' | Should -Be '"-5"'
            ConvertTo-MigInvCsvCell 12345 | Should -Be '"12345"'
            ConvertTo-MigInvCsvCell 'a"b' | Should -Be '"a""b"'
            ConvertTo-MigInvCsvCell $null | Should -Be '""'
        }
    }
}

Describe 'Inventory manifest index cache' {
    It 'stores timestamps as ticks and keeps entries minimal' {
        InModuleScope NotificationMigration {
            $idx = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
            Add-MigInvIndexEntries -Index $idx -Records @(
                [ordered]@{ rel_path = 'a\x.html'; kind = 'file'; size_bytes = 12; modified_utc = '2019-03-01T10:00:00.1234567Z'; created_utc = '2019-02-01T00:00:00.0000000Z'; attributes = 'Archive'; hash = 'AB'; error = $null },
                [ordered]@{ rel_path = 'a\y.html'; kind = 'file'; size_bytes = 1; modified_utc = '2019-03-01T10:00:00Z'; hash = 'CD' },
                [ordered]@{ rel_path = 'a\y.html'; deleted = $true }
            )
            $idx.Count | Should -Be 1
            $en = $idx['A\X.HTML']
            $en.Count | Should -Be 7
            $en[1] | Should -BeOfType [long]
            $en[2] | Should -BeOfType [long]
            $en[2] | Should -Be ([DateTime]::Parse('2019-03-01T10:00:00.1234567Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)).Ticks
            $en[6] | Should -BeFalse
        }
    }

    It 'bounds the LRU by the total number of records held' {
        $e = New-TestInventoryEnv -Name 'invCache'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config } {
            param($cfg)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker' -Override @{ inventory = @{ manifestCacheRecords = 4 } }
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                $cache = New-MigInvManifestCache -Ctx $ctx
                $cache.Capacity | Should -Be 4
                [void](Get-MigInvManifestIndex -Cache $cache -BatchId '2019-03')    # 3 records
                $cache.Held | Should -Be 3
                [void](Get-MigInvManifestIndex -Cache $cache -BatchId '2019-04')    # 3 records -> 6 > 4, evict 2019-03
                $cache.Map.ContainsKey('2019-03') | Should -BeFalse
                $cache.Map.ContainsKey('2019-04') | Should -BeTrue
                $cache.Held | Should -Be 3
            } finally { Close-MigContext -Ctx $ctx }
        }
    }
}
