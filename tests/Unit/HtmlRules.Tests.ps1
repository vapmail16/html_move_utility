#Requires -Modules Pester
# Unit tests for Providers/HtmlRule/*.ps1 (each rule, called directly through the provider registry).

BeforeAll {
    Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
    $script:mod = Get-Module NotificationMigration

    function New-TestContext {
        param([string] $Root, [hashtable] $Override = @{})
        $src = Join-Path $Root 'src'; $tgt = Join-Path $Root 'tgt'; $work = Join-Path $Root 'work'
        foreach ($d in @($src, $tgt, $work)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $cfg = @{
            paths     = @{ sourceRoot = $src; targetRoot = $tgt; workDir = $work }
            inventory = @{ aclReader = 'none'; threads = 2 }
            compare   = @{ fileFields = @('exists', 'size', 'hash', 'modified'); dirFields = @('exists') }
            copy      = @{ engine = 'dotnet' }
            htmlChecks = @{ rules = @{ absoluteLinks = @{ oldHosts = @('ServerA', 'servera.corp.local'); oldUncPrefixes = @('\\ServerA\Notifications'); oldIpAddresses = @('10.1.2.3') } } }
        }
        $path = Join-Path $Root 'migration.config.json'
        [System.IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json -Depth 10))
        return (& $script:mod { param($p, $o) New-MigContext -ConfigPath $p -Override $o -Operator 'maker' } $path $Override)
    }

    function Invoke-Rule {
        param([string] $Name, $Ctx, [string] $Root, [object[]] $Records, $Options = $null, [string] $Side = 'source', [string] $BatchId = 'B1')
        & $script:mod {
            param($n, $c, $r, $recs, $o, $s, $b)
            if ($null -eq $o) { $o = $c.Config.htmlChecks.rules[$n] }
            $sb = Get-MigProvider -Kind HtmlRule -Name $n
            @(& $sb $c $b $s $r $recs $o)
        } $Name $Ctx $Root $Records $Options $Side $BatchId
    }

    function New-Rec {
        param([string] $RelPath, [string] $Kind = 'file', $Size = 10)
        @{ rel_path = $RelPath; kind = $Kind; size_bytes = $Size }
    }

    function Write-Bytes { param([string] $Path, [byte[]] $Bytes)
        New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($Path, $Bytes)
    }
    function Write-Text { param([string] $Path, [string] $Text, $Encoding = (New-Object System.Text.UTF8Encoding($false)))
        New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
        [System.IO.File]::WriteAllText($Path, $Text, $Encoding)
    }
}

Describe 'HtmlRule registration' {
    It 'registers every config rule key as an HtmlRule provider' {
        $names = & $script:mod { Get-MigProviderNames -Kind HtmlRule }
        foreach ($n in @('longPath', 'fileName', 'linkedAssets', 'absoluteLinks', 'zeroByte', 'malformed', 'renderSample')) { $names | Should -Contain $n }
    }
}

Describe 'Read-MigHtmlText encoding detection' {
    BeforeAll { $script:d = Join-Path $TestDrive 'enc'; New-Item -ItemType Directory -Path $script:d -Force | Out-Null }

    It 'decodes UTF-16 LE with BOM' {
        $p = Join-Path $script:d 'u16.html'
        Write-Text $p '<html>caf&eacute; é 通知</html>' (New-Object System.Text.UnicodeEncoding($false, $true))
        $r = & $script:mod { param($p) Read-MigHtmlText -Path $p } $p
        $r.ok | Should -BeTrue
        $r.encoding | Should -Be 'utf-16le-bom'
        $r.binary | Should -BeFalse
        $r.text | Should -Be '<html>caf&eacute; é 通知</html>'
    }
    It 'decodes UTF-16 BE and UTF-8 with BOM' {
        $p1 = Join-Path $script:d 'u16be.html'; Write-Text $p1 '<html>x</html>' (New-Object System.Text.UnicodeEncoding($true, $true))
        $p2 = Join-Path $script:d 'u8bom.html'; Write-Text $p2 '<html>é</html>' (New-Object System.Text.UTF8Encoding($true))
        (& $script:mod { param($p) Read-MigHtmlText -Path $p } $p1).encoding | Should -Be 'utf-16be-bom'
        $r2 = & $script:mod { param($p) Read-MigHtmlText -Path $p } $p2
        $r2.encoding | Should -Be 'utf-8-bom'
        $r2.text | Should -Be '<html>é</html>'
    }
    It 'falls back to the ANSI code page for invalid UTF-8' {
        $p = Join-Path $script:d 'ansi.html'
        Write-Bytes $p ([byte[]](@([System.Text.Encoding]::ASCII.GetBytes('<html>caf')) + @(0xE9) + @([System.Text.Encoding]::ASCII.GetBytes('</html>'))))
        $r = & $script:mod { param($p) Read-MigHtmlText -Path $p } $p
        $r.ok | Should -BeTrue
        $r.encoding | Should -Match '^ansi-'
        $r.text | Should -Be '<html>café</html>'
    }
    It 'flags NUL bytes as binary and honours MaxBytes' {
        $p = Join-Path $script:d 'bin.html'
        Write-Bytes $p ([byte[]]@(60, 104, 0, 0, 1, 2, 62))
        (& $script:mod { param($p) Read-MigHtmlText -Path $p } $p).binary | Should -BeTrue
        (& $script:mod { param($p) Read-MigHtmlText -Path $p -MaxBytes 3 } $p).too_large | Should -BeTrue
    }
    It 'returns an error for a missing file without throwing' {
        $r = & $script:mod { param($p) Read-MigHtmlText -Path $p } (Join-Path $script:d 'nope.html')
        $r.ok | Should -BeFalse
        $r.error | Should -Not -BeNullOrEmpty
    }
}

