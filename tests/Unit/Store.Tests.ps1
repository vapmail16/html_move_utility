#Requires -Modules Pester
# Unit tests for Core/Store.ps1: append-only JSONL, torn last line tolerated, latest record wins,
# case-insensitive keys, tombstones, file status, batch info, stage events, exception register, ISO timestamps.

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
    $script:mod = Get-Module NotificationMigration
    function M { param([scriptblock] $Block, [object[]] $A = @()) & $script:mod $Block @A }
    function New-Store { param([string] $Name) M { param($p) Initialize-MigStore -Path $p } @((Join-Path $TestDrive $Name)) }
}

Describe 'Initialize-MigStore / paths' {
    It 'creates the store and batches folders' {
        $s = New-Store 'init'
        Test-Path -LiteralPath (Join-Path $s.Root 'batches') | Should -BeTrue
    }
    It 'rejects unsafe batch ids and sanitises derived ones' {
        $s = New-Store 'ids'
        { M { param($s) Get-MigStorePath -Store $s -Name 'x.jsonl' -BatchId '..\evil' } @($s) } | Should -Throw '*Invalid batch id*'
        M { ConvertTo-MigSafeBatchId '2019/03 x' } | Should -Be '2019_03_x'
        M { ConvertTo-MigSafeBatchId '' } | Should -Be '_'
    }
}

