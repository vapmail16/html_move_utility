#Requires -Modules Pester
# Unit tests for Core/Safety.ps1: canonical rel_paths, joins, long-path prefix, path containment and the
# copy-only guards (C-02).

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
    $script:mod = Get-Module NotificationMigration
    $script:sep = [System.IO.Path]::DirectorySeparatorChar
    function M { param([scriptblock] $Block, [object[]] $A = @()) & $script:mod $Block @A }
}

Describe 'rel_path helpers' {
    It 'canonicalises separators and strips the leading separator' {
        M { ConvertTo-MigCanonicalRelPath '/2019/01/a.html' } | Should -Be '2019\01\a.html'
        M { ConvertTo-MigCanonicalRelPath '\\2019\01' } | Should -Be '2019\01'
        M { ConvertTo-MigCanonicalRelPath '' } | Should -Be ''
    }
    It 'Join-MigPath builds a native path and tolerates a trailing separator on the root' {
        $root = Join-Path $TestDrive 'r'
        M { param($r) Join-MigPath -Root $r -RelPath '2019\01\café 通知.html' } @($root) | Should -Be (Join-Path $root "2019$($script:sep)01$($script:sep)café 通知.html")
        M { param($r) Join-MigPath -Root ($r + [System.IO.Path]::DirectorySeparatorChar) -RelPath 'a' } @($root) | Should -Be (Join-Path $root 'a')
        M { param($r) Join-MigPath -Root $r -RelPath '' } @($root) | Should -Be $root
    }
    It 'Get-MigRelativePath returns a canonical rel_path and refuses paths outside the root' {
        $root = Join-Path $TestDrive 'r'
        M { param($r) Get-MigRelativePath -Root $r -FullPath (Join-Path (Join-Path $r '2019') 'a.html') } @($root) | Should -Be '2019\a.html'
        { M { param($r) Get-MigRelativePath -Root $r -FullPath '/elsewhere/a.html' } @($root) } | Should -Throw '*not under root*'
    }
}

Describe 'long-path prefix' {
    It 'adds \\?\ (and \\?\UNC\) only on Windows and only when enabled' {
        if ((M { Test-MigIsWindows })) {
            M { Get-MigLongPath -Path 'C:\x' } | Should -Be '\\?\C:\x'
            M { Get-MigLongPath -Path '\\srv\share\x' } | Should -Be '\\?\UNC\srv\share\x'
            M { Get-MigLongPath -Path '\\?\C:\x' } | Should -Be '\\?\C:\x'
        } else {
            M { Get-MigLongPath -Path '/x/y' } | Should -Be '/x/y'
        }
        M { Get-MigLongPath -Path 'C:\x' -Enabled $false } | Should -Be 'C:\x'
    }
    It 'Remove-MigLongPathPrefix undoes both prefix forms' {
        M { Remove-MigLongPathPrefix '\\?\UNC\srv\share\x' } | Should -Be '\\srv\share\x'
        M { Remove-MigLongPathPrefix '\\?\C:\x' } | Should -Be 'C:\x'
        M { Remove-MigLongPathPrefix 'C:\x' } | Should -Be 'C:\x'
    }
}

