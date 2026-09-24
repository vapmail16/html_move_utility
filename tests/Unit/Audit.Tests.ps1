#Requires -Modules Pester
# Unit tests for Core/Audit.ps1: hash-chained append-only log, checksum sidecar, tamper detection (C-07).

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
    $script:mod = Get-Module NotificationMigration
    function M { param([scriptblock] $Block, [object[]] $A = @()) & $script:mod $Block @A }

    function New-Log {
        param([string] $Name, [int] $Lines = 4, [switch] $NoClose, [string] $Algorithm = 'SHA256', [bool] $HashChain = $true)
        $dir = Join-Path $TestDrive $Name
        M { param($d, $n, $noClose, $alg, $chain)
            $a = New-MigAuditLog -LogDir $d -RunId 'run1' -Algorithm $alg -HashChain $chain
            for ($i = 1; $i -le $n; $i++) { Write-MigAudit -Audit $a -Event "evt.$i" -Data ([ordered]@{ i = $i; path = "2019\café $i.html" }) -Operator 'maker' }
            if (-not $noClose) { Close-MigAuditLog -Audit $a }
            $a
        } @($dir, $Lines, [bool]$NoClose, $Algorithm, $HashChain)
    }
    function Test-Chain { param([string] $Path) M { param($p) Test-MigAuditChain -Path $p } @($Path) }
    function Get-Lines { param([string] $Path) [System.IO.File]::ReadAllLines($Path) }
    function Set-Lines { param([string] $Path, [string[]] $Lines) [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false))) }
}