Describe 'JSONL records' {
    It 'appends records and reads them back in order (Unicode safe)' {
        $s = New-Store 'append'
        M { param($s) Add-MigStoreRecords -Store $s -Name 'r.jsonl' -Records @(@{ n = 1; t = 'café 通知' }, @{ n = 2; t = 'b' }) } @($s)
        M { param($s) Add-MigStoreRecord -Store $s -Name 'r.jsonl' -Record @{ n = 3; t = 'c' } } @($s)
        $r = M { param($s) , @(Read-MigStoreRecords -Store $s -Name 'r.jsonl') } @($s)
        @($r | ForEach-Object { $_['n'] }) | Should -Be @(1, 2, 3)
        $r[0]['t'] | Should -Be 'café 通知'
    }
    It 'returns an empty array for a missing file and ignores blank lines' {
        $s = New-Store 'missing'
        @(M { param($s) Read-MigStoreRecords -Store $s -Name 'none.jsonl' } @($s)).Count | Should -Be 0
        [System.IO.File]::WriteAllText((Join-Path $s.Root 'b.jsonl'), "{`"a`":1}`n`n{`"a`":2}`n")
        @(M { param($s) Read-MigStoreRecords -Store $s -Name 'b.jsonl' } @($s)).Count | Should -Be 2
    }
    It 'tolerates a torn last line (crash mid-write): warns and keeps every complete record' {
        $s = New-Store 'torn'
        M { param($s) Add-MigStoreRecords -Store $s -Name 't.jsonl' -Records @(@{ k = 'a'; v = 1 }, @{ k = 'b'; v = 2 }) } @($s)
        [System.IO.File]::AppendAllText((Join-Path $s.Root 't.jsonl'), '{"k":"c","v":')
        $r = M { param($s) , @(Read-MigStoreRecords -Store $s -Name 't.jsonl' -WarningVariable w -WarningAction SilentlyContinue); } @($s)
        $r.Count | Should -Be 2
        @($r | Where-Object { $null -eq $_ -or $_ -isnot [System.Collections.IDictionary] }).Count | Should -Be 0
        @($r | ForEach-Object { $_['k'] }) | Should -Be @('a', 'b')
    }
    It 'returns timestamps as ISO-8601 strings (top level and nested), never DateTime' {
        $s = New-Store 'dates'
        $ts = '2024-03-05T06:07:08.1234567Z'
        M { param($s, $t) Add-MigStoreRecord -Store $s -Name 'd.jsonl' -Record ([ordered]@{ ts_utc = $t; nested = @{ when = $t }; list = @($t) }) } @($s, $ts)
        $r = @(M { param($s) Read-MigStoreRecords -Store $s -Name 'd.jsonl' } @($s))[0]
        $r['ts_utc'] | Should -BeOfType [string]
        $r['ts_utc'] | Should -Be $ts
        $r['nested']['when'] | Should -BeOfType [string]
        $r['nested']['when'] | Should -Be $ts
        @($r['list'])[0] | Should -Be $ts
        M { param($s) (Get-MigBatches -Store $s) } @($s) | Out-Null
    }
    It 'returns Get-MigUtcNow timestamps unchanged through batch info' {
        $s = New-Store 'dates2'
        M { param($s) Set-MigBatchInfo -Store $s -BatchId 'B1' -Data @{ state = 'planned' } } @($s)
        $b = M { param($s) (Get-MigBatches -Store $s)['B1'] } @($s)
        $b['ts_utc'] | Should -BeOfType [string]
        [DateTime]::Parse($b['ts_utc']) | Should -BeOfType [DateTime]
    }
}

Describe 'Manifest' {
    BeforeAll {
        $script:s = New-Store 'manifest'
        M { param($s)
            Write-MigManifest -Store $s -BatchId 'B1' -Side source -Records @(
                @{ rel_path = '2019\A.html'; kind = 'file'; size_bytes = 1; hash = 'H1' },
                @{ rel_path = '2019\b.html'; kind = 'file'; size_bytes = 5; hash = 'H5' },
                @{ rel_path = '2019\gone.html'; kind = 'file'; size_bytes = 9; hash = 'H9' })
            Write-MigManifest -Store $s -BatchId 'B1' -Side source -Records @(
                @{ rel_path = '2019\a.HTML'; kind = 'file'; size_bytes = 2; hash = 'H2' },
                @{ rel_path = '2019\gone.html'; kind = 'file'; deleted = $true })
        } @($script:s)
        $script:m = M { param($s) Read-MigManifest -Store $s -BatchId 'B1' -Side source } @($script:s)
    }
    It 'latest record per rel_path wins' { $script:m['2019\A.html']['hash'] | Should -Be 'H2' }
    It 'keys compare case-insensitively (NTFS semantics)' {
        $script:m.ContainsKey('2019\A.HTML') | Should -BeTrue
        $script:m.ContainsKey('2019\B.HTML') | Should -BeTrue
    }
    It 'drops tombstoned entries' {
        $script:m.ContainsKey('2019\gone.html') | Should -BeFalse
        $script:m.Count | Should -Be 2
    }
    It 'keeps sides and batches apart' {
        (M { param($s) Read-MigManifest -Store $s -BatchId 'B1' -Side target } @($script:s)).Count | Should -Be 0
        @(M { param($s) Get-MigBatchIds -Store $s } @($script:s)) | Should -Be @('B1')
    }
}

Describe 'File status' {
    It 'latest status wins, attempts count copied events, last error kept, case-insensitive' {
        $s = New-Store 'status'
        M { param($s)
            Add-MigFileStatus -Store $s -BatchId 'B1' -RunId 'r1' -Events @(@{ rel_path = 'a.html'; status = 'pending' })
            Add-MigFileStatus -Store $s -BatchId 'B1' -RunId 'r1' -Events @(@{ rel_path = 'a.html'; status = 'copied' }, @{ rel_path = 'A.HTML'; status = 'mismatch'; error = 'hash' })
            Add-MigFileStatus -Store $s -BatchId 'B1' -RunId 'r2' -Events @(@{ rel_path = 'a.html'; status = 'copied' }, @{ rel_path = 'a.html'; status = 'verified' })
        } @($s)
        $st = M { param($s) Get-MigFileStatus -Store $s -BatchId 'B1' } @($s)
        $st.Count | Should -Be 1
        $st['A.html'].status | Should -Be 'verified'
        $st['a.html'].attempts | Should -Be 2
        $st['a.html'].last_error | Should -Be 'hash'
    }
    It 'rejects an unknown status' {
        $s = New-Store 'status2'
        { M { param($s) Add-MigFileStatus -Store $s -BatchId 'B1' -Events @(@{ rel_path = 'a'; status = 'moved' }) } @($s) } | Should -Throw '*Invalid file status*'
    }
}

Describe 'Batch info, stage events, exceptions' {
    It 'merges batch info keys, later events overwrite' {
        $s = New-Store 'batch'
        M { param($s)
            Set-MigBatchInfo -Store $s -BatchId 'B2' -Data @{ state = 'planned'; plan = @{ file_count = 3 } }
            Set-MigBatchInfo -Store $s -BatchId 'B1' -Data @{ state = 'planned' }
            Set-MigBatchInfo -Store $s -BatchId 'B2' -Data @{ state = 'copied' }
        } @($s)
        $b = M { param($s) Get-MigBatches -Store $s } @($s)
        @($b.Keys) | Should -Be @('B1', 'B2')
        $b['B2']['state'] | Should -Be 'copied'
        $b['B2']['plan']['file_count'] | Should -Be 3
        $b.ContainsKey('b2') | Should -BeTrue
    }
    It 'returns the latest (optionally completed-only) stage event per scope' {
        $s = New-Store 'stages'
        M { param($s)
            Add-MigStageEvent -Store $s -Stage Copy -Scope B1 -State completed -RunId r1 -Operator op
            Add-MigStageEvent -Store $s -Stage Copy -Scope B1 -State started -RunId r2 -Operator op
            Add-MigStageEvent -Store $s -Stage Copy -Scope B2 -State failed -RunId r3 -Operator op
        } @($s)
        (M { param($s) Get-MigLatestStageEvent -Store $s -Stage Copy -Scope B1 } @($s))['run_id'] | Should -Be 'r2'
        (M { param($s) Get-MigLatestStageEvent -Store $s -Stage Copy -Scope B1 -CompletedOnly } @($s))['run_id'] | Should -Be 'r1'
        M { param($s) Get-MigLatestStageEvent -Store $s -Stage Copy -Scope B2 -CompletedOnly } @($s) | Should -BeNullOrEmpty
    }
    It 'exception register: latest state per id wins and filters work' {
        $s = New-Store 'ex'
        $ids = M { param($s)
            $a = Add-MigException -Store $s -BatchId 'B1' -RelPath 'a' -Category 'missing' -Detail 'd' -RunId 'r1'
            $b = Add-MigException -Store $s -BatchId 'B2' -RelPath 'b' -Category 'extra' -RunId 'r1'
            Update-MigException -Store $s -Id $a -Status resolved -Resolution 'recopied' -By 'checker'
            @($a, $b)
        } @($s)
        $all = @(M { param($s) Get-MigExceptions -Store $s } @($s))
        $all.Count | Should -Be 2
        $a = $all | Where-Object { $_['id'] -eq $ids[0] }
        $a['status'] | Should -Be 'resolved'
        $a['resolution'] | Should -Be 'recopied'
        $a['updated_by'] | Should -Be 'checker'
        @(M { param($s) Get-MigExceptions -Store $s -Status open } @($s)).Count | Should -Be 1
        @(M { param($s) Get-MigExceptions -Store $s -BatchId 'B1' } @($s)).Count | Should -Be 1
        { M { param($s) Update-MigException -Store $s -Id 'nope' -Status resolved } @($s) } | Should -Throw '*not found*'
    }
}