Describe 'Test-MigPathUnder' {
    BeforeAll { $script:src = Join-Path $TestDrive 'src' }

    It 'is true for the root itself and anything inside it' {
        M { param($s) Test-MigPathUnder -Path $s -Root $s } @($script:src) | Should -BeTrue
        M { param($s) Test-MigPathUnder -Path (Join-Path $s 'a/b') -Root $s } @($script:src) | Should -BeTrue
    }
    It 'ignores case, trailing separators and separator style' {
        M { param($s) Test-MigPathUnder -Path ($s.ToUpperInvariant() + '/x') -Root ($s + [System.IO.Path]::DirectorySeparatorChar) } @($script:src) | Should -BeTrue
        M { param($s) Test-MigPathUnder -Path ($s.Replace([System.IO.Path]::DirectorySeparatorChar, '\') + '\x') -Root $s } @($script:src) | Should -BeTrue
    }
    It 'is false for a sibling sharing a name prefix' {
        M { param($s) Test-MigPathUnder -Path ($s + '2') -Root $s } @($script:src) | Should -BeFalse
        M { param($s) Test-MigPathUnder -Path ($s + '-copy/x') -Root $s } @($script:src) | Should -BeFalse
    }
    It "collapses '..' segments (no escape and no false negative)" {
        M { param($s) Test-MigPathUnder -Path (Join-Path $s '../tgt') -Root $s } @($script:src) | Should -BeFalse
        M { param($s) Test-MigPathUnder -Path (Join-Path $s '../src/x') -Root $s } @($script:src) | Should -BeTrue
    }
    It 'resolves relative paths against the PowerShell location' {
        Push-Location $TestDrive
        try {
            M { param($s) Test-MigPathUnder -Path 'src/x' -Root $s } @($script:src) | Should -BeTrue
            M { param($s) Test-MigPathUnder -Path './other' -Root $s } @($script:src) | Should -BeFalse
        } finally { Pop-Location }
    }
    It 'ignores a long-path prefix (Windows)' -Skip:(-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')) {
        M { Test-MigPathUnder -Path '\\?\C:\data\src\x' -Root 'C:\data\src' } | Should -BeTrue
    }
}

Describe 'Assert-MigPathNotUnderSource' {
    It 'throws SAFETY for any write path inside sourceRoot' {
        $src = Join-Path $TestDrive 'src'
        { M { param($s) Assert-MigPathNotUnderSource -Path (Join-Path $s 'store') -SourceRoot $s } @($src) } | Should -Throw 'SAFETY:*'
        { M { param($s) Assert-MigPathNotUnderSource -Path $s -SourceRoot $s } @($src) } | Should -Throw 'SAFETY:*'
    }
    It 'allows paths outside sourceRoot' {
        $src = Join-Path $TestDrive 'src'
        { M { param($s) Assert-MigPathNotUnderSource -Path (Join-Path $TestDrive 'work') -SourceRoot $s } @($src) } | Should -Not -Throw
    }
    It 'guards New-MigContext: a store under sourceRoot is refused before anything is written' {
        $root = Join-Path $TestDrive 'ctx'
        $src = Join-Path $root 'src'; $tgt = Join-Path $root 'tgt'; $work = Join-Path $root 'work'
        foreach ($d in @($src, $tgt, $work)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $p = Join-Path $root 'c.json'
        [System.IO.File]::WriteAllText($p, (@{ paths = @{ sourceRoot = $src; targetRoot = $tgt; workDir = $work; storeDir = (Join-Path $src 'store') }; inventory = @{ aclReader = 'none' } } | ConvertTo-Json -Depth 5))
        { M { param($x) New-MigContext -ConfigPath $x } @($p) } | Should -Throw
        Test-Path -LiteralPath (Join-Path $src 'store') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $src -Force).Count | Should -Be 0
    }
}

Describe 'Assert-MigCopyFlagsSafe' {
    It 'rejects <flag>' -ForEach @(@{ flag = '/MIR' }, @{ flag = '/mov' }, @{ flag = '/MOVE' }, @{ flag = '/PURGE' }, @{ flag = '/Purge:x' }) {
        { M { param($f) Assert-MigCopyFlagsSafe -Flags @('/COPY:DAT', $f) -ForbiddenFlags @() } @($flag) } | Should -Throw 'SAFETY*'
    }
    It 'rejects configured extra flags and allows safe ones' {
        { M { Assert-MigCopyFlagsSafe -Flags @('/CREATE') -ForbiddenFlags @('/CREATE') } } | Should -Throw 'SAFETY*'
        { M { Assert-MigCopyFlagsSafe -Flags @('/COPY:DATSO', '/DCOPY:T', '/R:3', '/W:5') -ForbiddenFlags @('/CREATE') } } | Should -Not -Throw
    }
    It 'does not confuse /MOT or /MINAGE with /MOV or /MIR' {
        { M { Assert-MigCopyFlagsSafe -Flags @('/MOT:5', '/MINAGE:1', '/MAXAGE:9') -ForbiddenFlags @() } } | Should -Not -Throw
    }
}
