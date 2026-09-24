#Requires -Modules Pester
# Unit tests: Batch providers (regex, yearMonth, year, folderDepth) and the Batching stage (FR-02, C-04).

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
}

Describe 'Batch providers' {
    Context 'regex (default)' {
        BeforeAll {
            $script:opts = @{ pattern = '^(?<y>\d{4})[\\/](?<m>\d{2})'; template = '{y}-{m}'; unmatchedBatchId = 'UNBATCHED' }
        }
        It 'fills the template from named groups for files' {
            InModuleScope NotificationMigration -Parameters @{ o = $script:opts } {
                param($o)
                $sb = Get-MigProvider -Kind Batch -Name 'regex'
                & $sb '2019\03\a.html' @{ kind = 'file' } $o | Should -Be '2019-03'
                & $sb '2019\03\17\deep\b.htm' @{ kind = 'file' } $o | Should -Be '2019-03'
            }
        }
        It 'accepts forward slashes (canonicalised) and numbered groups' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'regex'
                & $sb '2020/11/x.html' @{ kind = 'file' } @{ pattern = '^(\d{4})\\(\d{2})'; template = 'B{1}{2}' } | Should -Be 'B202011'
            }
        }
        It 'puts unmatched files in unmatchedBatchId' {
            InModuleScope NotificationMigration -Parameters @{ o = $script:opts } {
                param($o)
                $sb = Get-MigProvider -Kind Batch -Name 'regex'
                & $sb 'readme.txt' @{ kind = 'file' } $o | Should -Be 'UNBATCHED'
                & $sb 'misc\2019\03\a.html' @{ kind = 'file' } $o | Should -Be 'UNBATCHED'
            }
        }
        It 'places a directory in the batch its path matches' {
            InModuleScope NotificationMigration -Parameters @{ o = $script:opts } {
                param($o)
                $sb = Get-MigProvider -Kind Batch -Name 'regex'
                & $sb '2019\03' @{ kind = 'dir' } $o | Should -Be '2019-03'
            }
        }
        It 'sends directories above the batch level to parentDirBatchId, else unmatchedBatchId' {
            InModuleScope NotificationMigration -Parameters @{ o = $script:opts } {
                param($o)
                $sb = Get-MigProvider -Kind Batch -Name 'regex'
                & $sb '2019' @{ kind = 'dir' } $o | Should -Be 'UNBATCHED'
                $o2 = @{} + $o; $o2['parentDirBatchId'] = 'STRUCTURE'
                & $sb '2019' @{ kind = 'dir' } $o2 | Should -Be 'STRUCTURE'
                & $sb 'loose.html' @{ kind = 'file' } $o2 | Should -Be 'UNBATCHED'
            }
        }
        It 'returns a safe batch id' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'regex'
                & $sb 'Team A\x.html' @{ kind = 'file' } @{ pattern = '^(?<t>[^\\]+)\\'; template = '{t}' } | Should -Be 'Team_A'
            }
        }
        It 'throws on a template group the pattern does not define' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'regex'
                { & $sb '2019\03\a' @{ kind = 'file' } @{ pattern = '^(?<y>\d{4})'; template = '{y}-{q}' } } | Should -Throw '*{q}*'
            }
        }
        It 'throws when the pattern is missing' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'regex'
                { & $sb 'a' @{ kind = 'file' } @{ template = '{y}' } } | Should -Throw '*pattern*'
            }
        }
    }

    Context 'yearMonth / year' {
        It 'derives yyyy-MM from modified_utc by default' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'yearMonth'
                & $sb 'x.html' @{ kind = 'file'; modified_utc = '2019-03-31T23:59:59.0000000Z'; created_utc = '2018-01-01T00:00:00.0000000Z' } @{} | Should -Be '2019-03'
            }
        }
        It 'honours dateField = created_utc and accepts DateTime values' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'yearMonth'
                $rec = @{ kind = 'file'; modified_utc = '2019-03-01T00:00:00Z'; created_utc = [DateTime]::SpecifyKind([DateTime]'2018-07-04T12:00:00', 'Utc') }
                & $sb 'x' $rec @{ dateField = 'created_utc' } | Should -Be '2018-07'
            }
        }
        It 'derives yyyy for year' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'year'
                & $sb 'x' @{ kind = 'file'; modified_utc = '2021-12-31T10:00:00.0000000Z' } @{} | Should -Be '2021'
            }
        }
        It 'uses unmatchedBatchId when no timestamp is available (scan error)' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'yearMonth'
                & $sb 'x' @{ kind = 'error'; error = 'denied' } @{ unmatchedBatchId = 'NODATE' } | Should -Be 'NODATE'
            }
        }
        It 'rejects an unknown dateField' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'year'
                { & $sb 'x' @{ kind = 'file'; modified_utc = '2021-01-01T00:00:00Z' } @{ dateField = 'accessed' } } | Should -Throw '*dateField*'
            }
        }
    }

    Context 'folderDepth' {
        It 'joins the first N folder segments with -' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'folderDepth'
                & $sb '2019\03\17\a.html' @{ kind = 'file' } @{ depth = 2 } | Should -Be '2019-03'
                & $sb '2019\03\a.html' @{ kind = 'file' } @{ depth = 2 } | Should -Be '2019-03'
                & $sb '2019\03' @{ kind = 'dir' } @{ depth = 2 } | Should -Be '2019-03'
                & $sb '2019\a.html' @{ kind = 'file' } @{ depth = 1 } | Should -Be '2019'
            }
        }
        It 'uses the fallback for entries above the batch level' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'folderDepth'
                & $sb '2019\a.html' @{ kind = 'file' } @{ depth = 2; unmatchedBatchId = 'U' } | Should -Be 'U'
                & $sb '2019' @{ kind = 'dir' } @{ depth = 2; unmatchedBatchId = 'U' } | Should -Be 'U'
                & $sb '2019' @{ kind = 'dir' } @{ depth = 2; unmatchedBatchId = 'U'; parentDirBatchId = 'P' } | Should -Be 'P'
                & $sb 'root.html' @{ kind = 'file' } @{ depth = 1 } | Should -Be 'UNBATCHED'
            }
        }
        It 'requires depth >= 1' {
            InModuleScope NotificationMigration {
                $sb = Get-MigProvider -Kind Batch -Name 'folderDepth'
                { & $sb 'a\b' @{ kind = 'file' } @{ depth = 0 } } | Should -Throw '*depth*'
            }
        }
    }

    Context 'compiled options (per-run cache)' {
        It 'compiles options once per options object and picks up edits after a reset' {
            InModuleScope NotificationMigration {
                Reset-MigBatchCompileCache
                $sb = Get-MigProvider -Kind Batch -Name 'regex'
                $o = @{ pattern = '^(?<y>\d{4})\\(?<m>\d{2})'; template = '{y}-{m}' }
                & $sb '2019\03\a.html' @{ kind = 'file' } $o | Should -Be '2019-03'
                $o['template'] = 'M{m}'
                & $sb '2019\03\a.html' @{ kind = 'file' } $o | Should -Be '2019-03'     # same run: compiled once
                Reset-MigBatchCompileCache                                               # next stage run
                & $sb '2019\03\a.html' @{ kind = 'file' } $o | Should -Be 'M03'
                & $sb '2019\03\a.html' @{ kind = 'file' } @{ pattern = '^(?<y>\d{4})'; template = 'Y{y}' } | Should -Be 'Y2019'
            }
        }
        It 'resolves ids through Resolve-MigInvBatchId with the configured strategy' {
            InModuleScope NotificationMigration {
                $res = @{ Name = 'folderDepth'; Script = (Get-MigProvider -Kind Batch -Name 'folderDepth'); Options = @{ depth = 2; parentDirBatchId = 'P' } }
                Reset-MigBatchCompileCache
                Resolve-MigInvBatchId -Resolver $res -RelPath '2019\03\x\a.html' -Record @{ kind = 'file' } | Should -Be '2019-03'
                Resolve-MigInvBatchId -Resolver $res -RelPath '2019' -Record @{ kind = 'dir' } | Should -Be 'P'
                Resolve-MigInvBatchId -Resolver $res -RelPath 'Team A\B C\a.html' -Record @{ kind = 'file' } | Should -Be 'Team_A-B_C'
            }
        }
    }

    It 'registers all strategies' {
        InModuleScope NotificationMigration {
            $names = Get-MigProviderNames -Kind Batch
            foreach ($n in @('regex', 'yearMonth', 'year', 'folderDepth')) { $names | Should -Contain $n }
        }
    }
}

