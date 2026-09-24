#Requires -Modules Pester
# Unit tests: Delta stage (FR-08) - new / changed / missing-on-source detection after inventory.

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking

    function New-TestDeltaEnv {
        param([string] $Name, [hashtable] $Delta = @{})
        $root = Join-Path $TestDrive $Name
        $src = Join-Path $root 'src'
        foreach ($d in @('2019/03', '2019/04', '2020/01')) { New-Item -ItemType Directory -Path (Join-Path $src $d) -Force | Out-Null }
        [IO.File]::WriteAllText((Join-Path $src '2019/03/a.html'), '<html>a</html>')
        [IO.File]::WriteAllText((Join-Path $src '2019/03/b.html'), '<html>b</html>')
        [IO.File]::WriteAllText((Join-Path $src '2019/04/c.html'), '<html>c</html>')
        [IO.File]::WriteAllText((Join-Path $src '2020/01/d.html'), '<html>d</html>')
        $dl = @{ detectBy = @('size', 'modified') }
        foreach ($k in $Delta.Keys) { $dl[$k] = $Delta[$k] }
        $cfg = @{
            paths     = @{ sourceRoot = $src; targetRoot = (Join-Path $root 'tgt'); workDir = (Join-Path $root 'work') }
            inventory = @{ aclReader = 'none'; threads = 2; chunkSize = 2 }
            compare   = @{ fileFields = @('exists', 'size', 'hash', 'created', 'modified', 'attributes') }
            copy      = @{ engine = 'dotnet' }
            delta     = $dl
        }
        $cfgPath = Join-Path $root 'migration.config.json'
        [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 10))
        return @{ Root = $root; Src = $src; Config = $cfgPath }
    }
}

