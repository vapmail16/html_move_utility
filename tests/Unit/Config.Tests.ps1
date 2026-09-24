#Requires -Modules Pester
# Unit tests for Core/Config.ps1: layered merge, path resolution, validation (one error listing all problems),
# target-under-source rejection and forbidden copy flags.

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
    $script:mod = Get-Module NotificationMigration

    function New-BaseConfig {
        param([string] $Name)
        $root = Join-Path $TestDrive $Name
        $src = Join-Path $root 'src'; $tgt = Join-Path $root 'tgt'; $work = Join-Path $root 'work'
        foreach ($d in @($src, $tgt, $work)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        return @{
            paths     = @{ sourceRoot = $src; targetRoot = $tgt; workDir = $work }
            inventory = @{ aclReader = 'none' }
            compare = @{ fileFields = @('exists', 'size', 'hash', 'created', 'modified', 'attributes'); dirFields = @('exists', 'modified') }
            copy      = @{ engine = 'dotnet' }
        }
    }
    function Save-Config { param([hashtable] $Config, [string] $Name = 'cfg.json')
        $p = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllText($p, ($Config | ConvertTo-Json -Depth 10))
        return $p
    }
    function Get-Cfg { param([string] $Path, [hashtable] $Override)
        & $script:mod { param($p, $o) Get-MigrationConfig -Path $p -Override $o } $Path $Override
    }
    function Get-CfgError { param([hashtable] $Config, [hashtable] $Override)
        $p = Save-Config -Config $Config -Name ('err-' + [guid]::NewGuid().ToString('N') + '.json')
        try { $null = Get-Cfg -Path $p -Override $Override; return $null } catch { return $_.Exception.Message }
    }
}

