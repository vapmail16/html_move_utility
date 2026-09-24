#Requires -Modules Pester
# Unit tests for Stages/HtmlChecks.ps1: both sides checked, findings stored per run, parity differences ->
# exceptions, shared render sample, single read per file, chunking, dry run.
# Manifests are built directly from the test trees (HtmlChecks only needs rel_path, kind and size_bytes), so these
# tests do not depend on the scanner or on other stages.

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
    $script:mod = Get-Module NotificationMigration

    function Write-Text { param([string] $Path, [string] $Text)
        New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
        [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    }

    function New-Scenario {
        <# Source tree + copy on target (optionally skipping files); returns a context. #>
        param([string] $Name, [string[]] $SkipOnTarget = @(), [hashtable] $Override = @{}, [string] $TargetDirName = 'tgt')
        $root = Join-Path $TestDrive $Name
        $src = Join-Path $root 'src'; $tgt = Join-Path $root $TargetDirName; $work = Join-Path $root 'work'
        foreach ($d in @($src, $tgt, $work)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $files = [ordered]@{
            '2019/01/a.html'        = '<html><body><img src="img/logo.png"><a href="http://ServerA/x">old</a></body></html>'
            '2019/01/img/logo.png'  = 'png'
            '2019/01/noroot.html'   = '<div>fragment</div>'
            '2019/01/café 通知.html' = '<html><body>unicode</body></html>'
        }
        foreach ($k in $files.Keys) {
            Write-Text (Join-Path $src $k) $files[$k]
            if ($SkipOnTarget -notcontains $k) { Write-Text (Join-Path $tgt $k) $files[$k] }
        }
        [System.IO.File]::WriteAllBytes((Join-Path $src '2019/01/zero.html'), [byte[]]@())
        [System.IO.File]::WriteAllBytes((Join-Path $tgt '2019/01/zero.html'), [byte[]]@())
        $cfg = @{
            paths      = @{ sourceRoot = $src; targetRoot = $tgt; workDir = $work }
            inventory  = @{ aclReader = 'none'; threads = 2 }
            compare    = @{ fileFields = @('exists', 'size', 'hash', 'modified'); dirFields = @('exists') }
            copy       = @{ engine = 'dotnet' }
            htmlChecks = @{ rules = @{ absoluteLinks = @{ oldHosts = @('ServerA') }; renderSample = @{ rate = 1 } } }
        }
        $path = Join-Path $root 'migration.config.json'
        [System.IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json -Depth 10))
        return (& $script:mod { param($p, $o) New-MigContext -ConfigPath $p -Override $o -Operator 'maker' } $path $Override)
    }

    function Write-TestManifest {
        param($Ctx, [ValidateSet('source', 'target')][string] $Side, [string] $BatchId = 'B1')
        $root = $Ctx.Config.paths.sourceRoot
        if ($Side -eq 'target') { $root = $Ctx.Config.paths.targetRoot }
        $full = (Resolve-Path -LiteralPath $root).ProviderPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $recs = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName | ForEach-Object {
            $rel = $_.FullName.Substring($full.Length + 1).Replace('/', '\')
            if ($_.PSIsContainer) { [ordered]@{ rel_path = $rel; kind = 'dir'; batch_id = $BatchId; side = $Side; size_bytes = $null } }
            else { [ordered]@{ rel_path = $rel; kind = 'file'; batch_id = $BatchId; side = $Side; size_bytes = $_.Length } }
        })
        & $script:mod { param($c, $s, $b, $r) Write-MigManifest -Store $c.Store -BatchId $b -Side $s -Records $r } $Ctx $Side $BatchId $recs
    }

    function Invoke-HtmlChecks { param($Ctx, [string] $BatchId = 'B1')
        & $script:mod { param($c, $b) Invoke-MigStageHtmlChecks -Ctx $c -BatchId $b } $Ctx $BatchId
    }
    function Read-Store { param($Ctx, [string] $Name, [string] $BatchId = 'B1')
        return , @(& $script:mod { param($c, $n, $b) Read-MigStoreRecords -Store $c.Store -Name $n -BatchId $b } $Ctx $Name $BatchId)
    }
    function Get-Exceptions { param($Ctx)
        return , @(& $script:mod { param($c) Get-MigExceptions -Store $c.Store -BatchId 'B1' } $Ctx)
    }
    function Get-BatchInfo { param($Ctx)
        & $script:mod { param($c) (Get-MigBatches -Store $c.Store)['B1'] } $Ctx
    }
    function Read-RunFile { <# Findings file of the latest run (from batch info htmlChecks.files). #>
        param($Ctx, [ValidateSet('source', 'target', 'parity')][string] $Kind)
        $name = (Get-BatchInfo -Ctx $Ctx)['htmlChecks']['files'][$Kind]
        $r = Read-Store -Ctx $Ctx -Name $name
        return $r   # unrolled: wrap calls in @()
    }
    function New-Ready { <# Scenario + both manifests. #>
        param([string] $Name, [string[]] $SkipOnTarget = @(), [hashtable] $Override = @{}, [string] $TargetDirName = 'tgt')
        $c = New-Scenario -Name $Name -SkipOnTarget $SkipOnTarget -Override $Override -TargetDirName $TargetDirName
        Write-TestManifest -Ctx $c -Side source
        Write-TestManifest -Ctx $c -Side target
        return $c
    }
    function Get-StoreSnapshot { param($Ctx)
        $root = $Ctx.Store.Root
        return @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName | ForEach-Object {
            if ($_.PSIsContainer) { 'D|' + $_.FullName } else { 'F|{0}|{1}|{2}' -f $_.FullName, $_.Length, (Get-FileHash -LiteralPath $_.FullName).Hash }
        })
    }
}