Describe 'Invoke-MigStageDelta' {
    It 'reports nothing when the source is unchanged' {
        $e = New-TestDeltaEnv -Name 'd0'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config } {
            param($cfg)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                $s = Invoke-MigStageDelta -Ctx $ctx
                $s.new | Should -Be 0
                $s.changed | Should -Be 0
                $s.missing_on_source | Should -Be 0
                $s.Contains('affected_batches') | Should -BeTrue
                @($s.affected_batches).Count | Should -Be 0
                $s.source_files | Should -Be 4
                $s.source_bytes | Should -Be (4 * '<html>a</html>'.Length)
                $s.passed | Should -BeTrue
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'detects new, changed and deleted entries' {
        $e = New-TestDeltaEnv -Name 'd1'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                [void](Invoke-MigStageBatching -Ctx $ctx)
                Set-MigBatchInfo -Store $ctx.Store -BatchId '2019-03' -Data @{ state = 'reconciled'; reconcile = @{ passed = $true; run_id = 'r1' } }

                [IO.File]::WriteAllText((Join-Path $src '2019/03/new.html'), '<html>new</html>')          # new
                $b = Join-Path $src '2019/04/c.html'
                [IO.File]::WriteAllText($b, '<html>c changed</html>')                                      # changed
                [IO.File]::SetLastWriteTimeUtc($b, [DateTime]::UtcNow.AddMinutes(3))
                $dir01 = Join-Path $src '2020/01'
                $dirTime = [IO.Directory]::GetLastWriteTimeUtc($dir01)
                Remove-Item -LiteralPath (Join-Path $src '2020/01/d.html')                                 # deleted
                [IO.Directory]::SetLastWriteTimeUtc($dir01, $dirTime)   # isolate: folder mtime change is its own case (below)

                $sumsBefore = @(Read-MigStoreRecords -Store $ctx.Store -Name 'manifest.checksums.jsonl').Count
                $s = Invoke-MigStageDelta -Ctx $ctx
                $s.new | Should -Be 1
                $s.changed | Should -BeGreaterOrEqual 1
                $s.missing_on_source | Should -Be 1
                $s.affected_batches | Should -Contain '2019-03'
                $s.affected_batches | Should -Contain '2019-04'
                $s.affected_batches | Should -Not -Contain '2020-01'

                # New / changed records appended with hashes; pending status written.
                $m3 = Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source
                $m3['2019\03\new.html']['hash'] | Should -Not -BeNullOrEmpty
                (Get-MigFileStatus -Store $ctx.Store -BatchId '2019-03')['2019\03\new.html'].status | Should -Be 'pending'
                $m4 = Read-MigManifest -Store $ctx.Store -BatchId '2019-04' -Side source
                $m4['2019\04\c.html']['size_bytes'] | Should -Be '<html>c changed</html>'.Length
                $m4['2019\04\c.html']['hash'] | Should -Be (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash

                # Batch state goes back into the copy loop.
                $info = Get-MigBatches -Store $ctx.Store
                $info['2019-03']['state'] | Should -Be 'delta_pending'
                $info['2019-04']['state'] | Should -Be 'delta_pending'
                $info['2020-01']['state'] | Should -Be 'planned'
                $info['2019-03']['reconcile']['stale'] | Should -BeTrue
                $info['2019-03']['reconcile']['passed'] | Should -BeTrue           # merged into the existing keys
                $info['2019-04']['reconcile']['stale'] | Should -BeTrue
                $info['2020-01'].ContainsKey('reconcile') | Should -BeFalse

                # Plan totals refreshed for the affected batches (same as Batching).
                $info['2019-03']['plan']['file_count'] | Should -Be 3
                $info['2019-03']['plan']['total_bytes'] | Should -Be ('<html>a</html>'.Length + '<html>b</html>'.Length + '<html>new</html>'.Length)
                $info['2019-04']['plan']['total_bytes'] | Should -Be '<html>c changed</html>'.Length
                $info['2019-03']['delta']['new'] | Should -Be 1

                # C-01 checksums re-recorded for the affected batches, matching the manifests now on disk.
                $sums = @(Read-MigStoreRecords -Store $ctx.Store -Name 'manifest.checksums.jsonl' | Select-Object -Skip $sumsBefore)
                foreach ($bid in @('2019-03', '2019-04')) {
                    $r = @($sums | Where-Object { $_['batch_id'] -eq $bid })[-1]
                    $r['algorithm'] | Should -Be 'SHA256'
                    $r['hash'] | Should -Be (Get-FileHash -LiteralPath (Get-MigStorePath -Store $ctx.Store -Name 'source.manifest.jsonl' -BatchId $bid) -Algorithm SHA256).Hash
                }
                @($sums | Where-Object { $_['batch_id'] -eq '2020-01' }).Count | Should -Be 0

                # Summary: throughput inputs and a truthful result (a deleted source file needs a decision).
                $s.files | Should -Be 4                 # a, b, new, c (d was deleted)
                @($s.affected_batches) | Should -Be @('2019-03', '2019-04')                 # exact, ordinal order
                # Whole-manifest totals after the Delta: d.html is still in the manifest (not tombstoned).
                $s.source_files | Should -Be 5
                $s.source_bytes | Should -Be ('<html>a</html>'.Length + '<html>b</html>'.Length + '<html>new</html>'.Length + '<html>c changed</html>'.Length + '<html>d</html>'.Length)
                $s.bytes | Should -BeGreaterThan 0
                $s.errors | Should -Be 0
                $s.passed | Should -BeFalse

                # Deleted: not tombstoned, exception opened.
                (Read-MigManifest -Store $ctx.Store -BatchId '2020-01' -Side source).ContainsKey('2020\01\d.html') | Should -BeTrue
                $ex = @(Get-MigExceptions -Store $ctx.Store -Status open | Where-Object { $_['category'] -eq 'source_deleted' })
                $ex.Count | Should -Be 1
                $ex[0]['rel_path'] | Should -Be '2020\01\d.html'
                $ex[0]['batch_id'] | Should -Be '2020-01'

                # Re-run: already recorded -> nothing new, and no duplicate exception.
                $again = Invoke-MigStageDelta -Ctx $ctx
                $again.new | Should -Be 0
                $again.changed | Should -Be 0
                $again.missing_on_source | Should -Be 1
                @(Get-MigExceptions -Store $ctx.Store -Status open | Where-Object { $_['category'] -eq 'source_deleted' }).Count | Should -Be 1
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'flags a folder whose modified time changed (directory timestamps are copied too)' {
        $e = New-TestDeltaEnv -Name 'd6'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                [IO.Directory]::SetLastWriteTimeUtc((Join-Path $src '2020/01'), [DateTime]::UtcNow.AddHours(1))
                $s = Invoke-MigStageDelta -Ctx $ctx
                $s.changed | Should -Be 1
                $s.affected_batches | Should -Be @('2020-01')
                (Get-MigFileStatus -Store $ctx.Store -BatchId '2020-01').Count | Should -Be 1   # only the initial file event; dirs get no status
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'with detectBy hash catches a content change that keeps size and mtime' {
        $e = New-TestDeltaEnv -Name 'd2' -Delta @{ detectBy = @('hash') }
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                $p = Join-Path $src '2019/03/a.html'
                $t = [IO.File]::GetLastWriteTimeUtc($p)
                [IO.File]::WriteAllText($p, '<html>X</html>')        # same length
                [IO.File]::SetLastWriteTimeUtc($p, $t)                # same mtime
                $s = Invoke-MigStageDelta -Ctx $ctx
                $s.changed | Should -Be 1
                $s.new | Should -Be 0
                $s.affected_batches | Should -Be @('2019-03')
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'size/modified detection ignores a same-size same-mtime edit (documented limitation)' {
        $e = New-TestDeltaEnv -Name 'd3'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                $p = Join-Path $src '2019/03/a.html'
                $t = [IO.File]::GetLastWriteTimeUtc($p)
                [IO.File]::WriteAllText($p, '<html>X</html>')
                [IO.File]::SetLastWriteTimeUtc($p, $t)
                (Invoke-MigStageDelta -Ctx $ctx).changed | Should -Be 0
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'always re-hashes a changed file (no carried-forward hash)' {
        $e = New-TestDeltaEnv -Name 'd4' -Delta @{ detectBy = @('modified') }
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                $p = Join-Path $src '2019/03/b.html'
                [IO.File]::WriteAllText($p, '<html>B</html>')                     # same size, new content
                [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddDays(1))
                $s = Invoke-MigStageDelta -Ctx $ctx
                $s.changed | Should -Be 1
                $r = (Read-MigManifest -Store $ctx.Store -BatchId '2019-03' -Side source)['2019\03\b.html']
                $r['hash'] | Should -Be (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
                $r.Contains('hash_carried_forward') | Should -BeFalse
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'rejects the removed delta.rehashChanged option' {
        $e = New-TestDeltaEnv -Name 'd7' -Delta @{ rehashChanged = $false }
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config } {
            param($cfg)
            { New-MigContext -ConfigPath $cfg -Operator 'maker' } | Should -Throw '*delta.rehashChanged*'
        }
    }

    It 'puts a batch that did not exist before in state inventoried' {
        $e = New-TestDeltaEnv -Name 'd8'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                [void](Invoke-MigStageBatching -Ctx $ctx)
                New-Item -ItemType Directory -Path (Join-Path $src '2021/05') -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $src '2021/05/e.html'), '<html>e</html>')
                $s = Invoke-MigStageDelta -Ctx $ctx
                $s.affected_batches | Should -Contain '2021-05'
                $info = Get-MigBatches -Store $ctx.Store
                $info['2021-05']['state'] | Should -Be 'inventoried'
                $info['2021-05'].ContainsKey('reconcile') | Should -BeFalse
                $info['2021-05']['plan']['file_count'] | Should -Be 1
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'excludes files with scan errors from source_files / source_bytes' {
        $e = New-TestDeltaEnv -Name 'd10'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config } {
            param($cfg)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                # A file record with a scan error that the walk cannot refresh (the entry is not listable).
                Write-MigManifest -Store $ctx.Store -BatchId '2020-01' -Side source -Records @(
                    [ordered]@{ rel_path = '2020\01\locked.html'; kind = 'file'; batch_id = '2020-01'; side = 'source'; size_bytes = 99; error = 'denied' })
                $s = Invoke-MigStageDelta -Ctx $ctx
                $s.source_files | Should -Be 4
                $s.source_bytes | Should -Be (4 * '<html>a</html>'.Length)
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'writes one summary audit event, not one per file' {
        $e = New-TestDeltaEnv -Name 'd9'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                1..5 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $src "2019/03/n$_.html"), "n$_") }
                $s = Invoke-MigStageDelta -Ctx $ctx
                $s.new | Should -Be 5
                $log = Get-Content -LiteralPath $ctx.Audit.Path
                @($log | Where-Object { $_ -match '"event":"delta\.new"' }).Count | Should -Be 0
                $done = @($log | Where-Object { $_ -match '"event":"delta\.completed"' })
                $done.Count | Should -Be 1
                $done[0] | Should -Match 'n3\.html'
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'writes nothing to the store under DryRun' {
        $e = New-TestDeltaEnv -Name 'd5'
        InModuleScope NotificationMigration -Parameters @{ cfg = $e.Config; src = $e.Src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try { [void](Invoke-MigStageInventory -Ctx $ctx); [void](Invoke-MigStageBatching -Ctx $ctx) } finally { Close-MigContext -Ctx $ctx }

            [IO.File]::WriteAllText((Join-Path $src '2019/03/new.html'), 'n')
            Remove-Item -LiteralPath (Join-Path $src '2019/04/c.html')
            $dry = New-MigContext -ConfigPath $cfg -Operator 'maker' -DryRun
            try {
                $manifestBefore = [IO.File]::ReadAllText((Get-MigStorePath -Store $dry.Store -Name 'source.manifest.jsonl' -BatchId '2019-03'))
                $s = Invoke-MigStageDelta -Ctx $dry
                $s.new | Should -Be 1
                $s.missing_on_source | Should -Be 1
                $s.dry_run | Should -BeTrue
                [IO.File]::ReadAllText((Get-MigStorePath -Store $dry.Store -Name 'source.manifest.jsonl' -BatchId '2019-03')) | Should -Be $manifestBefore
                @(Get-MigExceptions -Store $dry.Store).Count | Should -Be 0
                (Get-MigBatches -Store $dry.Store)['2019-03']['state'] | Should -Be 'planned'
            } finally { Close-MigContext -Ctx $dry }
        }
    }
}