Describe 'Get-MigrationConfig merge' {
    BeforeAll {
        $script:base = New-BaseConfig -Name 'merge'
        $script:base.inventory.threads = 3
        $script:base.report = @{ formats = @('json') }
        $script:path = Save-Config -Config $script:base -Name 'merge.json'
        $script:cfg = Get-Cfg -Path $script:path
    }

    It 'user values override defaults' {
        $script:cfg.inventory.threads | Should -Be 3
        $script:cfg.copy.engine | Should -Be 'dotnet'
    }
    It 'dictionaries merge deeply: unspecified nested keys keep their defaults' {
        $script:cfg.inventory.chunkSize | Should -Be 500
        $script:cfg.inventory.hash.algorithm | Should -Be 'SHA256'
        $script:cfg.copy.maxRetries | Should -Be 3
        $script:cfg.htmlChecks.rules.longPath.maxLength | Should -Be 260
    }
    It 'arrays replace rather than append' {
        @($script:cfg.report.formats) | Should -Be @('json')
    }
    It '-Override wins over the file and still merges deeply' {
        $c = Get-Cfg -Path $script:path -Override @{ inventory = @{ threads = 9 }; htmlChecks = @{ rules = @{ longPath = @{ maxLength = 100 } } } }
        $c.inventory.threads | Should -Be 9
        $c.inventory.chunkSize | Should -Be 500
        $c.htmlChecks.rules.longPath.maxLength | Should -Be 100
        $c.htmlChecks.rules.longPath.enabled | Should -BeTrue
    }
    It 'records config path and hash (_meta)' {
        $script:cfg._meta.configPath | Should -Be (Resolve-Path $script:path).ProviderPath
        $script:cfg._meta.configHash | Should -Match '^[0-9A-F]{64}$'
    }
    It 'resolves store/report/log dirs relative to workDir, keeps rooted ones' {
        $w = $script:cfg.paths.workDir
        $script:cfg._resolved.storeDir | Should -Be (Join-Path $w 'store')
        $script:cfg._resolved.reportDir | Should -Be (Join-Path $w 'reports')
        $abs = Join-Path $TestDrive 'abs-logs'
        (Get-Cfg -Path $script:path -Override @{ paths = @{ logDir = $abs } })._resolved.logDir | Should -Be $abs
    }
    It 'makes relative roots absolute against the PowerShell location' {
        Push-Location (Join-Path $TestDrive 'merge')
        try {
            $c = Get-Cfg -Path $script:path -Override @{ paths = @{ sourceRoot = 'src'; targetRoot = './tgt'; workDir = 'work' } }
            [System.IO.Path]::IsPathRooted($c.paths.sourceRoot) | Should -BeTrue
            $c.paths.sourceRoot | Should -Be (Join-Path (Join-Path $TestDrive 'merge') 'src')
            $c._resolved.storeDir | Should -Be (Join-Path (Join-Path (Join-Path $TestDrive 'merge') 'work') 'store')
        } finally { Pop-Location }
    }
    It 'defaults stay free of environment-specific values' {
        $d = Get-Content -Raw (Join-Path $script:mod.ModuleBase 'config/defaults.json') | ConvertFrom-Json
        $d.paths.sourceRoot | Should -BeNullOrEmpty
        $d.paths.targetRoot | Should -BeNullOrEmpty
        @($d.htmlChecks.rules.absoluteLinks.oldHosts).Count | Should -Be 0
    }
    It 'fails for a missing config file' {
        { Get-Cfg -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw
    }
}

Describe 'Assert-MigConfigValid' {
    It 'requires sourceRoot, targetRoot and workDir and reports them all at once' {
        $p = Save-Config -Config @{ inventory = @{ aclReader = 'none' } } -Name 'empty.json'
        $msg = $null
        try { $null = Get-Cfg -Path $p } catch { $msg = $_.Exception.Message }
        $msg | Should -Match 'paths.sourceRoot is required'
        $msg | Should -Match 'paths.targetRoot is required'
        $msg | Should -Match 'paths.workDir is required'
    }

    It 'rejects <case>' -ForEach @(
        @{ case = 'an unknown stage'; ov = @{ pipeline = @{ stages = @('Inventory', 'Bogus') } }; msg = "unknown stage 'Bogus'" }
        @{ case = 'an unknown gate'; ov = @{ pipeline = @{ gates = @('Nope') } }; msg = "pipeline.gates: unknown stage 'Nope'" }
        @{ case = 'a bad inventory.mode'; ov = @{ inventory = @{ mode = 'ftp' } }; msg = 'inventory.mode' }
        @{ case = 'a bad aclReader'; ov = @{ inventory = @{ aclReader = 'posix' } }; msg = 'inventory.aclReader' }
        @{ case = 'threads < 1'; ov = @{ inventory = @{ threads = 0 } }; msg = 'inventory.threads' }
        @{ case = 'chunkSize < 1'; ov = @{ inventory = @{ chunkSize = 0 } }; msg = 'inventory.chunkSize' }
        @{ case = 'an unsupported hash'; ov = @{ inventory = @{ hash = @{ algorithm = 'MD5' } } }; msg = 'inventory.hash.algorithm' }
        @{ case = 'a non-integer manifestCacheRecords'; ov = @{ inventory = @{ manifestCacheRecords = 'many' } }; msg = 'manifestCacheRecords' }
        @{ case = 'an unregistered batching strategy'; ov = @{ batching = @{ strategy = 'byMoon' } }; msg = "batching.strategy 'byMoon'" }
        @{ case = 'a regex pattern that does not compile'; ov = @{ batching = @{ strategy = 'regex'; options = @{ pattern = '([' } } }; msg = 'does not compile' }
        @{ case = 'a regex strategy without template'; ov = @{ batching = @{ strategy = 'regex'; options = @{ template = '' } } }; msg = 'batching.options.template' }
        @{ case = 'folderDepth depth 0'; ov = @{ batching = @{ strategy = 'folderDepth'; options = @{ depth = 0 } } }; msg = 'batching.options.depth' }
        @{ case = 'a bad dateField'; ov = @{ batching = @{ strategy = 'yearMonth'; options = @{ dateField = 'accessed_utc' } } }; msg = 'dateField' }
        @{ case = 'an unregistered copy engine'; ov = @{ copy = @{ engine = 'teleport' } }; msg = "copy.engine 'teleport'" }
        @{ case = 'negative maxRetries'; ov = @{ copy = @{ maxRetries = -1 } }; msg = 'copy.maxRetries' }
        @{ case = 'robocopy threads 200'; ov = @{ copy = @{ robocopy = @{ threads = 200 } } }; msg = 'copy.robocopy.threads must be 1-128' }
        @{ case = 'successExitCodeMax 8'; ov = @{ copy = @{ robocopy = @{ successExitCodeMax = 8 } } }; msg = 'successExitCodeMax' }
        @{ case = 'an unknown compare field'; ov = @{ compare = @{ fileFields = @('size', 'colour') } }; msg = "unknown field 'colour'" }
        @{ case = 'negative timestamp tolerance'; ov = @{ compare = @{ timestampToleranceSec = -1 } }; msg = 'timestampToleranceSec' }
        @{ case = 'a bad acl mode'; ov = @{ compare = @{ acl = @{ mode = 'magic' } } }; msg = 'compare.acl.mode' }
        @{ case = 'mapped acl without sidMapFile'; ov = @{ compare = @{ acl = @{ mode = 'mapped' } } }; msg = 'sidMapFile is required' }
        @{ case = 'a non-bool includeOwner'; ov = @{ compare = @{ acl = @{ includeOwner = 'yes' } } }; msg = 'includeOwner' }
        @{ case = 'an unknown delta field'; ov = @{ delta = @{ detectBy = @('colour') } }; msg = 'delta.detectBy' }
        @{ case = 'renderSample rate > 1'; ov = @{ htmlChecks = @{ rules = @{ renderSample = @{ rate = 2 } } } }; msg = 'renderSample.rate' }
        @{ case = 'an unregistered html rule'; ov = @{ htmlChecks = @{ rules = @{ spellCheck = @{ enabled = $true } } } }; msg = "'spellCheck' is not a registered HtmlRule" }
        @{ case = 'an unknown report format'; ov = @{ report = @{ formats = @('pdf') } }; msg = "unknown format 'pdf'" }
        @{ case = 'a bad throttle time zone'; ov = @{ throttle = @{ timeZone = 'Mars' } }; msg = 'throttle.timeZone' }
        @{ case = 'a bad throttle day and time'; ov = @{ throttle = @{ windows = @(@{ days = @('Funday'); from = '25:99'; to = '18:00'; threads = 2 }) } }; msg = "invalid day 'Funday'" }
        @{ case = 'a bad throttle time'; ov = @{ throttle = @{ windows = @(@{ days = @('Mon'); from = '25:99'; to = '18:00'; threads = 2 }) } }; msg = "invalid time '25:99'" }
    ) {
        $err = Get-CfgError -Config (New-BaseConfig -Name 'valid') -Override $ov
        $err | Should -Match '^Invalid configuration'
        $err | Should -Match ([regex]::Escape($msg))
    }

    It 'reports a clear error when folderDepth has no depth option' {
        $err = Get-CfgError -Config (New-BaseConfig -Name 'nodepth') -Override @{ batching = @{ strategy = 'folderDepth' } }
        $err | Should -Match 'batching.options.depth'
    }

    It 'accepts a throttle window without the optional threads key' {
        $err = Get-CfgError -Config (New-BaseConfig -Name 'nothreads') -Override @{ throttle = @{ windows = @(@{ days = @('Mon'); from = '08:00'; to = '18:00'; ipgMs = 10 }) } }
        $err | Should -BeNullOrEmpty
    }

    It 'lists every problem in one error' {
        $msg = Get-CfgError -Config (New-BaseConfig -Name 'multi') -Override @{ inventory = @{ threads = 0; chunkSize = 0 }; report = @{ formats = @('pdf') } }
        $msg | Should -Match 'inventory.threads'
        $msg | Should -Match 'inventory.chunkSize'
        $msg | Should -Match 'report.formats'
    }

    It 'accepts the defaults plus required paths' {
        Get-CfgError -Config (New-BaseConfig -Name 'ok') | Should -BeNullOrEmpty
    }
}

Describe 'Config path safety' {
    It 'rejects a targetRoot inside sourceRoot' {
        $c = New-BaseConfig -Name 'tus'
        $c.paths.targetRoot = Join-Path $c.paths.sourceRoot 'copy'
        Get-CfgError -Config $c | Should -Match 'targetRoot must not be inside sourceRoot'
    }
    It 'rejects a targetRoot equal to sourceRoot (case and trailing separator ignored)' {
        $c = New-BaseConfig -Name 'teq'
        $c.paths.targetRoot = $c.paths.sourceRoot.ToUpperInvariant() + [System.IO.Path]::DirectorySeparatorChar
        Get-CfgError -Config $c | Should -Match 'targetRoot must not be inside sourceRoot'
    }
    It "rejects a targetRoot that reaches the source through '..'" {
        $c = New-BaseConfig -Name 'tdot'
        $c.paths.targetRoot = Join-Path (Join-Path $c.paths.targetRoot '..') 'src'
        Get-CfgError -Config $c | Should -Match 'targetRoot must not be inside sourceRoot'
    }
    It 'rejects a sourceRoot inside targetRoot' {
        $c = New-BaseConfig -Name 'sut'
        $c.paths.sourceRoot = Join-Path $c.paths.targetRoot 'src'
        Get-CfgError -Config $c | Should -Match 'sourceRoot must not be inside targetRoot'
    }
    It 'rejects workDir and absolute store/report/log dirs inside sourceRoot' {
        $c = New-BaseConfig -Name 'wus'
        $c.paths.workDir = Join-Path $c.paths.sourceRoot 'work'
        Get-CfgError -Config $c | Should -Match 'paths.workDir must not be inside sourceRoot'
        $c2 = New-BaseConfig -Name 'sdus'
        $c2.paths.storeDir = Join-Path $c2.paths.sourceRoot 'store'
        $c2.paths.logDir = Join-Path $c2.paths.sourceRoot 'logs'
        $m = Get-CfgError -Config $c2
        $m | Should -Match 'paths.storeDir must not be inside sourceRoot'
        $m | Should -Match 'paths.logDir must not be inside sourceRoot'
    }
    It 'accepts a sibling whose name starts with the source name' {
        $c = New-BaseConfig -Name 'sib'
        $c.paths.targetRoot = $c.paths.sourceRoot + '2'
        Get-CfgError -Config $c | Should -BeNullOrEmpty
    }
}

Describe 'Forbidden copy flags' {
    It 'rejects robocopy flag <flag>' -ForEach @(
        @{ flag = '/MIR' }, @{ flag = '/MOV' }, @{ flag = '/MOVE' }, @{ flag = '/PURGE' }, @{ flag = '/mir' }, @{ flag = '/CREATE' }
    ) {
        $c = New-BaseConfig -Name 'flags'
        $c.copy = @{ engine = 'robocopy'; robocopy = @{ flags = @('/COPY:DAT', $flag) } }
        Get-CfgError -Config $c | Should -Match 'SAFETY: copy flag'
    }
    It 'keeps the built-in floor even when forbiddenFlags is emptied' {
        $c = New-BaseConfig -Name 'floor'
        $c.copy = @{ engine = 'robocopy'; forbiddenFlags = @(); robocopy = @{ flags = @('/MIR') } }
        Get-CfgError -Config $c | Should -Match 'SAFETY'
    }
    It 'rejects /MT and /LOG in flags (managed by the tool)' {
        $c = New-BaseConfig -Name 'mtlog'
        $c.copy = @{ engine = 'robocopy'; robocopy = @{ flags = @('/MT:8', '/LOG:x.txt') } }
        $m = Get-CfgError -Config $c
        $m | Should -Match 'copy.robocopy.threads'
        $m | Should -Match 'logging is managed'
    }
    It 'accepts the default robocopy flags' {
        $c = New-BaseConfig -Name 'robook'
        $c.copy = @{ engine = 'robocopy' }
        Get-CfgError -Config $c | Should -BeNullOrEmpty
    }
}