Describe 'Audit log' {
    It 'writes one JSON line per event with seq, UTC ts, operator, prev_hash and hash' {
        $a = New-Log -Name 'fmt' -Lines 2
        $lines = Get-Lines $a.Path
        $lines.Count | Should -Be 3   # 2 events + audit.closed
        $first = $lines[0] | ConvertFrom-Json
        $first.seq | Should -Be 1
        $first.operator | Should -Be 'maker'
        $first.prev_hash | Should -Be ('0' * 64)
        $first.hash | Should -Match '^[0-9A-F]{64}$'
        ($lines[1] | ConvertFrom-Json).prev_hash | Should -Be $first.hash
        ($lines[2] | ConvertFrom-Json).event | Should -Be 'audit.closed'
        $lines[0] | Should -Match '"ts_utc":"\d{4}-\d\d-\d\dT[^"]+Z"'
        (Split-Path $a.Path -Leaf) | Should -Match '^run-\d{8}T\d{6}Z-run1\.jsonl$'
    }
    It 'refuses writes after close and writes a checksum sidecar' {
        $a = New-Log -Name 'closed'
        { M { param($a) Write-MigAudit -Audit $a -Event 'late' -Data @{} } @($a) } | Should -Throw '*closed*'
        $side = $a.Path + '.sha256'
        Test-Path -LiteralPath $side | Should -BeTrue
        ((Get-Content -LiteralPath $side -Raw).Trim() -split '\s+')[0] | Should -Be (Get-FileHash -LiteralPath $a.Path -Algorithm SHA256).Hash
    }
    It 'validates an intact chain (closed and still-open logs)' {
        $a = New-Log -Name 'valid' -Lines 5
        $r = Test-Chain $a.Path
        $r.valid | Should -BeTrue
        $r.chained | Should -BeTrue
        $r.lines | Should -Be 6
        (Test-Chain (New-Log -Name 'open' -NoClose).Path).valid | Should -BeTrue
    }
    It 'detects an edited line' {
        $a = New-Log -Name 'edit' -NoClose
        $l = Get-Lines $a.Path
        $l[1] = $l[1].Replace('"evt.2"', '"evt.X"')
        Set-Lines $a.Path $l
        $r = Test-Chain $a.Path
        $r.valid | Should -BeFalse
        $r.error | Should -Match 'line 2: hash mismatch'
    }
    It 'detects an edited line even when its hash is recomputed (breaks the next link)' {
        $a = New-Log -Name 'rehash' -NoClose
        $l = Get-Lines $a.Path
        $m = [regex]::Match($l[1], ',"hash":"([0-9A-F]+)"\}$')
        $body = $l[1].Substring(0, $m.Index).Replace('"maker"', '"mallory"') + '}'
        $prev = ($l[0] | ConvertFrom-Json).hash
        $h = M { param($t) Get-MigStringHash -Text $t } @($prev + $body)
        $l[1] = $body.Substring(0, $body.Length - 1) + ',"hash":"' + $h + '"}'
        Set-Lines $a.Path $l
        $r = Test-Chain $a.Path
        $r.valid | Should -BeFalse
        $r.error | Should -Match 'line 3: prev_hash'
    }
    It 'detects a deleted line' {
        $a = New-Log -Name 'del' -NoClose
        $l = @(Get-Lines $a.Path)
        Set-Lines $a.Path (@($l[0]) + @($l[2..($l.Count - 1)]))
        $r = Test-Chain $a.Path
        $r.valid | Should -BeFalse
        $r.error | Should -Match 'prev_hash does not link'
    }
    It 'detects reordered lines' {
        $a = New-Log -Name 'reorder' -NoClose
        $l = @(Get-Lines $a.Path)
        Set-Lines $a.Path (@($l[1], $l[0]) + @($l[2..($l.Count - 1)]))
        (Test-Chain $a.Path).valid | Should -BeFalse
    }
    It 'detects truncation of the last line of a closed log via the sidecar' {
        $a = New-Log -Name 'trunc'
        $l = @(Get-Lines $a.Path)
        Set-Lines $a.Path $l[0..($l.Count - 2)]
        $r = Test-Chain $a.Path
        $r.valid | Should -BeFalse
        $r.error | Should -Match 'sidecar'
    }
    It 'detects a sidecar mismatch' {
        $a = New-Log -Name 'sidecar'
        [System.IO.File]::WriteAllText($a.Path + '.sha256', ('0' * 64) + '  x.jsonl' + "`n")
        $r = Test-Chain $a.Path
        $r.valid | Should -BeFalse
        $r.error | Should -Match 'sidecar'
    }
    It 'uses the algorithm of the sidecar (SHA384)' {
        $a = New-Log -Name 'sha384' -Algorithm 'SHA384'
        Test-Path -LiteralPath ($a.Path + '.sha384') | Should -BeTrue
        (Test-Chain $a.Path).valid | Should -BeTrue
    }
    It 'unchained log: valid only with a matching sidecar' {
        $a = New-Log -Name 'nochain' -HashChain $false
        $r = Test-Chain $a.Path
        $r.valid | Should -BeTrue
        $r.chained | Should -BeFalse
        $l = @(Get-Lines $a.Path); $l[0] = $l[0].Replace('maker', 'makr'); Set-Lines $a.Path $l
        (Test-Chain $a.Path).valid | Should -BeFalse
        $b = New-Log -Name 'nochainopen' -HashChain $false -NoClose
        (Test-Chain $b.Path).valid | Should -BeFalse
    }
    It 'context lifecycle: run.started first, audit.closed last, chain valid' {
        $root = Join-Path $TestDrive 'ctx'
        $src = Join-Path $root 'src'; $tgt = Join-Path $root 'tgt'; $work = Join-Path $root 'work'
        foreach ($d in @($src, $tgt, $work)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $p = Join-Path $root 'c.json'
        [System.IO.File]::WriteAllText($p, (@{ paths = @{ sourceRoot = $src; targetRoot = $tgt; workDir = $work }; inventory = @{ aclReader = 'none' }; compare = @{ fileFields = @('exists', 'size', 'hash', 'created', 'modified', 'attributes'); dirFields = @('exists', 'modified') } } | ConvertTo-Json -Depth 5))
        $ctx = M { param($x) New-MigContext -ConfigPath $x -Operator 'op1' } @($p)
        M { param($c) Close-MigContext -Ctx $c } @($ctx)
        $l = @(Get-Lines $ctx.Audit.Path)
        ($l[0] | ConvertFrom-Json).event | Should -Be 'run.started'
        ($l[0] | ConvertFrom-Json).data.config_hash | Should -Match '^[0-9A-F]{64}$'
        ($l[-1] | ConvertFrom-Json).event | Should -Be 'audit.closed'
        (Test-Chain $ctx.Audit.Path).valid | Should -BeTrue
        (Test-MigrationAuditLog -Path (Split-Path $ctx.Audit.Path)).Valid | Should -Be $true
    }
}