Describe 'Invoke-MigStageBatching' {
    BeforeAll {
        $script:root = Join-Path $TestDrive 'batching'
        $src = Join-Path $script:root 'src'
        foreach ($d in @('2019/03', '2019/04', '2020/01')) { New-Item -ItemType Directory -Path (Join-Path $src $d) -Force | Out-Null }
        [IO.File]::WriteAllText((Join-Path $src '2019/03/a.html'), '<html>a</html>')
        [IO.File]::WriteAllText((Join-Path $src '2019/03/b.html'), '<html>bb</html>')
        [IO.File]::WriteAllText((Join-Path $src '2019/03/empty.html'), '')
        [IO.File]::WriteAllText((Join-Path $src '2019/04/c.html'), '<html>c</html>')
        [IO.File]::WriteAllText((Join-Path $src '2020/01/d.html'), '<html>d</html>')
        [IO.File]::WriteAllText((Join-Path $src 'loose.txt'), 'x')
        $cfg = @{
            paths     = @{ sourceRoot = $src; targetRoot = (Join-Path $script:root 'tgt'); workDir = (Join-Path $script:root 'work') }
            inventory = @{ aclReader = 'none'; threads = 2; chunkSize = 2 }
            compare   = @{ fileFields = @('exists', 'size', 'hash', 'created', 'modified', 'attributes') }
            copy      = @{ engine = 'dotnet' }
        }
        $script:cfgPath = Join-Path $script:root 'migration.config.json'
        [IO.File]::WriteAllText($script:cfgPath, ($cfg | ConvertTo-Json -Depth 10))
    }

    It 'plans per-batch totals, sorted oldest first, and sets state planned' {
        InModuleScope NotificationMigration -Parameters @{ cfgPath = $script:cfgPath } {
            param($cfgPath)
            $ctx = New-MigContext -ConfigPath $cfgPath -Operator 'maker'
            try {
                [void](Invoke-MigStageInventory -Ctx $ctx)
                $s = Invoke-MigStageBatching -Ctx $ctx
                @($s.batches | ForEach-Object { $_.batch_id }) | Should -Be @('2019-03', '2019-04', '2020-01', 'UNBATCHED')
                $s.batch_count | Should -Be 4
                $s.files | Should -Be 6
                $b = $s.batches[0]
                $b.file_count | Should -Be 3
                $b.dir_count | Should -Be 1           # the 2019\03 folder itself
                $b.zero_byte_count | Should -Be 1
                $b.total_bytes | Should -Be ('<html>a</html>'.Length + '<html>bb</html>'.Length)
                $b.error_count | Should -Be 0
                # '2019' and '2020' folders are above the batch level -> UNBATCHED together with loose.txt
                $u = $s.batches[3]
                $u.file_count | Should -Be 1
                $u.dir_count | Should -Be 2
                $s.bytes | Should -Be (@($s.batches | ForEach-Object { $_.total_bytes }) | Measure-Object -Sum).Sum

                $info = Get-MigBatches -Store $ctx.Store
                $info['2019-03']['state'] | Should -Be 'planned'          # was 'inventoried'
                $info['2019-03']['plan']['file_count'] | Should -Be 3
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'does not reset the state of a batch that already progressed' {
        InModuleScope NotificationMigration -Parameters @{ cfgPath = $script:cfgPath } {
            param($cfgPath)
            $ctx = New-MigContext -ConfigPath $cfgPath -Operator 'maker'
            try {
                Set-MigBatchInfo -Store $ctx.Store -BatchId '2019-04' -Data @{ state = 'verified' }
                $s = Invoke-MigStageBatching -Ctx $ctx
                ($s.batches | Where-Object { $_.batch_id -eq '2019-04' }).state | Should -Be 'verified'
                $info = Get-MigBatches -Store $ctx.Store
                $info['2019-04']['state'] | Should -Be 'verified'
                $info['2019-04']['plan']['file_count'] | Should -Be 1
                $info['2019-03']['state'] | Should -Be 'planned'
            } finally { Close-MigContext -Ctx $ctx }
        }
    }

    It 'streams plan totals using only the latest record per path (superseded records and tombstones)' {
        InModuleScope NotificationMigration -Parameters @{ root = $script:root } {
            param($root)
            $store = Initialize-MigStore -Path (Join-Path $root 'planstore')
            Write-MigManifest -Store $store -BatchId 'B1' -Side source -Records @(
                [ordered]@{ rel_path = 'b1\a.html'; kind = 'file'; size_bytes = 10 },
                [ordered]@{ rel_path = 'b1\b.html'; kind = 'file'; size_bytes = 0 },
                [ordered]@{ rel_path = 'b1\c.html'; kind = 'file'; size_bytes = 5 },
                [ordered]@{ rel_path = 'b1'; kind = 'dir' }
            )
            Write-MigManifest -Store $store -BatchId 'B1' -Side source -Records @(
                [ordered]@{ rel_path = 'B1\A.HTML'; kind = 'file'; size_bytes = 25 },                  # supersedes a (case-insensitive)
                [ordered]@{ rel_path = 'b1\c.html'; deleted = $true },                                 # tombstone
                [ordered]@{ rel_path = 'b1\locked.html'; kind = 'file'; size_bytes = $null; error = 'denied' },
                [ordered]@{ rel_path = 'b1\sub'; kind = 'error'; error = 'denied' }
            )
            $p = Get-MigBatchPlanTotals -Store $store -BatchId 'B1'
            $p.file_count | Should -Be 3
            $p.dir_count | Should -Be 1
            $p.total_bytes | Should -Be 25
            $p.zero_byte_count | Should -Be 1
            $p.error_count | Should -Be 2
            @($p.Keys) | Should -Be @('file_count', 'dir_count', 'total_bytes', 'zero_byte_count', 'error_count')
            $t = Get-MigBatchManifestTotals -Store $store -BatchId 'B1'
            $t.ok_file_count | Should -Be 2                 # a (25 bytes) and b (0 bytes); locked.html has an error
            $t.ok_bytes | Should -Be 25
            (Get-MigBatchPlanTotals -Store $store -BatchId 'EMPTY').file_count | Should -Be 0
        }
    }
}
