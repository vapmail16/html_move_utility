# End-to-end: synthetic dataset -> every stage through the PUBLIC commands, with maker-checker approvals,
# fault injection on the target, exception handling, final report and audit-log verification.
# Runs on any OS with copy.engine 'dotnet' and aclReader 'none'. On Windows the maker/checker identity is the
# real logged-on account, so the distinct-user parts are skipped there (use two accounts in a real pilot).

BeforeDiscovery {
    $script:OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or [bool]$IsWindows
}

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot/../..").ProviderPath
    Import-Module "$repo/NotificationMigration/NotificationMigration.psd1" -Force -DisableNameChecking
    $script:Src = Join-Path $TestDrive 'source'
    $script:Tgt = Join-Path $TestDrive 'target'
    $script:Work = Join-Path $TestDrive 'work'
    $script:Dataset = & "$repo/tools/New-SyntheticDataset.ps1" -Path $script:Src -Years 2019 -MonthsPerYear 2 -FilesPerMonth 4 -LargeFileMB 1 -Seed 7 -WarningAction SilentlyContinue

    $cfg = [ordered]@{
        paths      = @{ sourceRoot = $script:Src; targetRoot = $script:Tgt; workDir = $script:Work }
        pipeline   = @{ makerCheckerDistinctUsers = $true }
        inventory  = @{ threads = 4; chunkSize = 25; aclReader = 'none' }
        copy       = @{ engine = 'dotnet'; maxRetries = 2 }
        compare    = @{ fileFields = @('exists', 'size', 'hash', 'created', 'modified', 'attributes'); dirFields = @('exists') }
        htmlChecks = @{ rules = @{ absoluteLinks = @{ enabled = $true; oldHosts = @('OLDSERVER01'); oldUncPrefixes = @(); oldIpAddresses = @() } } }
        report     = @{ formats = @('csv', 'html', 'json') }
    }
    $script:Config = Join-Path $TestDrive 'migration.config.json'
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:Config -Encoding UTF8

    function script:As([string] $who, [scriptblock] $action) {
        $old = $env:USERDOMAIN
        $env:USERDOMAIN = $who
        try { & $action } finally { $env:USERDOMAIN = $old }
    }
    function script:SourceHashes {
        Get-ChildItem -LiteralPath $script:Src -Recurse -File | Sort-Object FullName | ForEach-Object {
            $_.FullName.Substring($script:Src.Length) + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash + '|' + $_.LastWriteTimeUtc.Ticks
        }
    }
    function script:Run([string] $stage, [string] $batch) {
        $p = @{ Stage = $stage; Config = $script:Config; WarningAction = 'SilentlyContinue' }
        if ($batch) { $p.Batch = $batch }
        if ($stage -eq 'Report' -and -not $batch) { $p.Final = $true }
        As 'MAKER' { Migrate-Notifications @p }
    }
    function script:Approve([string] $stage, [string] $batch) {
        $p = @{ Stage = $stage; Config = $script:Config; Comment = 'reviewed' }
        if ($batch) { $p.Batch = $batch }
        As 'CHECKER' { Approve-MigrationGate @p }
    }
    $script:SourceBefore = SourceHashes
}

