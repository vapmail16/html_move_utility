#Requires -Modules Pester
# Unit tests for Core/Gates.ps1 (+ Invoke-MigStageRun): maker-checker gates (C-08).
# Stages are simulated with dummy actions through Invoke-MigStageRun, so no real stage is needed.

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
    $script:mod = Get-Module NotificationMigration
    function M { param([scriptblock] $Block, [object[]] $A = @()) & $script:mod $Block @A }

    function New-ConfigFile {
        param([string] $Name, [hashtable] $Extra = @{})
        $root = Join-Path $TestDrive $Name
        $src = Join-Path $root 'src'; $tgt = Join-Path $root 'tgt'; $work = Join-Path $root 'work'
        foreach ($d in @($src, $tgt, $work)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $cfg = @{ paths = @{ sourceRoot = $src; targetRoot = $tgt; workDir = $work }; inventory = @{ aclReader = 'none' }; copy = @{ engine = 'dotnet' }; compare = @{ fileFields = @('exists', 'size', 'hash', 'created', 'modified', 'attributes'); dirFields = @('exists', 'modified') } }
        foreach ($k in $Extra.Keys) { $cfg[$k] = $Extra[$k] }
        $p = Join-Path $root 'c.json'
        [System.IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 10))
        return $p
    }
    function New-Ctx { param([string] $Path, [string] $Operator, [switch] $DryRun)
        M { param($p, $o, $d) New-MigContext -ConfigPath $p -Operator $o -DryRun:$d } @($Path, $Operator, [bool]$DryRun)
    }
    function Invoke-Stage { param($Ctx, [string] $Stage, [string] $BatchId, [switch] $Fail)
        M { param($c, $s, $b, $f)
            $action = { param($x) @{ ok = $true } }
            if ($f) { $action = { throw 'boom' } }
            Invoke-MigStageRun -Ctx $c -Stage $s -BatchId $b -Action $action -Parameters @{}
        } @($Ctx, $Stage, $BatchId, [bool]$Fail)
    }
    function Test-Ready { param($Ctx, [string] $Stage, [string] $BatchId) M { param($c, $s, $b) Test-MigStageReady -Ctx $c -Stage $s -BatchId $b } @($Ctx, $Stage, $BatchId) }
    function Approve { param($Ctx, [string] $Stage, [string] $BatchId, [string] $Decision = 'approved')
        M { param($c, $s, $b, $d) Set-MigGateDecision -Ctx $c -Stage $s -BatchId $b -Decision $d -Comment 'reviewed' } @($Ctx, $Stage, $BatchId, $Decision)
    }
}