Describe 'longPath rule' {
    BeforeAll { $script:ctx = New-TestContext -Root (Join-Path $TestDrive 'lp') }
    AfterAll { & $script:mod { param($c) Close-MigContext -Ctx $c } $script:ctx }

    It 'flags paths longer than maxLength on this side, rel_path length in detail, compared for parity' {
        $root = $script:ctx.Config.paths.sourceRoot
        $short = 'a\b.html'
        $long = ('x' * 40) + '\' + ('y' * 40) + '.html'
        $max = $root.Length + 1 + 30
        $f = Invoke-Rule -Name longPath -Ctx $script:ctx -Root $root -Records @((New-Rec $short), (New-Rec $long), (New-Rec ('x' * 40) 'dir')) -Options @{ enabled = $true; maxLength = $max }
        $f.Count | Should -Be 2
        $l = $f | Where-Object { $_.rel_path -eq $long }
        $l.side_specific | Should -BeFalse
        $l.detail | Should -Match "rel_path length $($long.Length)"
        $l.parity_key | Should -Be ('longPath|path_too_long|' + $long + '|').ToLowerInvariant()
        @($f | Where-Object { $_.rel_path -eq $short }).Count | Should -Be 0
    }
    It 'depends on the root length; too long on both sides gives the same parity key' {
        $rel = 'a\' + ('z' * 20) + '.html'
        $max = 60
        $a = Invoke-Rule -Name longPath -Ctx $script:ctx -Root ('/' + ('r' * 10)) -Records @((New-Rec $rel)) -Options @{ maxLength = $max }
        $b = Invoke-Rule -Name longPath -Ctx $script:ctx -Root ('/' + ('r' * 40)) -Records @((New-Rec $rel)) -Options @{ maxLength = $max }
        $c = Invoke-Rule -Name longPath -Ctx $script:ctx -Root ('/' + ('r' * 50)) -Records @((New-Rec $rel)) -Options @{ maxLength = $max }
        $a.Count | Should -Be 0
        $b.Count | Should -Be 1
        $b[0].parity_key | Should -Be $c[0].parity_key
        $b[0].detail | Should -Not -Be $c[0].detail
    }
}

Describe 'zeroByte rule' {
    BeforeAll { $script:ctx = New-TestContext -Root (Join-Path $TestDrive 'zb') }
    AfterAll { & $script:mod { param($c) Close-MigContext -Ctx $c } $script:ctx }

    It 'reports only files of size 0' {
        $f = Invoke-Rule -Name zeroByte -Ctx $script:ctx -Root '/x' -Records @((New-Rec 'a.html' 'file' 0), (New-Rec 'b.css' 'file' 0), (New-Rec 'c.html' 'file' 5), (New-Rec 'd' 'dir' $null))
        @($f.rel_path) | Should -Be @('a.html', 'b.css')
        $f[0].code | Should -Be 'zero_byte'
    }
}