Describe 'End-to-end migration' -Skip:$script:OnWindows {

    It 'dry run inventories and plans without touching the target' {
        $r = As 'MAKER' { Migrate-Notifications -Stage All -DryRun -Config $script:Config -WarningAction SilentlyContinue }
        $r.Contains('Inventory') | Should -BeTrue
        $r.Contains('Batching') | Should -BeTrue
        $r.Contains('Copy') | Should -BeFalse
        Test-Path -LiteralPath $script:Tgt | Should -BeFalse
    }

    It 'blocks Copy until Batching is completed and approved' {
        (Run 'Inventory').ran.Count | Should -Be 1
        { Run 'Batching' } | Should -Throw '*not approved*'
        Approve 'Inventory'
        (Run 'Batching').ran.Count | Should -Be 1
        $r = Run 'Copy' '2019-01'
        $r.failed.Count | Should -Be 1
        $r.failed[0].error | Should -BeLike '*Gate*Batching*'
    }

    It 'refuses to let the maker approve their own run' {
        { As 'MAKER' { Approve-MigrationGate -Stage Batching -Config $script:Config -Comment 'self' } } | Should -Throw '*MAKER-CHECKER*'
        Approve 'Batching'
    }

    It 'copies, verifies, reconciles and HTML-checks every batch with full parity' {
        $batches = @((Get-MigrationStatus -Config $script:Config | Where-Object Scope -ne 'global').Scope)
        $batches.Count | Should -BeGreaterThan 1
        foreach ($b in $batches) {
            (Run 'Copy' $b).failed.Count | Should -Be 0 -Because "copy $b"
            Approve 'Copy' $b
            (Run 'Verify' $b).failed.Count | Should -Be 0
            Approve 'Verify' $b
            $rec = Run 'Reconcile' $b
            $rec.ran[0].summary.passed | Should -BeTrue -Because "reconcile $b"
            Approve 'Reconcile' $b
            $html = Run 'HtmlChecks' $b
            $html.ran[0].summary.parity | Should -BeTrue -Because "html parity $b"
            Approve 'HtmlChecks' $b
            (Run 'Report' $b).ran[0].summary.files.Count | Should -BeGreaterThan 0
        }
    }

    It 'detects and auto-repairs a corrupted target file' {
        $pick = $script:Dataset.Files | Where-Object { $_.rel_path -like '2019\02\*.html' -and $_.bytes -gt 0 -and @($_.tags).Count -le 1 } | Select-Object -First 1
        $pick | Should -Not -BeNullOrEmpty
        $batch = '2019-02'
        [void](& "$PSScriptRoot/../../tools/Invoke-FaultInjection.ps1" -TargetRoot $script:Tgt -SourceRoot $script:Src -Fault Corrupt -RelPath $pick.rel_path)
        (Run 'Verify' $batch).failed.Count | Should -Be 0
        Approve 'Verify' $batch
        $rec = (Run 'Reconcile' $batch).ran[0].summary
        $rec.retried | Should -BeGreaterThan 0
        $rec.passed | Should -BeTrue
    }

    It 'never deletes an extra target file: it becomes an exception a person must close' {
        $f = & "$PSScriptRoot/../../tools/Invoke-FaultInjection.ps1" -TargetRoot $script:Tgt -SourceRoot $script:Src -Fault Extra -RelPath '2019\01\zz-extra.html'
        (Run 'Verify' '2019-01').failed.Count | Should -Be 0
        Approve 'Verify' '2019-01'
        (Run 'Reconcile' '2019-01').ran[0].summary.passed | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Tgt '2019/01/zz-extra.html') | Should -BeTrue
        $ex = @(Get-MigrationException -Config $script:Config -Batch '2019-01' -Status open)
        $ex.Count | Should -BeGreaterThan 0
        foreach ($e in $ex) { As 'CHECKER' { Set-MigrationException -Config $script:Config -Id $e.id -Status accepted -Resolution 'Test artefact; approved to remain' -Owner 'CHECKER' } }
        @(Get-MigrationException -Config $script:Config -Status open | Where-Object batch_id -eq '2019-01').Count | Should -Be 0
    }

    It 'a Reconcile that did not pass cannot be approved without an override' {
        { Approve 'Reconcile' '2019-01' } | Should -Throw '*did not pass*'
    }

    It 'after the exception is accepted, re-reconciling passes and the batch chain completes again' {
        $rec = Run 'Reconcile' '2019-01'
        $rec.ran[0].summary.passed | Should -BeTrue
        Approve 'Reconcile' '2019-01'
        (Run 'HtmlChecks' '2019-01').ran[0].summary.parity | Should -BeTrue
        Approve 'HtmlChecks' '2019-01'
        (Run 'Report' '2019-01').ran[0].summary.passed | Should -BeTrue
    }

    It 'Delta (freeze) picks up a late source file and only the changed batch must re-run' {
        [System.IO.File]::WriteAllText((Join-Path $script:Src '2019/02/late-notification.html'), '<html><body>late</body></html>')
        $script:SourceBefore = SourceHashes                                  # the late file is a legitimate source change
        $d = (Run 'Delta').ran[0].summary
        Approve 'Delta'
        @($d.affected_batches) | Should -Contain '2019-02'
        @($d.affected_batches) | Should -Not -Contain '2019-01'
        (Run 'Copy' '2019-02').failed[0].error | Should -BeLike "*Delta*"
        (Run 'Batching').ran.Count | Should -Be 1
        Approve 'Batching'
        foreach ($st in @('Copy', 'Verify', 'Reconcile', 'HtmlChecks')) {
            $r = Run $st '2019-02'
            $r.failed.Count | Should -Be 0 -Because "$st 2019-02"
            Approve $st '2019-02'
        }
        Test-Path -LiteralPath (Join-Path $script:Tgt '2019/02/late-notification.html') | Should -BeTrue
    }

    It 'the final report passes every acceptance criterion' {
        $r = Run 'Report'
        $sum = $r.ran[0].summary
        $sum.final | Should -BeTrue
        $accCsv = @($sum.files) | Where-Object { $_ -like '*acceptance.csv' } | Select-Object -First 1
        $details = @{}
        if ($accCsv) { Import-Csv -LiteralPath $accCsv | ForEach-Object { $details[$_.id] = $_.detail } }
        foreach ($k in @($sum.acceptance.Keys)) { $sum.acceptance[$k] | Should -BeTrue -Because "acceptance $k ($($details[$k]))" }
        $sum.passed | Should -BeTrue
        $files = @($sum.files)
        ($files | Where-Object { $_ -like '*.html' }).Count | Should -BeGreaterThan 0
        foreach ($f in $files) { Test-Path -LiteralPath $f | Should -BeTrue }
    }

    It 'exports each batch manifest as CSV with a checksum sidecar (C-01)' {
        $ex = @(As 'MAKER' { Export-MigrationManifest -Config $script:Config })
        $ex.Count | Should -BeGreaterThan 1
        foreach ($e in $ex) {
            Test-Path -LiteralPath $e.path | Should -BeTrue
            $want = ((Get-Content -LiteralPath $e.checksum_path -Raw).Trim() -split '\s+')[0]
            (Get-FileHash -LiteralPath $e.path -Algorithm SHA256).Hash | Should -Be $want
        }
    }

    It 'three-party sign-off needs three different people, and a maker cannot sign as control owner' {
        { As 'MAKER' { Approve-MigrationSignOff -Config $script:Config -Role ControlOwner -Comment 'x' } } | Should -Throw '*cannot sign as Control owner*'
        $null = As 'SRCOWNER' { Approve-MigrationSignOff -Config $script:Config -Role SourceOwner -Comment 'source verified' }
        { As 'SRCOWNER' { Approve-MigrationSignOff -Config $script:Config -Role TargetOwner -Comment 'x' } } | Should -Throw '*three different people*'
        $null = As 'TGTOWNER' { Approve-MigrationSignOff -Config $script:Config -Role TargetOwner -Comment 'target verified' }
        $null = As 'CHECKER' { Approve-MigrationSignOff -Config $script:Config -Role ControlOwner -Comment 'controls evidenced' }
        { As 'OTHER' { Approve-MigrationSignOff -Config $script:Config -Role SourceOwner -Comment 'again' } } | Should -Throw '*already signed*'
        $null = As 'OTHER' { Register-MigrationRetention -Config $script:Config -Ticket 'CHG-42' -RetainUntil (Get-Date).AddDays(90) }
    }

    It 'keeps every audit log intact (hash chain + checksum)' {
        $logs = @(Test-MigrationAuditLog -Path (Join-Path $script:Work 'logs'))
        $logs.Count | Should -BeGreaterThan 5
        @($logs | Where-Object { -not $_.Valid }).Count | Should -Be 0
    }

    It 'never modified the source' {
        SourceHashes | Should -Be $script:SourceBefore
    }
}
