# Test plan row "Kill mid-copy, then resume": a Copy running in a separate process is killed partway,
# then the pipeline resumes. Proves: idempotent restart (no false pass, nothing lost), the interrupted run's
# audit log is sealed by the next run and still verifies, and the scope lock died with the process.

BeforeDiscovery {
    $script:OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or [bool]$IsWindows
}

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot/../..").ProviderPath
    Import-Module "$script:Repo/NotificationMigration/NotificationMigration.psd1" -Force -DisableNameChecking
    $script:Src = Join-Path $TestDrive 'source'
    $script:Tgt = Join-Path $TestDrive 'target'
    $script:Work = Join-Path $TestDrive 'work'
    # Enough files that a copy takes a few seconds: 40 day folders x 150 files (~6000 files).
    foreach ($d in 1..40) {
        $dir = Join-Path $script:Src ('2019/05/{0:D2}' -f (($d % 28) + 1)) | Join-Path -ChildPath "part$d"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($f in 1..150) { [System.IO.File]::WriteAllText((Join-Path $dir "n$f.html"), "<html><body>notification $d/$f $('x' * 2000)</body></html>") }
    }
    $cfg = [ordered]@{
        paths     = @{ sourceRoot = $script:Src; targetRoot = $script:Tgt; workDir = $script:Work }
        pipeline  = @{ makerCheckerDistinctUsers = $false }
        inventory = @{ threads = 4; aclReader = 'none' }
        copy      = @{ engine = 'dotnet'; maxRetries = 2; chunkSize = 200 }
        compare   = @{ fileFields = @('exists', 'size', 'hash', 'modified'); dirFields = @('exists') }
    }
    $script:Config = Join-Path $TestDrive 'migration.config.json'
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:Config -Encoding UTF8
    function script:Step([string] $stage, [string] $batch) {
        $p = @{ Stage = $stage; Config = $script:Config; WarningAction = 'SilentlyContinue' }
        if ($batch) { $p.Batch = $batch }
        $r = Migrate-Notifications @p
        $a = @{ Stage = $stage; Config = $script:Config; Comment = 'reviewed' }
        if ($batch) { $a.Batch = $batch }
        $null = Approve-MigrationGate @a
        return $r
    }
    $script:Pwsh = (Get-Process -Id $PID).Path
}

Describe 'Kill mid-copy, then resume' -Skip:$script:OnWindows {

    It 'prepares inventory and batching' {
        $null = Step 'Inventory'
        $null = Step 'Batching'
        @((Get-MigrationStatus -Config $script:Config | Where-Object Scope -eq '2019-05')).Count | Should -Be 1
    }

    It 'kills a running Copy partway through' {
        $cmd = "Import-Module '$script:Repo/NotificationMigration/NotificationMigration.psd1' -DisableNameChecking; " +
               "Migrate-Notifications -Stage Copy -Batch 2019-05 -Config '$script:Config' -WarningAction SilentlyContinue | Out-Null"
        $p = Start-Process -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', $cmd) -PassThru
        $deadline = (Get-Date).AddSeconds(60)
        # Wait until some (but not all) files have been copied, then kill hard.
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
            $n = @(Get-ChildItem -LiteralPath $script:Tgt -Recurse -File -ErrorAction SilentlyContinue).Count
            if ($n -ge 300) { break }
            if ($p.HasExited) { break }
        }
        $wasRunning = -not $p.HasExited
        if ($wasRunning) { Stop-Process -Id $p.Id -Force; $p.WaitForExit() }
        if (-not $wasRunning) { Set-ItResult -Inconclusive -Because 'copy finished before it could be killed (machine too fast); increase the dataset'; return }
        $copied = @(Get-ChildItem -LiteralPath $script:Tgt -Recurse -File).Count
        $copied | Should -BeLessThan 6000
    }

    It 'the next run seals the killed run''s audit log, and every log verifies' {
        $status = Get-MigrationStatus -Config $script:Config        # any command starts a context -> seals orphans
        $logs = @(Test-MigrationAuditLog -Path (Join-Path $script:Work 'logs'))
        @($logs | Where-Object { -not $_.Valid }).Count | Should -Be 0
        $sealed = @(Get-ChildItem -LiteralPath (Join-Path $script:Work 'logs') -Filter 'run-*.jsonl' |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'audit.sealed_after_interruption' })
        # Get-MigrationStatus does not open a run context, so run a real command to trigger sealing if needed.
        if ($sealed.Count -eq 0) {
            $null = Migrate-Notifications -Stage Batching -DryRun -Config $script:Config -WarningAction SilentlyContinue
            $sealed = @(Get-ChildItem -LiteralPath (Join-Path $script:Work 'logs') -Filter 'run-*.jsonl' |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'audit.sealed_after_interruption' })
        }
        $sealed.Count | Should -Be 1
    }

    It 'the killed Copy is not approvable and blocks Verify' {
        { Approve-MigrationGate -Stage Copy -Batch 2019-05 -Config $script:Config -Comment 'x' } | Should -Throw
        $r = Migrate-Notifications -Stage Verify -Batch 2019-05 -Config $script:Config -WarningAction SilentlyContinue
        $r.failed.Count | Should -Be 1
    }

    It 'resumes: Copy completes, then Verify and Reconcile pass with every file byte-identical' {
        $c = Step 'Copy' '2019-05'
        $c.failed.Count | Should -Be 0
        $null = Step 'Verify' '2019-05'
        $rec = Migrate-Notifications -Stage Reconcile -Batch 2019-05 -Config $script:Config -WarningAction SilentlyContinue
        $rec.ran[0].summary.passed | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:Tgt -Recurse -File).Count | Should -Be 6000
    }
}
