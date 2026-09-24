#Requires -Modules Pester
# Unit tests: Core/Scanner.ps1 - walk order, case-only duplicates, long-path fallback, hash buffer sizing.

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking

    # Fake FileSystemInfo for mocked enumerations; defined in the module scope so mock bodies (module scope) see it.
    & (Get-Module NotificationMigration) {
        function script:New-FakeFsEntry {
            param([string] $Name, [switch] $Dir, [string] $Parent = 'X:\root')
            $attrs = [System.IO.FileAttributes]::Archive
            if ($Dir) { $attrs = [System.IO.FileAttributes]::Directory }
            return [pscustomobject]@{ Name = $Name; Attributes = $attrs; FullName = ($Parent + '\' + $Name) }
        }
    }
}

Describe 'Get-MigTreeEntries' {
    It 'sorts each folder by name, ordinal ignoring case' {
        $root = Join-Path $TestDrive 'sort'
        New-Item -ItemType Directory -Path (Join-Path $root 'Mid') -Force | Out-Null
        foreach ($n in @('b.html', 'A.html', '_x.html', 'c.html', 'Mid/z.html', 'Mid/Y.html')) { [IO.File]::WriteAllText((Join-Path $root $n), 'x') }
        InModuleScope NotificationMigration -Parameters @{ root = $root } {
            param($root)
            $e = @(Get-MigTreeEntries -Root $root -UseLongPath $false)
            # Ordinal-ignore-case compares upper-case code points: 'A' < 'B' < 'C' < 'M' < '_' (0x5F).
            @($e | ForEach-Object { $_.rel_path }) | Should -Be @('A.html', 'b.html', 'c.html', 'Mid', '_x.html', 'Mid\Y.html', 'Mid\z.html')
            @($e | Where-Object { $_.rel_path -eq 'b.html' })[0].full | Should -Be (Join-Path $root 'b.html')
        }
    }

    It 'keeps each entry paired with its own path after sorting (mixed files and folders)' {
        $root = Join-Path $TestDrive 'pair'
        New-Item -ItemType Directory -Path (Join-Path $root 'b') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'c.html'), 'c')
        [IO.File]::WriteAllText((Join-Path $root 'a.html'), 'a')
        InModuleScope NotificationMigration -Parameters @{ root = $root } {
            param($root)
            foreach ($e in @(Get-MigTreeEntries -Root $root -UseLongPath $false)) {
                [IO.Path]::GetFileName($e.full) | Should -Be $e.rel_path
                if ($e.rel_path -eq 'b') { $e.kind | Should -Be 'dir' } else { $e.kind | Should -Be 'file' }
            }
        }
    }

    It 'emits case-only duplicates as case_duplicate_of errors and does not descend into them' {
        InModuleScope NotificationMigration {
            Mock Get-MigDirectoryChildren {
                if ($Path -like '*sub') { return @(New-FakeFsEntry -Name 'inner.html' -Parent $Path) }
                @(
                    (New-FakeFsEntry -Name 'Report.html'),
                    (New-FakeFsEntry -Name 'report.HTML'),
                    (New-FakeFsEntry -Name 'REPORT.html'),
                    (New-FakeFsEntry -Name 'sub' -Dir),
                    (New-FakeFsEntry -Name 'SUB' -Dir),
                    (New-FakeFsEntry -Name 'other.html')
                )
            }
            $e = @(Get-MigTreeEntries -Root 'X:\root' -UseLongPath $false)
            $files = @($e | Where-Object { $_.kind -ne 'error' })
            $errs = @($e | Where-Object { $_.kind -eq 'error' })
            $files.Count | Should -Be 4             # one Report.html, other.html, one sub, sub\inner.html
            $errs.Count | Should -Be 3
            $first = @($files | Where-Object { $_.rel_path -like 'report.html' })
            $first.Count | Should -Be 1
            foreach ($x in $errs) { $x.error | Should -BeLike 'case_duplicate_of:*' }
            @($errs | Where-Object { $_.rel_path -like 'report.html' }).Count | Should -Be 2
            @($errs | Where-Object { $_.rel_path -like 'report.html' } | ForEach-Object { $_.error } | Select-Object -Unique) | Should -Be @('case_duplicate_of:' + $first[0].rel_path)
            @($errs | Where-Object { $_.rel_path -ceq 'SUB' -or $_.rel_path -ceq 'sub' }).Count | Should -Be 1
            @($e | Where-Object { $_.rel_path -like 'sub\inner.html' }).Count | Should -Be 1   # descended only once
            Should -Invoke Get-MigDirectoryChildren -Times 2 -Exactly
        }
    }

    It 'reports a folder that cannot be listed as an error entry' {
        InModuleScope NotificationMigration {
            Mock Get-MigDirectoryChildren {
                if ($Path -like '*locked') { throw [System.UnauthorizedAccessException]::new('Access denied') }
                @((New-FakeFsEntry -Name 'locked' -Dir), (New-FakeFsEntry -Name 'a.html'))
            }
            $e = @(Get-MigTreeEntries -Root 'X:\root' -UseLongPath $false)
            $err = @($e | Where-Object { $_.kind -eq 'error' })
            $err.Count | Should -Be 1
            $err[0].rel_path | Should -Be 'locked'
            $err[0].error | Should -Match 'Access denied'
        }
    }
}