Describe 'Maker-checker gates' {
    BeforeEach {
        $script:cfgPath = New-ConfigFile -Name ('g' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:maker = New-Ctx -Path $script:cfgPath -Operator 'DOM\maker'
        $script:checker = New-Ctx -Path $script:cfgPath -Operator 'DOM\checker'
    }
    AfterEach { foreach ($c in @($script:maker, $script:checker)) { M { param($c) Close-MigContext -Ctx $c } @($c) } }

    It 'the first stage has no prerequisite' {
        (Test-Ready $script:maker 'Inventory').ready | Should -BeTrue
    }
    It 'a stage is blocked until the previous stage has completed' {
        $r = Test-Ready $script:maker 'Batching'
        $r.ready | Should -BeFalse
        $r.reason | Should -Match "requires 'Inventory' completed"
        { Invoke-Stage $script:maker 'Batching' } | Should -Throw 'GATE:*'
    }
    It 'a failed run does not count as completed' {
        { Invoke-Stage $script:maker 'Inventory' -Fail } | Should -Throw '*boom*'
        (Test-Ready $script:maker 'Batching').reason | Should -Match 'failed; re-run it'
        (M { param($c) Get-MigLatestStageEvent -Store $c.Store -Stage Inventory -Scope global } @($script:maker))['state'] | Should -Be 'failed'
    }
    It 'a completed gated stage blocks the next one until a checker approves it' {
        $null = Invoke-Stage $script:maker 'Inventory'
        $r = Test-Ready $script:maker 'Batching'
        $r.ready | Should -BeFalse
        $r.reason | Should -Match 'not approved'
        $g = Approve $script:checker 'Inventory'
        $g.maker | Should -Be 'DOM\maker'
        $g.checker | Should -Be 'DOM\checker'
        (Test-Ready $script:maker 'Batching').ready | Should -BeTrue
    }
    It 'the maker cannot approve their own run' {
        $null = Invoke-Stage $script:maker 'Inventory'
        { Approve $script:maker 'Inventory' } | Should -Throw 'MAKER-CHECKER*'
        (Test-Ready $script:maker 'Batching').ready | Should -BeFalse
    }
    It 'a rejection keeps the next stage blocked' {
        $null = Invoke-Stage $script:maker 'Inventory'
        $null = Approve $script:checker 'Inventory' -Decision rejected
        (Test-Ready $script:maker 'Batching').ready | Should -BeFalse
    }
    It 'approval is tied to the run_id: a re-run needs a new approval' {
        $null = Invoke-Stage $script:maker 'Inventory'
        $null = Approve $script:checker 'Inventory'
        (Test-Ready $script:maker 'Batching').ready | Should -BeTrue
        $rerun = New-Ctx -Path $script:cfgPath -Operator 'DOM\maker'
        try {
            $null = Invoke-Stage $rerun 'Inventory'
            $r = Test-Ready $rerun 'Batching'
            $r.ready | Should -BeFalse
            $r.reason | Should -Match ([regex]::Escape($rerun.RunId))
            $null = Approve $script:checker 'Inventory'
            (Test-Ready $rerun 'Batching').ready | Should -BeTrue
        } finally { M { param($c) Close-MigContext -Ctx $c } @($rerun) }
    }
    It 'batch stages are gated per batch on the previous stage (global Batching, then per-batch chain)' {
        $null = Invoke-Stage $script:maker 'Inventory'; $null = Approve $script:checker 'Inventory'
        (Test-Ready $script:maker 'Copy' 'B1').reason | Should -Match "'Batching' completed for scope 'global'"
        $null = Invoke-Stage $script:maker 'Batching'; $null = Approve $script:checker 'Batching'
        (Test-Ready $script:maker 'Copy' 'B1').ready | Should -BeTrue
        $null = Invoke-Stage $script:maker 'Copy' 'B1'
        (Test-Ready $script:maker 'Verify' 'B1').ready | Should -BeFalse
        (Test-Ready $script:maker 'Verify' 'B2').reason | Should -Match "scope 'B2'"
        $null = Approve $script:checker 'Copy' 'B1'
        (Test-Ready $script:maker 'Verify' 'B1').ready | Should -BeTrue
        (Test-Ready $script:maker 'Verify' 'B2').ready | Should -BeFalse
    }
    It 'a batch Report follows the chain (HtmlChecks) while the global Report and Delta need an approved Inventory' {
        (Test-Ready $script:maker 'Report').ready | Should -BeFalse
        (Test-Ready $script:maker 'Delta').ready | Should -BeFalse
        $null = Invoke-Stage $script:maker 'Inventory'
        (Test-Ready $script:maker 'Report').reason | Should -Match "Gate 'Inventory'"
        $null = Approve $script:checker 'Inventory'
        (Test-Ready $script:maker 'Report').ready | Should -BeTrue
        (Test-Ready $script:maker 'Delta').ready | Should -BeTrue
        (Test-Ready $script:maker 'Report' 'B1').reason | Should -Match "'HtmlChecks'"
    }
    It 're-running an earlier stage invalidates later approvals (chain freshness)' {
        $null = Invoke-Stage $script:maker 'Inventory'; $null = Approve $script:checker 'Inventory'
        $null = Invoke-Stage $script:maker 'Batching'; $null = Approve $script:checker 'Batching'
        (Test-Ready $script:maker 'Copy' 'B1').ready | Should -BeTrue
        Start-Sleep -Milliseconds 20
        $null = Invoke-Stage $script:maker 'Inventory'; $null = Approve $script:checker 'Inventory'
        $r = Test-Ready $script:maker 'Copy' 'B1'
        $r.ready | Should -BeFalse
        $r.reason | Should -Match "re-run after 'Batching'"
    }
    It 'a Delta only invalidates the batches it changed (affected_batches)' {
        $null = Invoke-Stage $script:maker 'Inventory'; $null = Approve $script:checker 'Inventory'
        $null = Invoke-Stage $script:maker 'Batching'; $null = Approve $script:checker 'Batching'
        foreach ($b in @('B1', 'B2')) { $null = Invoke-Stage $script:maker 'Copy' $b; $null = Approve $script:checker 'Copy' $b }
        Start-Sleep -Milliseconds 20
        M { param($c) Invoke-MigStageRun -Ctx $c -Stage 'Delta' -Action { @{ affected_batches = @('B2'); new = 1 } } -Parameters @{} } @($script:maker) | Out-Null
        (Test-Ready $script:maker 'Verify' 'B1').ready | Should -BeTrue
        $r = Test-Ready $script:maker 'Verify' 'B2'
        $r.ready | Should -BeFalse
        $r.reason | Should -Match "changed batch 'B2'"
        (Test-Ready $script:maker 'Copy' 'B2').reason | Should -Match "'Delta'"
    }
    It 'a gate record without a matching audit-log entry is rejected (tampering)' {
        $null = Invoke-Stage $script:maker 'Inventory'
        M { param($c) Add-MigStoreRecord -Store $c.Store -Name 'gates.jsonl' -Record ([ordered]@{
                stage = 'Inventory'; scope = 'global'; run_id = (Get-MigLatestStageEvent -Store $c.Store -Stage Inventory -Scope global)['run_id']
                decision = 'approved'; checker = 'DOM\forger'; audit_ref = @{ log = 'run-x.jsonl'; seq = 1; hash = 'AA' } }) } @($script:maker)
        (Test-Ready $script:maker 'Batching').reason | Should -Match 'possible tampering'
    }
    It 'a run that did not pass cannot be approved without -Override and a justification' {
        $null = Invoke-Stage $script:maker 'Inventory'
        M { param($c) Add-MigStageEvent -Store $c.Store -Stage 'Reconcile' -Scope 'B1' -State completed -RunId 'rbad' -Operator 'DOM\maker' -Summary @{ passed = $false } } @($script:maker)
        { M { param($c) Set-MigGateDecision -Ctx $c -Stage Reconcile -BatchId B1 -Decision approved -Comment 'ok' } @($script:checker) } | Should -Throw '*did not pass*'
        { M { param($c) Set-MigGateDecision -Ctx $c -Stage Reconcile -BatchId B1 -Decision approved -Comment 'short' -Override } @($script:checker) } | Should -Throw '*justification*'
        $g = M { param($c) Set-MigGateDecision -Ctx $c -Stage Reconcile -BatchId B1 -Decision approved -Comment 'Accepted by data owner under ticket CHG-1234' -Override } @($script:checker)
        $g.override | Should -BeTrue
    }
    It 'batch-scoped stages need a batch id' {
        { M { Get-MigStageScope -Stage 'Copy' } } | Should -Throw '*needs a batch id*'
        M { Get-MigStageScope -Stage 'Inventory' -BatchId 'B1' } | Should -Be 'global'
    }
    It 'dry runs: never approvable, never satisfy a real run, but let a dry-run pipeline proceed' {
        $dry = New-Ctx -Path $script:cfgPath -Operator 'DOM\maker' -DryRun
        try {
            $null = Invoke-Stage $dry 'Inventory'
            { Approve $script:checker 'Inventory' } | Should -Throw '*dry run*'
            (Test-Ready $script:maker 'Batching').reason | Should -Match 'dry run'
            (Test-Ready $dry 'Batching').ready | Should -BeTrue
        } finally { M { param($c) Close-MigContext -Ctx $c } @($dry) }
    }
    It 'records stage started/completed events and a gate.decision audit event' {
        $null = Invoke-Stage $script:maker 'Inventory'
        $null = Approve $script:checker 'Inventory'
        $ev = @(M { param($c) Read-MigStoreRecords -Store $c.Store -Name 'stages.jsonl' } @($script:maker))
        @($ev | ForEach-Object { $_['state'] }) | Should -Be @('started', 'completed')
        $ev[1]['summary']['ok'] | Should -BeTrue
        (Get-Content -LiteralPath $script:checker.Audit.Path -Raw) | Should -Match '"event":"gate.decision"'
    }
}

Describe 'makerCheckerDistinctUsers = false' {
    It 'lets the operator approve their own run' {
        $p = New-ConfigFile -Name 'selfapprove' -Extra @{ pipeline = @{ makerCheckerDistinctUsers = $false } }
        $c = New-Ctx -Path $p -Operator 'solo'
        try {
            $null = Invoke-Stage $c 'Inventory'
            (Approve $c 'Inventory').decision | Should -Be 'approved'
            (Test-Ready $c 'Batching').ready | Should -BeTrue
        } finally { M { param($x) Close-MigContext -Ctx $x } @($c) }
    }
}