Describe 'Invoke-MigStageHtmlChecks' {
    AfterEach { if ($script:ctx) { & $script:mod { param($c) Close-MigContext -Ctx $c } $script:ctx; $script:ctx = $null } }

    It 'fails with a clear message when the target manifest does not exist (Verify not run)' {
        $script:ctx = New-Scenario -Name 'noverify'
        Write-TestManifest -Ctx $script:ctx -Side source
        { Invoke-HtmlChecks -Ctx $script:ctx } | Should -Throw '*Verify*'
    }

    It 'identical trees: findings on both sides, parity true, no exceptions, stored with run_id' {
        $script:ctx = New-Scenario -Name 'same'
        Write-TestManifest -Ctx $script:ctx -Side source
        Write-TestManifest -Ctx $script:ctx -Side target
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        $s.parity | Should -BeTrue
        $s.parity_differences | Should -Be 0
        $s.source_findings | Should -BeGreaterThan 0
        $s.source_findings | Should -Be $s.target_findings

        $s.files.source | Should -Be ('htmlchecks.source.{0}.jsonl' -f $script:ctx.RunId)
        $s.files.target | Should -Be ('htmlchecks.target.{0}.jsonl' -f $script:ctx.RunId)
        $s.files.parity | Should -Be ('htmlchecks.parity.{0}.jsonl' -f $script:ctx.RunId)
        $src = @(Read-RunFile -Ctx $script:ctx -Kind source)
        $tgt = @(Read-RunFile -Ctx $script:ctx -Kind target)
        $src.Count | Should -Be $s.source_findings
        $tgt.Count | Should -Be $s.target_findings
        foreach ($f in @($src) + @($tgt)) { $f['run_id'] | Should -Be $script:ctx.RunId }
        @($src | ForEach-Object { $_['rule'] } | Sort-Object -Unique) | Should -Contain 'absoluteLinks'
        @($src | ForEach-Object { $_['rule'] } | Sort-Object -Unique) | Should -Contain 'zeroByte'
        @($src | ForEach-Object { $_['rule'] } | Sort-Object -Unique) | Should -Contain 'fileName'
        @($src | ForEach-Object { $_['rule'] } | Sort-Object -Unique) | Should -Contain 'renderSample'
        @(Read-RunFile -Ctx $script:ctx -Kind parity).Count | Should -Be 0
        (Get-Exceptions -Ctx $script:ctx).Count | Should -Be 0

        $info = (Get-BatchInfo -Ctx $script:ctx)['htmlChecks']
        $info['files']['source'] | Should -Be $s.files.source
        $info['parity'] | Should -BeTrue
        $info['run_id'] | Should -Be $script:ctx.RunId
        $info['by_rule']['zeroByte'] | Should -Be 2
    }

    It 'a finding only on one side is a parity difference and opens an html_parity exception' {
        $script:ctx = New-Scenario -Name 'diff' -SkipOnTarget @('2019/01/img/logo.png')
        Write-TestManifest -Ctx $script:ctx -Side source
        Write-TestManifest -Ctx $script:ctx -Side target
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        $s.parity | Should -BeFalse
        $s.parity_differences | Should -Be 1
        $s.exceptions_opened | Should -Be 1

        $p = @(Read-RunFile -Ctx $script:ctx -Kind parity)
        $p.Count | Should -Be 1
        $p[0]['rule'] | Should -Be 'linkedAssets'
        $p[0]['only_on'] | Should -Be 'target'
        $p[0]['rel_path'] | Should -Be '2019\01\a.html'
        $p[0]['run_id'] | Should -Be $script:ctx.RunId

        $ex = Get-Exceptions -Ctx $script:ctx
        $ex.Count | Should -Be 1
        $ex[0]['category'] | Should -Be 'html_parity'
        $ex[0]['rel_path'] | Should -Be '2019\01\a.html'
        $ex[0]['detail'] | Should -Match 'only on target'
        (Get-BatchInfo -Ctx $script:ctx)['htmlChecks']['parity'] | Should -BeFalse
    }

    It 're-running does not duplicate open exceptions, records the new run_id and writes a new per-run file' {
        $script:ctx = New-Scenario -Name 'rerun' -SkipOnTarget @('2019/01/img/logo.png')
        Write-TestManifest -Ctx $script:ctx -Side source
        Write-TestManifest -Ctx $script:ctx -Side target
        $s1 = Invoke-HtmlChecks -Ctx $script:ctx
        $first = $script:ctx.RunId
        $script:ctx.RunId = 'second-run'
        $s2 = Invoke-HtmlChecks -Ctx $script:ctx
        $s2.exceptions_opened | Should -Be 0
        (Get-Exceptions -Ctx $script:ctx).Count | Should -Be 1
        (Get-BatchInfo -Ctx $script:ctx)['htmlChecks']['run_id'] | Should -Be 'second-run'
        $s2.files.parity | Should -Be 'htmlchecks.parity.second-run.jsonl'
        $s1.files.parity | Should -Be "htmlchecks.parity.$first.jsonl"
        @(Read-RunFile -Ctx $script:ctx -Kind parity | Where-Object { $_['run_id'] -eq 'second-run' }).Count | Should -Be 1
        $p1 = Read-Store -Ctx $script:ctx -Name $s1.files.parity; $p2 = Read-Store -Ctx $script:ctx -Name $s2.files.parity
        @($p1 | Where-Object { $_['run_id'] -eq $first }).Count | Should -Be 1
        @($p2 | Where-Object { $_['run_id'] -eq $first }).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:ctx.Store.Root 'batches/B1/htmlchecks.parity.jsonl') | Should -BeFalse
    }

    It 'never re-opens an accepted exception; one audit event for all opened exceptions' {
        $script:ctx = New-Ready -Name 'accepted' -SkipOnTarget @('2019/01/img/logo.png')
        # A second rel_path with a difference: a target-only zero-byte change.
        [System.IO.File]::WriteAllText((Join-Path $script:ctx.Config.paths.targetRoot '2019/01/zero.html'), '<html></html>')
        Write-TestManifest -Ctx $script:ctx -Side target
        $s1 = Invoke-HtmlChecks -Ctx $script:ctx
        $s1.exceptions_opened | Should -Be 2
        $audit = @(Get-Content -LiteralPath $script:ctx.Audit.Path | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'htmlchecks.parity_exceptions' })
        $audit.Count | Should -Be 1
        $audit[0].data.opened | Should -Be 2
        $all = Get-Exceptions -Ctx $script:ctx
        $ex = @($all | Where-Object { $_['rel_path'] -eq '2019\01\a.html' })[0]
        & $script:mod { param($c, $id) Update-MigException -Store $c.Store -BatchId 'B1' -Id $id -Status accepted -Resolution 'known broken link' -By 'checker' } $script:ctx $ex['id']
        $script:ctx.RunId = 'run-after-accept'
        $s2 = Invoke-HtmlChecks -Ctx $script:ctx
        $s2.parity | Should -BeFalse
        $s2.exceptions_opened | Should -Be 0
        $all = Get-Exceptions -Ctx $script:ctx
        $all.Count | Should -Be 2
        @($all | Where-Object { $_['rel_path'] -eq '2019\01\a.html' })[0]['status'] | Should -Be 'accepted'
    }

    It 'without requireSourceTargetParity, differences are reported but no exception is opened' {
        $script:ctx = New-Scenario -Name 'noreq' -SkipOnTarget @('2019/01/img/logo.png') -Override @{ htmlChecks = @{ requireSourceTargetParity = $false } }
        Write-TestManifest -Ctx $script:ctx -Side source
        Write-TestManifest -Ctx $script:ctx -Side target
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        $s.parity | Should -BeFalse
        (Get-Exceptions -Ctx $script:ctx).Count | Should -Be 0
    }

    It 'longPath: a path too long only on the (longer) target root is a parity difference naming both lengths' {
        $script:ctx = New-Scenario -Name 'lp' -TargetDirName 'a-much-longer-target-root-folder-name'
        $srcRoot = $script:ctx.Config.paths.sourceRoot; $tgtRoot = $script:ctx.Config.paths.targetRoot
        $rel = '2019\01\img\logo.png'
        $max = $srcRoot.Length + 1 + $rel.Length + 5
        $script:ctx.Config.htmlChecks.rules.longPath.maxLength = $max
        Write-TestManifest -Ctx $script:ctx -Side source
        Write-TestManifest -Ctx $script:ctx -Side target
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        $s.parity | Should -BeFalse
        $p = @(Read-RunFile -Ctx $script:ctx -Kind parity | Where-Object { $_['rule'] -eq 'longPath' })
        $p.Count | Should -BeGreaterThan 0
        @($p | Where-Object { $_['only_on'] -ne 'target' }).Count | Should -Be 0
        $logo = @($p | Where-Object { $_['rel_path'] -eq $rel })[0]
        $logo['detail'] | Should -Match ("full path length {0} on source, {1} on target; maxLength {2}" -f ($srcRoot.Length + 1 + $rel.Length), ($tgtRoot.Length + 1 + $rel.Length), $max)
        $all = Get-Exceptions -Ctx $script:ctx
        @($all | Where-Object { $_['rel_path'] -eq $rel }).Count | Should -Be 1
        @(Read-RunFile -Ctx $script:ctx -Kind source | Where-Object { $_['rule'] -eq 'longPath' }).Count | Should -Be 0
    }

    It 'longPath: too long on both sides is parity (same finding on both sides)' {
        $script:ctx = New-Scenario -Name 'lp2' -TargetDirName 'tg2'
        $script:ctx.Config.htmlChecks.rules.longPath.maxLength = 10
        Write-TestManifest -Ctx $script:ctx -Side source
        Write-TestManifest -Ctx $script:ctx -Side target
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        $s.by_rule_source['longPath'] | Should -BeGreaterThan 0
        $s.by_rule_source['longPath'] | Should -Be $s.by_rule_target['longPath']
        $s.parity | Should -BeTrue
    }

    It 'renderSample: one sample from the source/target intersection, stable when either side has extra HTML files' {
        $o = @{ htmlChecks = @{ rules = @{ renderSample = @{ rate = 0; minPerBatch = 2 } } } }
        $script:ctx = New-Ready -Name 'sample-base' -Override $o
        $base = Invoke-HtmlChecks -Ctx $script:ctx
        $baseSample = @(Read-RunFile -Ctx $script:ctx -Kind source | Where-Object { $_['rule'] -eq 'renderSample' } | ForEach-Object { $_['rel_path'] } | Sort-Object)
        $baseSample.Count | Should -Be 2
        & $script:mod { param($c) Close-MigContext -Ctx $c } $script:ctx; $script:ctx = $null

        $script:ctx = New-Scenario -Name 'sample-extra' -Override $o
        foreach ($i in 1..25) {
            [System.IO.File]::WriteAllText((Join-Path $script:ctx.Config.paths.targetRoot ('2019/01/extra{0}.html' -f $i)), '<html>x</html>')
            [System.IO.File]::WriteAllText((Join-Path $script:ctx.Config.paths.sourceRoot ('2019/01/srconly{0}.html' -f $i)), '<html>x</html>')
        }
        Write-TestManifest -Ctx $script:ctx -Side source
        Write-TestManifest -Ctx $script:ctx -Side target
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        $s.parity | Should -BeTrue
        $s.html_files_compared | Should -Be 4
        $s.sample_size | Should -Be 2
        $srcS = @(Read-RunFile -Ctx $script:ctx -Kind source | Where-Object { $_['rule'] -eq 'renderSample' } | ForEach-Object { $_['rel_path'] } | Sort-Object)
        $tgtS = @(Read-RunFile -Ctx $script:ctx -Kind target | Where-Object { $_['rule'] -eq 'renderSample' } | ForEach-Object { $_['rel_path'] } | Sort-Object)
        $srcS | Should -Be $baseSample
        $tgtS | Should -Be $baseSample
    }

    It 'reads each HTML file once per side (all content rules share the read), also across chunks' {
        $o = @{ htmlChecks = @{ chunkSize = 2; rules = @{ malformed = @{ enabled = $true }; linkedAssets = @{ enabled = $true } } } }
        $script:ctx = New-Ready -Name 'onceread' -Override $o
        Mock -ModuleName NotificationMigration Read-MigHtmlText {
            @{ ok = $true; text = '<html><body><img src="img/logo.png"></body></html>'; encoding = 'utf-8'; size = 60; too_large = $false; binary = $false; error = $null }
        }
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        $s.chunks | Should -Be 2
        # 4 HTML files per side (a, noroot, café 通知, zero) -> 8 reads for 4 content rules.
        Should -Invoke Read-MigHtmlText -ModuleName NotificationMigration -Exactly -Times 8
        $s.parity | Should -BeTrue
    }

    It 'chunked and unchunked runs give the same results' {
        $script:ctx = New-Ready -Name 'chunks' -SkipOnTarget @('2019/01/img/logo.png')
        $a = Invoke-HtmlChecks -Ctx $script:ctx
        $script:ctx.Config.htmlChecks.chunkSize = 1
        $script:ctx.RunId = 'chunk-1'
        $b = Invoke-HtmlChecks -Ctx $script:ctx
        $b.chunks | Should -Be 4
        $a.chunks | Should -Be 1
        foreach ($k in @('parity', 'source_findings', 'target_findings', 'parity_differences')) { $b[$k] | Should -Be $a[$k] }
    }

    It 'reports skipped_large for every content rule and keeps parity when the file is large on both sides' {
        $o = @{ htmlChecks = @{ rules = @{ malformed = @{ maxBytesToParse = 30 } } } }
        $script:ctx = New-Ready -Name 'large' -Override $o
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        $big = @(Read-RunFile -Ctx $script:ctx -Kind source | Where-Object { $_['code'] -eq 'skipped_large' -and $_['rel_path'] -eq '2019\01\a.html' })
        @($big | ForEach-Object { $_['rule'] } | Sort-Object) | Should -Be @('absoluteLinks', 'linkedAssets', 'malformed', 'renderSample')
        @($big | Where-Object { $_['severity'] -ne 'warning' }).Count | Should -Be 0
        $s.skipped_large | Should -BeGreaterThan 7
        $s.parity | Should -BeTrue
    }

    It 'strictRenderer: fails the stage (writing nothing) when Edge is not found' {
        $o = @{ htmlChecks = @{ rules = @{ renderSample = @{ renderer = 'edgeHeadless'; strictRenderer = $true; edgePath = (Join-Path $TestDrive 'no-edge.exe') } } } }
        $script:ctx = New-Ready -Name 'strict' -Override $o
        $before = Get-StoreSnapshot -Ctx $script:ctx
        { Invoke-HtmlChecks -Ctx $script:ctx } | Should -Throw '*strictRenderer*'
        Get-StoreSnapshot -Ctx $script:ctx | Should -Be $before
    }

    It 'dry run computes the summary but writes nothing to the store' {
        $script:ctx = New-Ready -Name 'dry' -SkipOnTarget @('2019/01/img/logo.png')
        $script:ctx.DryRun = $true
        $before = Get-StoreSnapshot -Ctx $script:ctx
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        Get-StoreSnapshot -Ctx $script:ctx | Should -Be $before
        $s.dry_run | Should -BeTrue
        $s.parity | Should -BeFalse
        $s.parity_differences | Should -Be 1
        $s.exceptions_opened | Should -Be 0
        $s.exceptions_would_open | Should -Be 1
        $s.source_findings | Should -BeGreaterThan 0
        (Get-BatchInfo -Ctx $script:ctx) | Should -BeNullOrEmpty
    }

    It 'files missing on target are left to Reconcile (not compared for parity)' {
        $script:ctx = New-Scenario -Name 'missingfile' -SkipOnTarget @('2019/01/noroot.html')
        Write-TestManifest -Ctx $script:ctx -Side source
        Write-TestManifest -Ctx $script:ctx -Side target
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        $s.parity | Should -BeTrue
    }

    It 'runs only enabled rules' {
        $off = @{ htmlChecks = @{ rules = @{ zeroByte = @{ enabled = $false }; renderSample = @{ enabled = $false } } } }
        $script:ctx = New-Scenario -Name 'enabled' -Override $off
        Write-TestManifest -Ctx $script:ctx -Side source
        Write-TestManifest -Ctx $script:ctx -Side target
        $s = Invoke-HtmlChecks -Ctx $script:ctx
        @($s.rules) | Should -Not -Contain 'zeroByte'
        @($s.rules) | Should -Not -Contain 'renderSample'
        @((Read-Store -Ctx $script:ctx -Name 'htmlchecks.source.jsonl') | Where-Object { $_['rule'] -eq 'zeroByte' }).Count | Should -Be 0
    }

    It 'never writes under either root' {
        $script:ctx = New-Scenario -Name 'readonly'
        Write-TestManifest -Ctx $script:ctx -Side source
        Write-TestManifest -Ctx $script:ctx -Side target
        $snap = { param($r) Get-ChildItem -LiteralPath $r -Recurse -Force | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks } }
        $b1 = & $snap $script:ctx.Config.paths.sourceRoot; $b2 = & $snap $script:ctx.Config.paths.targetRoot
        $null = Invoke-HtmlChecks -Ctx $script:ctx
        (& $snap $script:ctx.Config.paths.sourceRoot) | Should -Be $b1
        (& $snap $script:ctx.Config.paths.targetRoot) | Should -Be $b2
    }
}
