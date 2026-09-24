#Requires -Modules Pester
# Unit tests for core hardening: crash-safe appends, strict mid-file corruption,
# compaction, bulk exceptions (no re-open), audit sealing of interrupted runs, audit references,
# scope locks, robocopy flag floor/allow-list, unknown config keys and config cross-checks.

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
    $script:mod = Get-Module NotificationMigration
    function M { param([scriptblock] $Block, [object[]] $A = @()) & $script:mod $Block @A }
    function New-Store { param([string] $Name) M { param($p) Initialize-MigStore -Path $p } @((Join-Path $TestDrive $Name)) }
    function New-ConfigFile {
        param([string] $Name, [hashtable] $Extra = @{})
        $root = Join-Path $TestDrive $Name
        $src = Join-Path $root 'src'; $tgt = Join-Path $root 'tgt'; $work = Join-Path $root 'work'
        foreach ($d in @($src, $tgt, $work)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $cfg = @{ paths = @{ sourceRoot = $src; targetRoot = $tgt; workDir = $work }; inventory = @{ aclReader = 'none' }
                  copy = @{ engine = 'dotnet' }; compare = @{ fileFields = @('exists', 'size', 'hash', 'modified'); dirFields = @('exists') } }
        foreach ($k in $Extra.Keys) { $cfg[$k] = $Extra[$k] }
        $p = Join-Path $root 'cfg.json'
        [System.IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 10))
        return $p
    }
}