Describe 'fileName rule' {
    BeforeAll { $script:ctx = New-TestContext -Root (Join-Path $TestDrive 'fn') }
    AfterAll { & $script:mod { param($c) Close-MigContext -Ctx $c } $script:ctx }

    It 'flags non-ASCII (Unicode) names' {
        $f = Invoke-Rule -Name fileName -Ctx $script:ctx -Root '/none' -Records @((New-Rec '2019\01\café 通知.html'), (New-Rec '2019\01\plain.html'))
        $n = @($f | Where-Object { $_.code -eq 'non_ascii' })
        $n.Count | Should -Be 1
        $n[0].rel_path | Should -Be '2019\01\café 通知.html'
        $n[0].detail | Should -Match 'U\+00E9'
    }
    It 'flags trailing dot/space and configured invalid characters' {
        $f = Invoke-Rule -Name fileName -Ctx $script:ctx -Root '/none' -Records @((New-Rec 'a\x.html.'), (New-Rec 'a\y.html '), (New-Rec 'a\q?.html'), (New-Rec 'a\ok.html'))
        @($f | Where-Object { $_.code -eq 'trailing_dot_space' }).rel_path | Should -Be @('a\x.html.', 'a\y.html ')
        $inv = @($f | Where-Object { $_.code -eq 'invalid_chars' })
        $inv.Count | Should -Be 1
        $inv[0].rel_path | Should -Be 'a\q?.html'
    }
    It 'uses invalidChars from config only' {
        $f = Invoke-Rule -Name fileName -Ctx $script:ctx -Root '/none' -Records @((New-Rec 'a\q?.html'), (New-Rec 'a\h#.html')) -Options @{ invalidChars = '#' }
        @($f | Where-Object { $_.code -eq 'invalid_chars' }).rel_path | Should -Be @('a\h#.html')
    }
    It 'flags case-only duplicates within the same folder, not across folders' {
        $recs = @((New-Rec '2019\A.html'), (New-Rec '2019\a.html'), (New-Rec '2020\a.html'), (New-Rec '2019\b.html'))
        $f = @(Invoke-Rule -Name fileName -Ctx $script:ctx -Root '/none' -Records $recs | Where-Object { $_.code -eq 'case_duplicate' })
        @($f.rel_path | Sort-Object) | Should -Be @('2019\a.html', '2019\A.html')
        $f[0].detail | Should -Match 'case-only duplicate'
    }
    It 'honours the flags being switched off' {
        $recs = @((New-Rec 'x\é.html'), (New-Rec 'x\E.html'), (New-Rec 'x\e.html'), (New-Rec 'x\t.'), (New-Rec ('x\a' + [char]7 + '.html')), (New-Rec 'x\ lead.html'), (New-Rec 'x\a&b.html'), (New-Rec 'x\CON.html'))
        $f = Invoke-Rule -Name fileName -Ctx $script:ctx -Root '/none' -Records $recs -Options @{ flagNonAscii = $false; flagTrailingDotSpace = $false; flagCaseDuplicates = $false; invalidChars = ''; specialChars = ''; flagControlChars = $false; flagLeadingSpace = $false; reservedNames = @() }
        $f.Count | Should -Be 0
    }
    It 'flags NTFS-legal special characters from specialChars (defaults), with the characters in detail' {
        $recs = @((New-Rec 'a\R&D #1.html'), (New-Rec 'a\x[1].html'), (New-Rec "a\it's.html"), (New-Rec 'a\back`tick.html'), (New-Rec 'a\caret^.html'), (New-Rec 'a\plain-name_1.html'))
        $all = Invoke-Rule -Name fileName -Ctx $script:ctx -Root '/none' -Records $recs; $f = @($all | Where-Object { $_.code -eq 'special_chars' })
        @($f.rel_path) | Should -Be @('a\R&D #1.html', 'a\x[1].html', "a\it's.html", 'a\back`tick.html', 'a\caret^.html')
        ($f | Where-Object { $_.rel_path -eq 'a\R&D #1.html' }).detail | Should -Match '& #'
        ($f | Where-Object { $_.rel_path -eq 'a\x[1].html' }).detail | Should -Match '\[ \]'
        $f[0].severity | Should -Be 'warning'
    }
    It 'treats regex metacharacters in specialChars literally' {
        $all = Invoke-Rule -Name fileName -Ctx $script:ctx -Root '/none' -Records @((New-Rec 'a\x-y.html'), (New-Rec 'a\x\y.html'), (New-Rec 'a\x].html')) -Options @{ specialChars = ']^-\' }; $f = @($all | Where-Object { $_.code -eq 'special_chars' })
        @($f.rel_path) | Should -Be @('a\x-y.html', 'a\x].html')
    }
    It 'flags control characters and a leading space' {
        $ctl = 'a\bell' + [char]7 + 'x' + [char]0x1F + '.html'
        $f = Invoke-Rule -Name fileName -Ctx $script:ctx -Root '/none' -Records @((New-Rec $ctl), (New-Rec 'a\ lead.html'), (New-Rec 'a\mid dle.html'))
        $c = @($f | Where-Object { $_.code -eq 'control_chars' })
        $c.Count | Should -Be 1
        $c[0].detail | Should -Match 'U\+0007 U\+001F'
        $c[0].severity | Should -Be 'error'
        @($f | Where-Object { $_.code -eq 'leading_space' }).rel_path | Should -Be @('a\ lead.html')
    }
    It 'flags reserved device names with or without extension, case-insensitively, not as substrings' {
        $recs = @((New-Rec 'a\CON'), (New-Rec 'a\con.html'), (New-Rec 'a\Com1.tar.gz'), (New-Rec 'a\lpt9.txt'), (New-Rec 'a\nul' 'dir'),
                  (New-Rec 'a\CONSOLE.html'), (New-Rec 'a\com10.html'), (New-Rec 'a\icon.html'), (New-Rec 'a\LPT.html'))
        $all = Invoke-Rule -Name fileName -Ctx $script:ctx -Root '/none' -Records $recs; $f = @($all | Where-Object { $_.code -eq 'reserved_name' })
        @($f.rel_path) | Should -Be @('a\CON', 'a\con.html', 'a\Com1.tar.gz', 'a\lpt9.txt', 'a\nul')
        $f[0].severity | Should -Be 'error'
    }
    It 'defaults find issues in names that can exist on NTFS (not only invalidChars)' {
        $o = $script:ctx.Config.htmlChecks.rules.fileName
        $o.specialChars | Should -Not -BeNullOrEmpty
        $o.flagControlChars | Should -BeTrue
        $o.flagLeadingSpace | Should -BeTrue
        @($o.reservedNames) | Should -Contain 'COM9'
        @($o.reservedNames) | Should -Contain 'LPT1'
    }
}

Describe 'content rules on files' {
    BeforeAll {
        $script:ctx = New-TestContext -Root (Join-Path $TestDrive 'content')
        $script:root = $script:ctx.Config.paths.sourceRoot
        $r = $script:root
        Write-Text (Join-Path $r '2019/01/img/logo.png') 'png'
        Write-Text (Join-Path $r '2019/01/css/site.css') 'body{}'
        Write-Text (Join-Path $r '2019/01/a.html') @'
<html><head><link rel="stylesheet" href="css/site.css"><link href="css/missing.css" rel="stylesheet"></head>
<body>
<img src="img/logo.png" data-src="img/not-checked.png"><img src='img/Logo.PNG?v=2#x'>
<a href="#top">top</a><a href="mailto:a@b.c">m</a><a href="https://example.com/x.png">ext</a><a href="javascript:void(0)">j</a>
<a href="missing%20page.html">gone</a><a href=b.html>b</a>
<a href="http://ServerA/notifications/x.html">old</a> <img src="\\ServerA\Notifications\img\y.png">
<a href="file://servera/notifications/z.html">f</a> <a href="http://10.1.2.3/p">ip</a> <a href="http://10.1.2.30/p">other ip</a>
<a href="http://servera.corp.local/q">fqdn</a> <a href="http://serveraa/q">not old</a>
Contact the ServerA team.
<!-- <img src="img/commented-out.png"> -->
<script>var s = "<img src='img/in-script.png'>";</script>
<a href="../../../../escape.html">up</a>
</body></html>
'@
        Write-Text (Join-Path $r '2019/01/b.html') '<html><body><img src="../01/img/logo.png"><img src="nope.gif"><a href="http://ServerA/u16">x</a></body></html>' (New-Object System.Text.UnicodeEncoding($false, $true))
        Write-Text (Join-Path $r '2019/01/café 通知.html') '<html><body><img src="img/logo.png"></body></html>'
        Write-Bytes (Join-Path $r '2019/01/empty.html') ([byte[]]@())
        Write-Text (Join-Path $r '2019/01/noroot.html') '<div>no html tag</div>'
        Write-Bytes (Join-Path $r '2019/01/bin.html') ([byte[]]@(60, 104, 116, 109, 108, 62, 0, 0, 0, 1))
        Write-Text (Join-Path $r '2019/01/big.html') ('<html>' + ('x' * 5000) + '</html>')
        Write-Text (Join-Path $r '2019/01/notes.txt') '<a href="missing.txt">'

        $script:recs = @(
            (New-Rec '2019\01\img\logo.png'), (New-Rec '2019\01\css\site.css'), (New-Rec '2019\01\a.html'), (New-Rec '2019\01\b.html'),
            (New-Rec '2019\01\café 通知.html'), (New-Rec '2019\01\empty.html' 'file' 0), (New-Rec '2019\01\noroot.html'),
            (New-Rec '2019\01\bin.html'), (New-Rec '2019\01\big.html'), (New-Rec '2019\01\notes.txt'), (New-Rec '2019\01\gone.html'),
            (New-Rec '2019\01\img' 'dir'), @{ rel_path = '2019\02'; kind = 'error'; error = 'denied' }
        )
    }
    AfterAll { & $script:mod { param($c) Close-MigContext -Ctx $c } $script:ctx }

    Context 'linkedAssets' {
        BeforeAll { $script:la = Invoke-Rule -Name linkedAssets -Ctx $script:ctx -Root $script:root -Records $script:recs }

        It 'reports missing relative assets and pages (URL-decoded, query/fragment stripped)' {
            $a = @($script:la | Where-Object { $_.rel_path -eq '2019\01\a.html' -and $_.code -eq 'missing_asset' })
            $a.detail -join "`n" | Should -Match "2019\\01\\css\\missing.css"
            $a.detail -join "`n" | Should -Match "2019\\01\\missing page.html"
            $a.Count | Should -Be 2
        }
        It 'ignores anchors, configured schemes, absolute URLs, data-* attributes, comments and script bodies' {
            $txt = ($script:la | ForEach-Object { $_.detail }) -join "`n"
            $txt | Should -Not -Match 'not-checked|commented-out|in-script|example.com|mailto|javascript|ServerA'
        }
        It 'resolves existing assets case-insensitively and with ../' {
            $txt = ($script:la | ForEach-Object { $_.detail }) -join "`n"
            $txt | Should -Not -Match 'logo'
            $txt | Should -Not -Match 'site.css'
        }
        It 'reads UTF-16 files (BOM) and Unicode-named files' {
            $b = @($script:la | Where-Object { $_.rel_path -eq '2019\01\b.html' })
            $b.Count | Should -Be 1
            $b[0].detail | Should -Match 'nope.gif'
            @($script:la | Where-Object { $_.rel_path -eq '2019\01\café 通知.html' }).Count | Should -Be 0
        }
        It 'reports references above the root as outside_root' {
            @($script:la | Where-Object { $_.code -eq 'outside_root' }).Count | Should -Be 1
        }
        It 'only parses configured extensions and uses rel_paths only (no roots)' {
            @($script:la | Where-Object { $_.rel_path -like '*.txt' }).Count | Should -Be 0
            foreach ($f in $script:la) { $f.detail | Should -Not -Match ([regex]::Escape($script:root)); $f.parity_key | Should -Not -Match ([regex]::Escape($script:root.ToLowerInvariant())) }
        }
        It 'checks existence on THIS side (target without the asset)' {
            $tgt = $script:ctx.Config.paths.targetRoot
            Write-Text (Join-Path $tgt '2019/01/c.html') '<html><img src="img/logo.png"></html>'
            $f = Invoke-Rule -Name linkedAssets -Ctx $script:ctx -Root $tgt -Side target -Records @((New-Rec '2019\01\c.html'))
            $f.Count | Should -Be 1
            $f[0].detail | Should -Match 'logo.png'
        }
    }

    Context 'absoluteLinks' {
        BeforeAll { $script:al = Invoke-Rule -Name absoluteLinks -Ctx $script:ctx -Root $script:root -Records $script:recs }

        It 'reports configured old hosts, UNC prefixes (both slash forms) and IPs case-insensitively' {
            $a = @($script:al | Where-Object { $_.rel_path -eq '2019\01\a.html' })
            $d = $a.detail -join "`n"
            $d | Should -Match 'http://ServerA/notifications/x.html'
            $d | Should -Match ([regex]::Escape('\\ServerA\Notifications\img\y.png'))
            $d | Should -Match 'file://servera/notifications/z.html'
            $d | Should -Match 'http://10.1.2.3/p'
            $d | Should -Match 'http://servera.corp.local/q'
            @($a | Where-Object { $_.code -eq 'old_unc' }).Count | Should -BeGreaterThan 1
        }
        It 'does not report other hosts/IPs or plain-text mentions' {
            $d = ($script:al | ForEach-Object { $_.detail }) -join "`n"
            $d | Should -Not -Match 'serveraa'
            $d | Should -Not -Match '10\.1\.2\.30'
            $d | Should -Not -Match 'team'
        }
        It 'finds links in UTF-16 files' {
            @($script:al | Where-Object { $_.rel_path -eq '2019\01\b.html' }).Count | Should -Be 1
        }
        It 'uses only the configured lists (nothing when lists are empty)' {
            $f = Invoke-Rule -Name absoluteLinks -Ctx $script:ctx -Root $script:root -Records $script:recs -Options @{ enabled = $true; oldHosts = @(); oldUncPrefixes = @(); oldIpAddresses = @() }
            $f.Count | Should -Be 0
            $f2 = Invoke-Rule -Name absoluteLinks -Ctx $script:ctx -Root $script:root -Records $script:recs -Options @{ oldHosts = @('example.com') }
            @($f2 | Where-Object { $_.detail -match 'example.com' }).Count | Should -Be 1
        }
        It 'never modifies the file (report only)' {
            $p = Join-Path $script:root '2019/01/a.html'
            $before = (Get-FileHash -LiteralPath $p).Hash
            $null = Invoke-Rule -Name absoluteLinks -Ctx $script:ctx -Root $script:root -Records $script:recs
            (Get-FileHash -LiteralPath $p).Hash | Should -Be $before
        }
    }

    Context 'malformed' {
        BeforeAll { $script:mf = Invoke-Rule -Name malformed -Ctx $script:ctx -Root $script:root -Records $script:recs -Options @{ enabled = $true; requireTags = @('html'); maxBytesToParse = 4000 } }

        It 'reports missing required tags, empty, binary, unreadable and skipped_large' {
            ($script:mf | Where-Object { $_.rel_path -eq '2019\01\noroot.html' }).code | Should -Be 'missing_tag'
            ($script:mf | Where-Object { $_.rel_path -eq '2019\01\empty.html' }).code | Should -Be 'empty'
            ($script:mf | Where-Object { $_.rel_path -eq '2019\01\bin.html' }).code | Should -Be 'binary'
            ($script:mf | Where-Object { $_.rel_path -eq '2019\01\gone.html' }).code | Should -Be 'unreadable'
            ($script:mf | Where-Object { $_.rel_path -eq '2019\01\big.html' }).code | Should -Be 'skipped_large'
            ($script:mf | Where-Object { $_.rel_path -eq '2019\01\big.html' }).severity | Should -Be 'warning'
        }
        It 'accepts valid UTF-8, UTF-16 and Unicode-named HTML' {
            @($script:mf | Where-Object { @('2019\01\a.html', '2019\01\b.html', '2019\01\café 通知.html') -contains $_.rel_path }).Count | Should -Be 0
        }
        It 'skips non-HTML files' {
            @($script:mf | Where-Object { $_.rel_path -like '*.txt' -or $_.rel_path -like '*.png' }).Count | Should -Be 0
        }
    }

    Context 'skipped_large for every content rule' {
        It '<name> reports big.html as skipped_large (warning) using its own maxBytesToParse' -ForEach @(
            @{ name = 'linkedAssets'; opt = @{ attributes = @('src', 'href'); ignoreSchemes = @('http'); maxBytesToParse = 4000 } }
            @{ name = 'absoluteLinks'; opt = @{ oldHosts = @('ServerA'); maxBytesToParse = 4000 } }
            @{ name = 'malformed'; opt = @{ requireTags = @('html'); maxBytesToParse = 4000 } }
        ) {
            $all = Invoke-Rule -Name $name -Ctx $script:ctx -Root $script:root -Records $script:recs -Options $opt; $f = @($all | Where-Object { $_.code -eq 'skipped_large' })
            $f.Count | Should -Be 1
            $f[0].rel_path | Should -Be '2019\01\big.html'
            $f[0].severity | Should -Be 'warning'
            $f[0].rule | Should -Be $name
        }
        It 'linkedAssets and absoluteLinks fall back to malformed.maxBytesToParse when their own is not set' {
            $ctx2 = New-TestContext -Root (Join-Path $TestDrive 'fallback') -Override @{ htmlChecks = @{ rules = @{ malformed = @{ maxBytesToParse = 4000 } } } }
            try {
                $ctx2.Config.htmlChecks.rules.linkedAssets['maxBytesToParse'] | Should -BeNullOrEmpty
                foreach ($n in @('linkedAssets', 'absoluteLinks')) {
                    $all = Invoke-Rule -Name $n -Ctx $ctx2 -Root $script:root -Records $script:recs; $f = @($all | Where-Object { $_.code -eq 'skipped_large' })
                    @($f.rel_path) | Should -Be @('2019\01\big.html')
                }
            } finally { & $script:mod { param($c) Close-MigContext -Ctx $c } $ctx2 }
        }
    }

    Context 'shared read cache' {
        It 'reads each HTML file once for all content rules that share a cache' {
            $res = & $script:mod {
                param($c, $root, $recs)
                $cache = New-MigHtmlTextCache -MaxBytes 0
                foreach ($n in @('malformed', 'linkedAssets', 'absoluteLinks', 'renderSample')) {
                    $o = @{}; foreach ($k in $c.Config.htmlChecks.rules[$n].Keys) { $o[$k] = $c.Config.htmlChecks.rules[$n][$k] }
                    $o['_htmlCache'] = $cache
                    if ($n -eq 'renderSample') { $o['rate'] = 1 }
                    $null = & (Get-MigProvider -Kind HtmlRule -Name $n) $c 'B1' 'source' $root $recs $o
                }
                @{ reads = $cache.reads; items = $cache.items.Count }
            } $script:ctx $script:root $script:recs
            $res.items | Should -Be 8
            $res.reads | Should -Be 8
        }
        It 'applies each rule''s own limit to a cached read' {
            $res = & $script:mod {
                param($c, $root)
                $cache = New-MigHtmlTextCache -MaxBytes 0
                $a = Get-MigHtmlContent -Ctx $c -Root $root -RelPath '2019\01\big.html' -MaxBytes 0 -Options @{ _htmlCache = $cache }
                $b = Get-MigHtmlContent -Ctx $c -Root $root -RelPath '2019\01\big.html' -MaxBytes 100 -Options @{ _htmlCache = $cache }
                @{ a = $a.too_large; b = $b.too_large; reads = $cache.reads }
            } $script:ctx $script:root
            $res.a | Should -BeFalse
            $res.b | Should -BeTrue
            $res.reads | Should -Be 1
        }
    }

    Context 'linkedAssets CSS url() and srcset' {
        BeforeAll {
            $r = $script:root
            Write-Text (Join-Path $r '2019/03/img/ok.png') 'png'
            Write-Text (Join-Path $r '2019/03/img/ok-2x.png') 'png'
            Write-Text (Join-Path $r '2019/03/css.html') @'
<html><head><style>
/* body { background: url(img/commented.png) } */
body { background: url("img/ok.png") } .a { background-image: url('img/style-block-missing.png') }
.b { background: url(img/bare-missing.png) } .c { background: url(data:image/png;base64,AAAA) } .d { background: url(https://cdn/x.png) }
</style></head>
<body style="background: url(&quot;img/attr-missing.png&quot;)">
<div style="background-image:url(img/ok.png)"></div>
<img srcset="img/ok.png 1x, img/ok-2x.png 2x, img/srcset-missing.png 3x">
<img srcset="img/ok.png,img/nospace-missing.png 2x">
<picture><source srcset="data:image/png;base64,AA,BB 1x, img/pic-missing.webp"></picture>
<td background="img/bg-missing.gif"></td>
</body></html>
'@
            $script:cssRecs = @((New-Rec '2019\03\css.html'), (New-Rec '2019\03\img\ok.png'), (New-Rec '2019\03\img\ok-2x.png'))
        }
        It 'reports missing url() targets in <style> blocks and style attributes, ignoring comments, data: and absolute URLs' {
            $all = Invoke-Rule -Name linkedAssets -Ctx $script:ctx -Root $script:root -Records $script:cssRecs; $f = @($all | Where-Object { $_.code -eq 'missing_asset' })
            $d = $f.detail -join "`n"
            $d | Should -Match "style-block='img/style-block-missing.png'"
            $d | Should -Match "style-block='img/bare-missing.png'"
            $d | Should -Match "style='img/attr-missing.png'"
            $d | Should -Not -Match 'commented|cdn|data:'
            $d | Should -Not -Match ([regex]::Escape("img\ok.png'"))
            $d | Should -Not -Match ([regex]::Escape("img\ok-2x.png'"))
        }
        It 'reports missing srcset candidates (descriptors dropped, commas inside data: URLs kept)' {
            $all = Invoke-Rule -Name linkedAssets -Ctx $script:ctx -Root $script:root -Records $script:cssRecs; $f = @($all | Where-Object { $_.code -eq 'missing_asset' })
            $d = $f.detail -join "`n"
            $d | Should -Match "srcset='img/srcset-missing.png'"
            $d | Should -Match "srcset='img/pic-missing.webp'"
            $d | Should -Match "srcset='img/ok.png,img/nospace-missing.png'"
            $d | Should -Not -Match 'BB'
        }
        It 'checks the configured attributes list (background by default)' {
            $all = Invoke-Rule -Name linkedAssets -Ctx $script:ctx -Root $script:root -Records $script:cssRecs; $f = @($all | Where-Object { $_.code -eq 'missing_asset' })
            ($f.detail -join "`n") | Should -Match "background='img/bg-missing.gif'"
            $f.Count | Should -Be 7
        }
        It 'honours parseCssUrls = false and parseSrcset = false' {
            $f = Invoke-Rule -Name linkedAssets -Ctx $script:ctx -Root $script:root -Records $script:cssRecs -Options @{ attributes = @('src', 'href'); ignoreSchemes = @('http', 'https', 'data'); parseCssUrls = $false; parseSrcset = $false }
            $f.Count | Should -Be 0
        }
        It 'splits srcset like the HTML spec' {
            $u = & $script:mod { Get-MigSrcsetUrls ' a.png 1x,b.png 2x , c(1).png 100w, data:x/y;base64,A,B 3x,d.png' }
            @($u) | Should -Be @('a.png', 'b.png', 'c(1).png', 'data:x/y;base64,A,B', 'd.png')
        }
    }

    Context 'renderSample' {
        It 'samples deterministically: same rel_paths -> same sample, independent of order and side' {
            $opt = @{ enabled = $true; rate = 0.2; minPerBatch = 1; seed = 42; renderer = 'parse' }
            $a = Invoke-Rule -Name renderSample -Ctx $script:ctx -Root $script:root -Records $script:recs -Options $opt
            $rev = @($script:recs); [array]::Reverse($rev)
            $b = Invoke-Rule -Name renderSample -Ctx $script:ctx -Root $script:root -Records $rev -Options $opt -Side target
            $a.Count | Should -Be 2   # ceil(0.2 * 8 html files)
            @($a.rel_path) | Should -Be @($b.rel_path)
        }
        It 'uses minPerBatch, seed and batch id' {
            $opt = @{ rate = 0; minPerBatch = 3; seed = 1; renderer = 'parse' }
            $a = Invoke-Rule -Name renderSample -Ctx $script:ctx -Root $script:root -Records $script:recs -Options $opt
            $a.Count | Should -Be 3
            $all = Invoke-Rule -Name renderSample -Ctx $script:ctx -Root $script:root -Records $script:recs -Options @{ rate = 1; minPerBatch = 1; seed = 1; renderer = 'parse' }
            $all.Count | Should -Be 8
            $samples = foreach ($s in 1..6) { (@(Invoke-Rule -Name renderSample -Ctx $script:ctx -Root $script:root -Records $script:recs -Options @{ rate = 0; minPerBatch = 1; seed = $s; renderer = 'parse' }).rel_path) -join '|' }
            @($samples | Select-Object -Unique).Count | Should -BeGreaterThan 1
        }
        It 'parse renderer passes good HTML and fails binary/empty/missing files' {
            $all = Invoke-Rule -Name renderSample -Ctx $script:ctx -Root $script:root -Records $script:recs -Options @{ rate = 1; minPerBatch = 1; seed = 1; renderer = 'parse' }
            ($all | Where-Object { $_.rel_path -eq '2019\01\a.html' }).code | Should -Be 'render_ok'
            ($all | Where-Object { $_.rel_path -eq '2019\01\b.html' }).code | Should -Be 'render_ok'
            ($all | Where-Object { $_.rel_path -eq '2019\01\bin.html' }).code | Should -Be 'render_failed'
            ($all | Where-Object { $_.rel_path -eq '2019\01\empty.html' }).code | Should -Be 'render_failed'
            ($all | Where-Object { $_.rel_path -eq '2019\01\gone.html' }).code | Should -Be 'render_failed'
        }
        It 'renders exactly the shared _sample entries present in its records (stage-computed sample)' {
            $opt = @{ rate = 0; minPerBatch = 1; seed = 42; renderer = 'parse'; _sample = @('2019\01\a.html', '2019\01\b.html', '2019\01\not-in-records.html') }
            $f = Invoke-Rule -Name renderSample -Ctx $script:ctx -Root $script:root -Records $script:recs -Options $opt
            @($f.rel_path) | Should -Be @('2019\01\a.html', '2019\01\b.html')
        }
        It 'single-pass top-k sample equals the full sort by rank' {
            $paths = @(1..200 | ForEach-Object { 'd\f{0:D3}.html' -f $_ })
            $res = & $script:mod {
                param($p)
                $k = Get-MigHtmlRenderSample -RelPaths $p -Rate 0.05 -MinPerBatch 1 -Seed '7' -BatchId 'B9'
                $ref = @($p | ForEach-Object { [pscustomobject]@{ rel = $_; rank = (Get-MigHtmlStableRank -Seed '7' -BatchId 'B9' -RelPath $_) } } | Sort-Object rank | Select-Object -First 10 | ForEach-Object { $_.rel })
                @{ k = @($k); ref = $ref }
            } $paths
            $res.k.Count | Should -Be 10
            $res.k | Should -Be $res.ref
        }
        It 'parse renderer reports files above maxBytesToParse as skipped_large, not render_ok' {
            $ctx2 = New-TestContext -Root (Join-Path $TestDrive 'rs-large') -Override @{ htmlChecks = @{ rules = @{ malformed = @{ maxBytesToParse = 4000 } } } }
            try {
                $f = Invoke-Rule -Name renderSample -Ctx $ctx2 -Root $script:root -Records $script:recs -Options @{ rate = 1; minPerBatch = 1; seed = 1; renderer = 'parse' }
                $big = $f | Where-Object { $_.rel_path -eq '2019\01\big.html' }
                $big.code | Should -Be 'skipped_large'
                $big.severity | Should -Be 'warning'
            } finally { & $script:mod { param($c) Close-MigContext -Ctx $c } $ctx2 }
        }
        It 'strictRenderer: fails instead of falling back when Edge is not available' {
            $opt = @{ rate = 0; minPerBatch = 1; seed = 42; renderer = 'edgeHeadless'; strictRenderer = $true; edgePath = (Join-Path $TestDrive 'no-edge.exe'); timeoutSec = 5 }
            { Invoke-Rule -Name renderSample -Ctx $script:ctx -Root $script:root -Records $script:recs -Options $opt 3>$null } | Should -Throw '*strictRenderer*'
        }
        It 'falls back to parse with a warning when Edge is not available' {
            $opt = @{ rate = 0; minPerBatch = 1; seed = 42; renderer = 'edgeHeadless'; edgePath = (Join-Path $TestDrive 'no-edge.exe'); timeoutSec = 5 }
            $f = Invoke-Rule -Name renderSample -Ctx $script:ctx -Root $script:root -Records $script:recs -Options $opt 3>$null
            $f.Count | Should -Be 1
            $f[0].detail | Should -Match '\(parse\)'
        }
        It 'rejects an unknown renderer' {
            { Invoke-Rule -Name renderSample -Ctx $script:ctx -Root $script:root -Records $script:recs -Options @{ rate = 1; minPerBatch = 1; seed = 1; renderer = 'bogus' } } | Should -Throw '*not supported*'
        }
    }
}

Describe 'Resolve-MigHtmlReference' {
    It 'resolves <ref> from <base> as <kind> <rel>' -ForEach @(
        @{ base = 'a\b\c.html'; ref = 'img/x.png'; kind = 'relative'; rel = 'a\b\img\x.png' }
        @{ base = 'a\b\c.html'; ref = './../x.css'; kind = 'relative'; rel = 'a\x.css' }
        @{ base = 'a\b\c.html'; ref = '/root.css'; kind = 'relative'; rel = 'root.css' }
        @{ base = 'a\b\c.html'; ref = 'x%20y.png?v=1#f'; kind = 'relative'; rel = 'a\b\x y.png' }
        @{ base = 'c.html'; ref = '../x.css'; kind = 'outside'; rel = $null }
        @{ base = 'c.html'; ref = 'HTTPS://x/y'; kind = 'ignore'; rel = $null }
        @{ base = 'c.html'; ref = 'ftp://x/y'; kind = 'ignore'; rel = $null }
        @{ base = 'c.html'; ref = '//cdn/x.js'; kind = 'ignore'; rel = $null }
        @{ base = 'c.html'; ref = 'C:\x\y.png'; kind = 'ignore'; rel = $null }
        @{ base = 'c.html'; ref = '#top'; kind = 'ignore'; rel = $null }
        @{ base = 'c.html'; ref = '{{url}}'; kind = 'ignore'; rel = $null }
    ) {
        $r = & $script:mod { param($b, $x) Resolve-MigHtmlReference -BaseRelPath $b -Reference $x -IgnoreSchemes @('http', 'https', 'mailto') } $base $ref
        $r.kind | Should -Be $kind
        $r.rel_path | Should -Be $rel
    }
}

Describe 'Get-MigHtmlReferences' {
    It 'finds attributes only inside start tags, across quoted values containing > and <' {
        $html = '<p>text src="not-a-tag.png" href=x</p><a title="a>b" data-href="no.html" href="yes1.html">x</a>' +
                "<img`nalt='c<d'`nsrc=yes2.png><IMG SRC=""yes3.png""><x-y href='yes4.html'>"
        $r = & $script:mod { param($t) Get-MigHtmlReferences -Text $t -Attributes @('src', 'href') } $html
        @($r | ForEach-Object { $_.value }) | Should -Be @('yes1.html', 'yes2.png', 'yes3.png', 'yes4.html')
        @($r | ForEach-Object { $_.attr }) | Should -Be @('href', 'src', 'src', 'href')
    }
    It 'HTML-decodes values' {
        $r = & $script:mod { Get-MigHtmlReferences -Text '<a href="a&amp;b.html">' -Attributes @('href') }
        $r[0].value | Should -Be 'a&b.html'
    }
}