Describe 'Get-MigTreeEntries long-path safety net' {
    It 'uses the \\?\ prefix on Windows when enabled' {
        InModuleScope NotificationMigration {
            Mock Test-MigIsWindows { $true }
            Mock Get-MigDirectoryChildren { @() }
            [void]@(Get-MigTreeEntries -Root 'C:\data' -UseLongPath $true)
            Should -Invoke Get-MigDirectoryChildren -ParameterFilter { $Path.StartsWith('\\?\') } -Times 1 -Exactly
        }
    }

    It 'on Windows PowerShell 5.1 retries the first enumeration once without the prefix, with a warning' {
        InModuleScope NotificationMigration {
            Mock Test-MigIsWindows { $true }
            Mock Test-MigIsDesktopEdition { $true }
            Mock Get-MigDirectoryChildren {
                if ($Path.StartsWith('\\?\')) { throw [System.ArgumentException]::new('Illegal characters in path.') }
                if ($Path -like '*deep') { return @(New-FakeFsEntry -Name 'x.html' -Parent $Path) }
                @((New-FakeFsEntry -Name 'deep' -Dir), (New-FakeFsEntry -Name 'a.html'))
            }
            $e = @(Get-MigTreeEntries -Root 'C:\data' -UseLongPath $true -WarningVariable w -WarningAction SilentlyContinue)
            @($e | Where-Object { $_.kind -eq 'error' }).Count | Should -Be 0
            @($e | ForEach-Object { $_.rel_path }) | Should -Be @('a.html', 'deep', 'deep\x.html')
            @($w).Count | Should -Be 1
            "$w" | Should -Match 'without the'
            # prefixed once, then plain for the root and the rest of the walk
            Should -Invoke Get-MigDirectoryChildren -ParameterFilter { $Path.StartsWith('\\?\') } -Times 1 -Exactly
            Should -Invoke Get-MigDirectoryChildren -ParameterFilter { -not $Path.StartsWith('\\?\') } -Times 2 -Exactly
        }
    }

    It 'does not retry on PowerShell 7 (the prefix error is reported)' {
        InModuleScope NotificationMigration {
            Mock Test-MigIsWindows { $true }
            Mock Test-MigIsDesktopEdition { $false }
            Mock Get-MigDirectoryChildren {
                if ($Path.StartsWith('\\?\')) { throw [System.ArgumentException]::new('Illegal characters in path.') }
                if ($Path -like '*deep') { return @(New-FakeFsEntry -Name 'x.html' -Parent $Path) }
                @((New-FakeFsEntry -Name 'deep' -Dir), (New-FakeFsEntry -Name 'a.html'))
            }
            $e = @(Get-MigTreeEntries -Root 'C:\data' -UseLongPath $true -WarningAction SilentlyContinue)
            $e.Count | Should -Be 1
            $e[0].kind | Should -Be 'error'
            $e[0].rel_path | Should -Be ''
            Should -Invoke Get-MigDirectoryChildren -Times 1 -Exactly
        }
    }

    It 'does not retry errors other than ArgumentException / NotSupportedException' {
        InModuleScope NotificationMigration {
            Mock Test-MigIsWindows { $true }
            Mock Test-MigIsDesktopEdition { $true }
            Mock Get-MigDirectoryChildren { throw [System.UnauthorizedAccessException]::new('denied') }
            $e = @(Get-MigTreeEntries -Root 'C:\data' -UseLongPath $true -WarningAction SilentlyContinue)
            $e.Count | Should -Be 1
            $e[0].kind | Should -Be 'error'
            Should -Invoke Get-MigDirectoryChildren -Times 1 -Exactly
        }
    }

    It 'retries only the first enumeration (a later legacy-path failure is an error entry)' {
        InModuleScope NotificationMigration {
            Mock Test-MigIsWindows { $true }
            Mock Test-MigIsDesktopEdition { $true }
            Mock Get-MigDirectoryChildren {
                if ($Path -like '*deep') { throw [System.NotSupportedException]::new('The given path''s format is not supported.') }
                @((New-FakeFsEntry -Name 'deep' -Dir), (New-FakeFsEntry -Name 'a.html'))
            }
            $e = @(Get-MigTreeEntries -Root 'C:\data' -UseLongPath $true -WarningAction SilentlyContinue)
            @($e | Where-Object { $_.kind -eq 'error' }).Count | Should -Be 1
            @($e | Where-Object { $_.kind -eq 'error' })[0].rel_path | Should -Be 'deep'
            Should -Invoke Get-MigDirectoryChildren -Times 2 -Exactly
        }
    }

    It 'does not retry when the prefix is disabled' {
        InModuleScope NotificationMigration {
            Mock Test-MigIsWindows { $true }
            Mock Test-MigIsDesktopEdition { $true }
            Mock Get-MigDirectoryChildren { throw [System.ArgumentException]::new('bad') }
            $e = @(Get-MigTreeEntries -Root 'C:\data' -UseLongPath $false -WarningAction SilentlyContinue)
            $e[0].kind | Should -Be 'error'
            Should -Invoke Get-MigDirectoryChildren -Times 1 -Exactly
        }
    }
}

Describe 'Hash buffer sizing' {
    It 'uses min(file length, bufferSizeKB*1024) with a 4096-byte floor' {
        InModuleScope NotificationMigration {
            Get-MigHashBufferSize -Length 100 -BufferBytes 65536 | Should -Be 4096
            Get-MigHashBufferSize -Length 0 -BufferBytes 65536 | Should -Be 4096
            Get-MigHashBufferSize -Length 10000 -BufferBytes 65536 | Should -Be 10000
            Get-MigHashBufferSize -Length 10485760 -BufferBytes 65536 | Should -Be 65536
            Get-MigHashBufferSize -Length 10485760 -BufferBytes 0 | Should -Be 4096
            Get-MigHashBufferSize -Length 5GB -BufferBytes 1048576 | Should -Be 1048576
        }
    }

    It 'the scan worker inlines the same formula' {
        InModuleScope NotificationMigration {
            $script:MigScanWorker.ToString() | Should -Match ([regex]::Escape('[Math]::Max([long]4096, [Math]::Min([long]$fsi.Length, [long]$A.BufferBytes))'))
        }
    }

    It 'defaults inventory.hash.bufferSizeKB to 64' {
        $d = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../../NotificationMigration/config/defaults.json') | ConvertFrom-Json
        $d.inventory.hash.bufferSizeKB | Should -Be 64
    }

    It 'hashes small, buffer-sized and multi-buffer files correctly' {
        $root = Join-Path $TestDrive 'hash'
        $src = Join-Path $root 'src'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $rnd = New-Object System.Random 7
        foreach ($size in @(0, 1, 4095, 4097, 65536, 200001)) {
            $b = New-Object byte[] $size; $rnd.NextBytes($b)
            [IO.File]::WriteAllBytes((Join-Path $src "f$size.bin"), $b)
        }
        $cfg = @{
            paths     = @{ sourceRoot = $src; targetRoot = (Join-Path $root 'tgt'); workDir = (Join-Path $root 'work') }
            inventory = @{ aclReader = 'none'; threads = 2; chunkSize = 2; hash = @{ bufferSizeKB = 64 } }
            compare   = @{ fileFields = @('exists', 'size', 'hash', 'modified') }
            copy      = @{ engine = 'dotnet' }
        }
        $cfgPath = Join-Path $root 'migration.config.json'
        [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 10))
        InModuleScope NotificationMigration -Parameters @{ cfg = $cfgPath; src = $src } {
            param($cfg, $src)
            $ctx = New-MigContext -ConfigPath $cfg -Operator 'maker'
            try {
                $recs = @(Get-MigScanRecords -Ctx $ctx -Side source -Entries @(Get-MigTreeEntries -Root $src -UseLongPath $false))
                $recs.Count | Should -Be 6
                foreach ($r in $recs) {
                    $r['error'] | Should -BeNullOrEmpty
                    $r['hash'] | Should -Be (Get-FileHash -LiteralPath (Join-Path $src $r['rel_path']) -Algorithm SHA256).Hash
                }
            } finally { Close-MigContext -Ctx $ctx }
        }
    }
}