Describe 'Store: crash safety' {
    It 'isolates a torn tail so the next append is not lost' {
        $s = New-Store 'torn'
        $p = Join-Path $s.Root 'x.jsonl'
        [System.IO.File]::WriteAllText($p, "{`"n`":1}`n{`"n`":2,`"t`":`"trunc")   # crash mid-write, no newline
        M { param($s) Add-MigStoreRecords -Store $s -Name 'x.jsonl' -Records @(@{ n = 3 }) } @($s)
        $r = @(M { param($s) Read-MigStoreRecords -Store $s -Name 'x.jsonl' } @($s) 3>$null)
        @($r | ForEach-Object { $_['n'] }) | Should -Be @(1, 3)
    }
    It 'refuses a damaged line in the middle of a file (evidence is never silently dropped)' {
        $s = New-Store 'damaged'
        [System.IO.File]::WriteAllText((Join-Path $s.Root 'y.jsonl'), "{`"n`":1}`nnot json at all}`n{`"n`":3}`n")
        { M { param($s) Read-MigStoreRecords -Store $s -Name 'y.jsonl' } @($s) } | Should -Throw '*not valid JSON*'
    }
    It 'reads while another handle has the file open for writing' {
        $s = New-Store 'shared'
        M { param($s) Add-MigStoreRecord -Store $s -Name 'z.jsonl' -Record @{ n = 1 } } @($s)
        $fs = [System.IO.File]::Open((Join-Path $s.Root 'z.jsonl'), 'Append', 'Write', 'Read')
        try { @(M { param($s) Read-MigStoreRecords -Store $s -Name 'z.jsonl' } @($s)).Count | Should -Be 1 }
        finally { $fs.Dispose() }
    }
    It 'streams large files in blocks' {
        $s = New-Store 'blocks'
        $recs = 1..2500 | ForEach-Object { @{ n = $_ } }
        M { param($s, $r) Add-MigStoreRecords -Store $s -Name 'big.jsonl' -Records $r } @($s, $recs)
        $sizes = New-Object System.Collections.Generic.List[int]
        M { param($s, $l) Invoke-MigStoreLineBlocks -Path (Join-Path $s.Root 'big.jsonl') -BlockLines 1000 -Action { param($b) $l.Add(@($b).Count) } } @($s, $sizes)
        ($sizes | Measure-Object -Sum).Sum | Should -Be 2500
        $sizes.Count | Should -BeGreaterThan 1
    }
}

Describe 'Store: compaction' {
    It 'keeps the latest record per key, sorted, and archives the old file with a checksum' {
        $s = New-Store 'compact'
        M { param($s) Add-MigStoreRecords -Store $s -Name 'm.jsonl' -BatchId 'B1' -Records @(
                @{ rel_path = 'b'; v = 1 }, @{ rel_path = 'a'; v = 1 }, @{ rel_path = 'B'; v = 2 }) } @($s)
        $r = M { param($s) Compress-MigStoreFile -Store $s -Name 'm.jsonl' -BatchId 'B1' -Key 'rel_path' } @($s)
        $r.before | Should -Be 3
        $r.after | Should -Be 2
        Test-Path -LiteralPath $r.archive | Should -BeTrue
        Test-Path -LiteralPath ($r.archive + '.sha256') | Should -BeTrue
        $after = @(M { param($s) Read-MigStoreRecords -Store $s -Name 'm.jsonl' -BatchId 'B1' } @($s))
        @($after | ForEach-Object { $_['rel_path'] }) | Should -Be @('a', 'B')
        ($after | Where-Object { $_['rel_path'] -eq 'B' })['v'] | Should -Be 2
    }
}

Describe 'Exception register: bulk and no re-open' {
    It 'opens in bulk, never duplicates, and never re-opens accepted or resolved items' {
        $s = New-Store 'exc'
        $items = @(@{ rel_path = 'a.html'; category = 'hash_mismatch'; detail = 'x' }, @{ rel_path = 'b.html'; category = 'missing'; detail = 'y' })
        $opened = @(M { param($s, $i) Add-MigExceptions -Store $s -BatchId 'B1' -Items $i -RunId 'r1' } @($s, $items))
        $opened.Count | Should -Be 2
        @(M { param($s, $i) Add-MigExceptions -Store $s -BatchId 'B1' -Items $i -RunId 'r2' } @($s, $items)).Count | Should -Be 0
        M { param($s, $id) Update-MigException -Store $s -Id $id -Status accepted -Resolution 'known difference' -By 'checker' } @($s, $opened[0]['id'])
        @(M { param($s, $i) Add-MigExceptions -Store $s -BatchId 'B1' -Items $i -RunId 'r3' } @($s, $items)).Count | Should -Be 0
        @(M { param($s) Get-MigExceptions -Store $s -BatchId 'B1' } @($s)).Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $s.Root 'batches/B1/exceptions.jsonl') | Should -BeTrue
    }
}

Describe 'Audit: interrupted runs and references' {
    It 'seals a log left open by a killed run, and the sealed log verifies' {
        $cfg = New-ConfigFile 'seal'
        $dead = M { param($p) New-MigContext -ConfigPath $p -Operator 'DOM\maker' } @($cfg)
        M { param($c) Write-MigAudit -Audit $c.Audit -Event 'stage.started' -Data @{ stage = 'Copy' } } @($dead)
        $deadLog = $dead.Audit.Path
        $dead.Audit.Lock.Dispose()                     # simulate the process dying: lock released, no close
        $live = M { param($p) New-MigContext -ConfigPath $p -Operator 'DOM\maker' } @($cfg)
        try {
            Test-Path -LiteralPath ($deadLog + '.sha256') | Should -BeTrue
            (M { param($p) Test-MigAuditChain -Path $p } @($deadLog)).valid | Should -BeTrue
            (Get-Content -LiteralPath $deadLog -Raw) | Should -Match 'audit.sealed_after_interruption'
            (Get-Content -LiteralPath $live.Audit.Path -Raw) | Should -Match 'audit.orphan_sealed'
        } finally { M { param($c) Close-MigContext -Ctx $c } @($live) }
    }
    It 'does not seal the log of a run that is still alive' {
        $cfg = New-ConfigFile 'alive'
        $a = M { param($p) New-MigContext -ConfigPath $p -Operator 'DOM\maker' } @($cfg)
        $b = M { param($p) New-MigContext -ConfigPath $p -Operator 'DOM\maker' } @($cfg)
        try { Test-Path -LiteralPath ($a.Audit.Path + '.sha256') | Should -BeFalse }
        finally { M { param($c) Close-MigContext -Ctx $c } @($b); M { param($c) Close-MigContext -Ctx $c } @($a) }
    }
    It 'proves a store record against the audit log and rejects forged references' {
        $cfg = New-ConfigFile 'ref'
        $c = M { param($p) New-MigContext -ConfigPath $p -Operator 'DOM\maker' } @($cfg)
        try {
            M { param($c) Write-MigAudit -Audit $c.Audit -Event 'gate.decision' -Data @{ x = 1 } } @($c)
            $ref = $c.Audit.LastRef
            $dir = $c.Config._resolved.logDir
            M { param($d, $r) Test-MigAuditReference -LogDir $d -Ref $r -Event 'gate.decision' } @($dir, $ref) | Should -BeTrue
            M { param($d, $r) Test-MigAuditReference -LogDir $d -Ref $r -Event 'stage.completed' } @($dir, $ref) | Should -BeFalse
            $forged = @{ log = $ref.log; seq = $ref.seq; hash = ('A' * 64) }
            M { param($d, $r) Test-MigAuditReference -LogDir $d -Ref $r -Event 'gate.decision' } @($dir, $forged) | Should -BeFalse
        } finally { M { param($c) Close-MigContext -Ctx $c } @($c) }
    }
}

Describe 'Scope locks' {
    It 'a second process cannot run a stage on a locked scope' {
        $cfg = New-ConfigFile 'lock'
        $c = M { param($p) New-MigContext -ConfigPath $p -Operator 'DOM\maker' } @($cfg)
        try {
            $held = M { param($c) Lock-MigScope -Ctx $c -Scope 'B1' } @($c)
            try {
                $path = Join-Path $c.Store.Root 'locks/B1.lock'
                { [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None').Dispose() } | Should -Throw
            } finally { M { param($l) Unlock-MigScope -Lock $l } @($held) }
            { [System.IO.File]::Open((Join-Path $c.Store.Root 'locks/B1.lock'), 'Open', 'ReadWrite', 'None').Dispose() } | Should -Not -Throw
        } finally { M { param($c) Close-MigContext -Ctx $c } @($c) }
    }
}

Describe 'Robocopy flag safety' {
    It 'always forbids <flag> even when config does not list it' -ForEach @(
        @{ flag = '/MIR' }, @{ flag = '/JOB:evil.rcj' }, @{ flag = '/S' }, @{ flag = '/E' }, @{ flag = '/LEV:2' }, @{ flag = '/SAVE:x' }, @{ flag = '/purge' }) {
        { M { param($f) Assert-MigCopyFlagsSafe -Flags @($f) -ForbiddenFlags @() } @($flag) } | Should -Throw '*forbidden*'
    }
    It 'rejects a flag entry that hides a second flag behind whitespace' {
        { M { Assert-MigCopyFlagsSafe -Flags @('/E /PURGE') -ForbiddenFlags @() } } | Should -Throw '*whitespace*'
        { M { Assert-MigCopyFlagsSafe -Flags @(' /MIR') -ForbiddenFlags @() } } | Should -Throw '*forbidden*'
    }
    It 'ignores non-flag arguments such as paths and file names' {
        { M { Assert-MigCopyFlagsSafe -Flags @('C:\src dir', 'a file.html', '/COPY:DATSO') -ForbiddenFlags @() } } | Should -Not -Throw
    }
    It 'rejects configured flags outside the allow-list' {
        { M { Assert-MigCopyFlagsAllowed -Flags @('/COPY:DATSO', '/MT:8') -AllowedFlags @('/COPY') } } | Should -Throw '*allowedFlags*'
        { M { Assert-MigCopyFlagsAllowed -Flags @('/COPY:DATSO', '/R:3') -AllowedFlags @('/COPY', '/R') } } | Should -Not -Throw
    }
}

Describe 'Config: unknown keys and cross-checks' {
    It 'rejects a misspelled key instead of silently ignoring it' {
        $p = New-ConfigFile 'typo' @{ copy = @{ engine = 'dotnet'; maxRetrys = 5 } }
        { M { param($p) Get-MigrationConfig -Path $p } @($p) } | Should -Throw '*copy.maxRetrys*'
    }
    It 'accepts provider-specific batching options' {
        $p = New-ConfigFile 'opts' @{ batching = @{ strategy = 'regex'; options = @{ pattern = '^(?<y>\d{4})'; template = '{y}'; parentDirBatchId = 'ROOT' } } }
        { M { param($p) Get-MigrationConfig -Path $p } @($p) } | Should -Not -Throw
    }
    It 'rejects comparing ACLs while not reading them' {
        $p = New-ConfigFile 'acl' @{ compare = @{ fileFields = @('exists', 'size', 'hash', 'acl') } }
        { M { param($p) Get-MigrationConfig -Path $p } @($p) } | Should -Throw "*aclReader is 'none'*"
    }
    It 'rejects dropping the hash from the compared fields' {
        $p = New-ConfigFile 'nohash' @{ compare = @{ fileFields = @('exists', 'size') } }
        { M { param($p) Get-MigrationConfig -Path $p } @($p) } | Should -Throw "*must include 'hash'*"
    }
    It 'rejects includeOwner without an owner-copying robocopy flag' {
        $p = New-ConfigFile 'owner' @{ inventory = @{ aclReader = 'windows' }; copy = @{ engine = 'robocopy'; robocopy = @{ flags = @('/COPY:DATS', '/R:1') } }
                                       compare = @{ fileFields = @('exists', 'size', 'hash', 'acl') } }
        { M { param($p) Get-MigrationConfig -Path $p } @($p) } | Should -Throw '*do not copy the owner*'
    }
    It 'rejects a copy-capable stage in pipeline.dryRunStages' {
        $p = New-ConfigFile 'dry' @{ pipeline = @{ dryRunStages = @('Inventory', 'Copy') } }
        { M { param($p) Get-MigrationConfig -Path $p } @($p) } | Should -Throw "*dryRunStages*'Copy'*"
    }
}
