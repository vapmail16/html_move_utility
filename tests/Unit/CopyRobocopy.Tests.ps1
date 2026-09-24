BeforeDiscovery {
    Import-Module "$PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1" -Force -DisableNameChecking
}

# Robocopy only exists on Windows: every test mocks Invoke-MigRobocopyProcess and inspects the arguments.
InModuleScope NotificationMigration {
    Describe 'Copy provider robocopy' {
        BeforeAll {
            function New-RoboCtx {
                param([hashtable] $Override = @{}, [switch] $DryRun)
                $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
                $src = Join-Path $root 'src'; $tgt = Join-Path $root 'tgt'; $work = Join-Path $root 'work'
                New-Item -ItemType Directory -Force -Path $src, $tgt, $work | Out-Null
                $cfg = [ordered]@{
                    paths     = @{ sourceRoot = $src; targetRoot = $tgt; workDir = $work }
                    inventory = @{ aclReader = 'none'; threads = 2 }
                    batching  = @{ strategy = 'yearMonth' }
                    copy      = @{ engine = 'robocopy' }
                    compare   = @{ fileFields = @('exists', 'size', 'hash'); dirFields = @('exists') }
                }
                $cfgPath = Join-Path $root 'migration.config.json'
                ConvertTo-Json $cfg -Depth 6 | Set-Content -LiteralPath $cfgPath
                return New-MigContext -ConfigPath $cfgPath -Override $Override -DryRun:$DryRun -Operator 'maker'
            }
            function New-SrcFiles {
                param($Ctx, [string[]] $RelPaths)
                foreach ($r in $RelPaths) {
                    $p = Join-MigPath -Root $Ctx.Config.paths.sourceRoot -RelPath $r
                    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($p)) | Out-Null
                    [IO.File]::WriteAllText($p, "content of $r")
                }
            }
            function Get-LogArg { param([string[]] $Arguments) return (@($Arguments | Where-Object { $_ -like '/UNILOG+:*' })[0]).Substring(9) }
            $script:calls = New-Object System.Collections.Generic.List[object]
        }
        BeforeEach {
            $script:calls.Clear()
            Mock Invoke-MigRobocopyProcess -ModuleName NotificationMigration -MockWith { $script:calls.Add([string[]]$Arguments); return 1 }
        }

        It 'groups by parent directory, never recurses, and applies flags, /MT, /UNILOG+' {
            $ctx = New-RoboCtx
            New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html', '2019\03\c.html', '2019\04\d.html')
            $p = Get-MigProvider -Kind Copy -Name 'robocopy'
            $r = & $p $ctx '2019-03' @{ RelPaths = @('2019\03\a.html', '2019\03\b.html', '2019\04\d.html'); Directories = @(); DryRun = $false }
            $script:calls.Count | Should -Be 2
            $a = $script:calls[0]
            $a[0] | Should -Be (Join-MigPath -Root $ctx.Config.paths.sourceRoot -RelPath '2019\03')
            $a[1] | Should -Be (Join-MigPath -Root $ctx.Config.paths.targetRoot -RelPath '2019\03')
            $a | Should -Contain 'a.html'
            $a | Should -Contain 'b.html'
            $a | Should -Not -Contain 'c.html'
            $a | Should -Contain '/COPY:DATSO'
            $a | Should -Contain '/DCOPY:T'
            $a | Should -Contain '/MT:16'
            @($a | Where-Object { $_ -match '^/(S|E|MIR|MOV|MOVE|PURGE)$' }).Count | Should -Be 0
            @($a | Where-Object { $_ -eq '/L' }).Count | Should -Be 0
            $log = Get-LogArg $a
            $log | Should -Be (Join-Path (Join-Path $ctx.Config._resolved.logDir 'robocopy') ('2019-03-{0}.log' -f $ctx.RunId))
            $r.exit_code | Should -Be 1
            $r.succeeded | Should -BeTrue
            @($r.copied).Count | Should -Be 3
            $r.log_path | Should -Be $log
            Close-MigContext $ctx
        }

        It 'passes no file names when the plan covers every file in the directory' {
            $ctx = New-RoboCtx
            New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html')
            $p = Get-MigProvider -Kind Copy -Name 'robocopy'
            [void](& $p $ctx '2019-03' @{ RelPaths = @('2019\03\a.html', '2019\03\b.html'); Directories = @(); DryRun = $false })
            $script:calls.Count | Should -Be 1
            $script:calls[0] | Should -Not -Contain 'a.html'
            $script:calls[0] | Should -Not -Contain 'b.html'
            $script:calls[0][2] | Should -BeLike '/*'
            Close-MigContext $ctx
        }

        It 'adds /L in dry run, /IS /IT when forced, and /XF * for directory-only entries' {
            $ctx = New-RoboCtx -DryRun
            New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html')
            New-Item -ItemType Directory -Force -Path (Join-MigPath -Root $ctx.Config.paths.sourceRoot -RelPath '2019\03\empty') | Out-Null
            $p = Get-MigProvider -Kind Copy -Name 'robocopy'
            $r = & $p $ctx '2019-03' @{ RelPaths = @('2019\03\a.html'); Directories = @('2019\03', '2019\03\empty'); DryRun = $true; Force = $true }
            $script:calls.Count | Should -Be 2
            $files = $script:calls[0]; $dir = $script:calls[1]
            $files | Should -Contain '/L'
            $files | Should -Contain '/IS'
            $files | Should -Contain '/IT'
            $dir[0] | Should -Be (Join-MigPath -Root $ctx.Config.paths.sourceRoot -RelPath '2019\03\empty')
            $i = [array]::IndexOf($dir, '/XF')
            $i | Should -BeGreaterThan 1
            $dir[$i + 1] | Should -Be '*'
            $r.dry_run | Should -BeTrue
            Close-MigContext $ctx
        }

        It 'caps /MT with the active throttle window and adds /IPG' {
            $all = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
            $ctx = New-RoboCtx
            # A window that is active at any time of any day.
            $ctx.Config.throttle = @{ enabled = $true; timeZone = 'Local'; windows = @(@{ days = $all; from = '00:00:00'; to = '23:59:59.9999999'; threads = 3; ipgMs = 25 }) }
            New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html')
            $p = Get-MigProvider -Kind Copy -Name 'robocopy'
            [void](& $p $ctx '2019-03' @{ RelPaths = @('2019\03\a.html'); Directories = @(); DryRun = $false })
            $script:calls[0] | Should -Contain '/MT:3'
            $script:calls[0] | Should -Contain '/IPG:25'
            Close-MigContext $ctx
        }

        It 'chunks file names to stay under copy.robocopy.maxCommandLineChars' {
            $ctx = New-RoboCtx
            $ctx.Config.copy.robocopy['maxCommandLineChars'] = 1500
            $rels = @(1..60 | ForEach-Object { '2019\03\notification-with-a-long-descriptive-name-{0:D4}.html' -f $_ })
            New-SrcFiles $ctx ($rels + @('2019\03\not-planned.html'))
            $p = Get-MigProvider -Kind Copy -Name 'robocopy'
            $r = & $p $ctx '2019-03' @{ RelPaths = $rels; Directories = @(); DryRun = $false }
            $script:calls.Count | Should -BeGreaterThan 1
            $names = New-Object System.Collections.Generic.List[string]
            foreach ($c in $script:calls) {
                $len = 'robocopy.exe'.Length
                foreach ($x in $c) { $len += $x.Length + 3 }
                $len | Should -BeLessOrEqual 1500
                foreach ($x in $c) { if ($x -like 'notification-*') { $names.Add($x) } }
            }
            $names.Count | Should -Be 60
            @($names | Select-Object -Unique).Count | Should -Be 60
            @($r.copied).Count | Should -Be 60
            Close-MigContext $ctx
        }

        Context 'exit codes and log parsing' {
            It 'treats exit codes up to successExitCodeMax as success' {
                Mock Invoke-MigRobocopyProcess -ModuleName NotificationMigration -MockWith { return 7 }
                $ctx = New-RoboCtx
                New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html')
                $r = & (Get-MigProvider Copy robocopy) $ctx '2019-03' @{ RelPaths = @('2019\03\a.html'); Directories = @(); DryRun = $false }
                $r.succeeded | Should -BeTrue
                @($r.failed).Count | Should -Be 0
                $r.exit_code | Should -Be 7
                Close-MigContext $ctx
            }

            It 'fails every file of the invocation when exit code >= 8 and the log names no file' {
                Mock Invoke-MigRobocopyProcess -ModuleName NotificationMigration -MockWith { return 16 }
                $ctx = New-RoboCtx
                New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html', '2019\03\c.html')
                $r = & (Get-MigProvider Copy robocopy) $ctx '2019-03' @{ RelPaths = @('2019\03\a.html', '2019\03\b.html'); Directories = @(); DryRun = $false }
                $r.succeeded | Should -BeFalse
                $r.exit_code | Should -Be 16
                @($r.failed).Count | Should -Be 2
                @($r.copied).Count | Should -Be 0
                $r.failed[0].error | Should -Match 'exit code 16'
                Close-MigContext $ctx
            }

            It 'fails only the files named by ERROR lines in the log' {
                Mock Invoke-MigRobocopyProcess -ModuleName NotificationMigration -MockWith {
                    $log = (@($Arguments | Where-Object { $_ -like '/UNILOG+:*' })[0]).Substring(9)
                    $sep = [IO.Path]::DirectorySeparatorChar
                    $text = "`r`n  New File  12  $($Arguments[0])$($sep)a.html`r`n" +
                            "2024/01/31 10:00:00 ERROR 32 (0x00000020) Copying File $($Arguments[0])$($sep)b.html`r`n" +
                            "The process cannot access the file because it is being used by another process.`r`n" +
                            "Waiting 5 seconds... Retrying...`r`n" +
                            "2024/01/31 10:00:05 ERROR 32 (0x00000020) Copying File $($Arguments[0])$($sep)b.html`r`n" +
                            "The process cannot access the file because it is being used by another process.`r`n" +
                            "ERROR: RETRY LIMIT EXCEEDED.`r`n"
                    [IO.File]::AppendAllText($log, $text, [Text.Encoding]::Unicode)
                    return 8
                }
                $ctx = New-RoboCtx
                New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html', '2019\03\c.html')
                # Pre-existing log content from an earlier invocation must not be re-parsed.
                $logDir = Join-Path $ctx.Config._resolved.logDir 'robocopy'
                New-Item -ItemType Directory -Force -Path $logDir | Out-Null
                $sep = [IO.Path]::DirectorySeparatorChar
                $old = "ERROR 5 (0x00000005) Copying File $(Join-MigPath -Root $ctx.Config.paths.sourceRoot -RelPath '2019\03')$($sep)a.html`r`nAccess is denied.`r`n"
                [IO.File]::WriteAllText((Join-Path $logDir "2019-03-$($ctx.RunId).log"), $old, [Text.Encoding]::Unicode)

                $r = & (Get-MigProvider Copy robocopy) $ctx '2019-03' @{ RelPaths = @('2019\03\a.html', '2019\03\b.html'); Directories = @(); DryRun = $false }
                $r.succeeded | Should -BeFalse
                @($r.failed).Count | Should -Be 1
                $r.failed[0].rel_path | Should -Be '2019\03\b.html'
                $r.failed[0].error | Should -Match 'ERROR 32'
                $r.failed[0].error | Should -Match 'being used by another process'
                @($r.copied) | Should -Be @('2019\03\a.html')
                Close-MigContext $ctx
            }

            It 'fails the invocation when robocopy cannot be started' {
                Mock Invoke-MigRobocopyProcess -ModuleName NotificationMigration -MockWith { throw "The term 'robocopy.exe' is not recognized" }
                $ctx = New-RoboCtx
                New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html')
                $r = & (Get-MigProvider Copy robocopy) $ctx '2019-03' @{ RelPaths = @('2019\03\a.html'); Directories = @(); DryRun = $false }
                $r.exit_code | Should -Be -1
                $r.failed[0].error | Should -Match 'could not be started'
                Close-MigContext $ctx
            }

            It 'parses ERROR lines, messages and the retry-limit marker' {
                $text = "2024/01/31 10:00:00 ERROR 5 (0x00000005) Copying File D:\src\2019\03\a.html`r`nAccess is denied.`r`n" +
                        "2024/01/31 10:00:01 ERROR 2 (0x00000002) Changing File Attributes \\srv\share\2019\03\b file.html`r`nThe system cannot find the file specified.`r`nERROR: RETRY LIMIT EXCEEDED.`r`n"
                $e = ConvertFrom-MigRobocopyLog -Text $text
                $e.Count | Should -Be 2
                $e[0].code | Should -Be 5
                $e[0].action | Should -Be 'Copying File'
                $e[0].path | Should -Be 'D:\src\2019\03\a.html'
                $e[0].message | Should -Be 'Access is denied.'
                $e[0].final | Should -BeFalse
                $e[1].path | Should -Be '\\srv\share\2019\03\b file.html'
                $e[1].final | Should -BeTrue
                $inv = @{ RelDir = '2019\03'; Mode = 'names'; RelPaths = @('2019\03\a.html', '2019\03\b file.html'); Source = '\\srv\share\2019\03'; Destination = 'E:\tgt\2019\03' }
                $m = Get-MigRobocopyFailedRelPaths -Invocation $inv -Errors $e
                @($m.Keys) | Should -Be @('2019\03\b file.html')    # only the final (retry limit exceeded) error counts
            }
        }

        Context 'safety' {
            It 'refuses forbidden flags before starting robocopy' {
                $ctx = New-RoboCtx
                New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html')
                $ctx.Config.copy.robocopy.flags = @($ctx.Config.copy.robocopy.flags) + '/MIR'
                { & (Get-MigProvider Copy robocopy) $ctx '2019-03' @{ RelPaths = @('2019\03\a.html'); Directories = @(); DryRun = $false } } | Should -Throw '*SAFETY*'
                Should -Invoke Invoke-MigRobocopyProcess -ModuleName NotificationMigration -Times 0 -Exactly
                Close-MigContext $ctx
            }
            It 'refuses /MOV even when the config forbidden list is emptied' {
                $ctx = New-RoboCtx
                New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html')
                $ctx.Config.copy.forbiddenFlags = @()
                $ctx.Config.copy.robocopy.flags = @('/MOV')
                { & (Get-MigProvider Copy robocopy) $ctx '2019-03' @{ RelPaths = @('2019\03\a.html'); Directories = @(); DryRun = $false } } | Should -Throw '*SAFETY*'
                Should -Invoke Invoke-MigRobocopyProcess -ModuleName NotificationMigration -Times 0 -Exactly
                Close-MigContext $ctx
            }
            It 'refuses a destination under sourceRoot' {
                $ctx = New-RoboCtx
                New-SrcFiles $ctx @('2019\03\a.html', '2019\03\b.html')
                $ctx.Config.paths.targetRoot = Join-Path $ctx.Config.paths.sourceRoot 'copy'
                { & (Get-MigProvider Copy robocopy) $ctx '2019-03' @{ RelPaths = @('2019\03\a.html'); Directories = @(); DryRun = $false } } | Should -Throw '*SAFETY*'
                Should -Invoke Invoke-MigRobocopyProcess -ModuleName NotificationMigration -Times 0 -Exactly
                Close-MigContext $ctx
            }
        }
        Context 'evidence and folder chunking' {
            BeforeAll {
                function Write-RoboManifest {
                    param($Ctx, [string[]] $RelPaths)
                    $recs = @(foreach ($r in $RelPaths) {
                        [ordered]@{ rel_path = $r; kind = 'file'; batch_id = '2019-03'; side = 'source'; size_bytes = ("content of $r").Length; scanned_utc = Get-MigUtcNow; error = $null }
                    })
                    Write-MigManifest -Store $Ctx.Store -BatchId '2019-03' -Side source -Records $recs
                }
            }

            It 'writes a .sha256 sidecar for the log after each invocation and reports it' {
                Mock Invoke-MigRobocopyProcess -ModuleName NotificationMigration -MockWith {
                    $script:calls.Add([string[]]$Arguments)
                    $log = (@($Arguments | Where-Object { $_ -like '/UNILOG+:*' })[0]).Substring(9)
                    [IO.File]::AppendAllText($log, "copied $($Arguments[0])`r`n", [Text.Encoding]::Unicode)
                    return 1
                }
                $ctx = New-RoboCtx
                New-SrcFiles $ctx @('2019\03\a.html', '2019\04\b.html')
                $r = & (Get-MigProvider Copy robocopy) $ctx '2019-03' @{ RelPaths = @('2019\03\a.html', '2019\04\b.html'); Directories = @(); DryRun = $false }
                $script:calls.Count | Should -Be 2
                $sc = $r.log_path + '.sha256'
                @($r.log_sidecars) | Should -Be @($sc)
                Test-Path -LiteralPath $sc | Should -BeTrue
                $line = [IO.File]::ReadAllText($sc).Trim()
                $line | Should -Be ('{0}  {1}' -f (Get-MigFileHash -Path $r.log_path), [IO.Path]::GetFileName($r.log_path))
                Close-MigContext $ctx
            }

            It 'Copy stage: one whole-folder robocopy per folder (no names), each folder listed once, no /S or /E' {
                Mock Test-MigRobocopyWholeDir -ModuleName NotificationMigration -MockWith { $script:listed.Add($Path); return $true }
                $script:listed = New-Object System.Collections.Generic.List[string]
                $ctx = New-RoboCtx -Override @{ copy = @{ chunkSize = 2 } }
                $rels = @('2019\03\01\a.html', '2019\03\01\b.html', '2019\03\01\c.html', '2019\03\02\d.html', '2019\03\02\e.html', '2019\03\03\f.html')
                New-SrcFiles $ctx $rels
                Write-RoboManifest $ctx $rels
                $s = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03'
                $script:calls.Count | Should -Be 3
                $s.invocations | Should -Be 3
                $s.chunks | Should -Be 3
                $script:listed.Count | Should -Be 3
                foreach ($c in $script:calls) {
                    @($c | Where-Object { $_ -like '*.html' }).Count | Should -Be 0
                    @($c | Where-Object { $_ -match '^/(S|E)$' }).Count | Should -Be 0
                }
                $s.files_copied | Should -Be 6
                $s.files_failed | Should -Be 0
                @($s.log_files).Count | Should -Be 1
                Close-MigContext $ctx
            }

            It 'Copy stage: a folder above chunkSize * splitFolderFactor is split into name lists and never listed' {
                Mock Test-MigRobocopyWholeDir -ModuleName NotificationMigration -MockWith { $script:listed.Add($Path); return $true }
                $script:listed = New-Object System.Collections.Generic.List[string]
                $ctx = New-RoboCtx -Override @{ copy = @{ chunkSize = 2; splitFolderFactor = 1 } }
                $rels = @('2019\03\a.html', '2019\03\b.html', '2019\03\c.html', '2019\03\d.html', '2019\03\e.html')
                New-SrcFiles $ctx $rels
                Write-RoboManifest $ctx $rels
                $s = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03'
                $script:calls.Count | Should -Be 3                  # 2 + 2 + 1 names
                $script:listed.Count | Should -Be 0
                $names = @($script:calls | ForEach-Object { $_ } | Where-Object { $_ -like '*.html' })
                $names.Count | Should -Be 5
                $s.files_copied | Should -Be 5
                Close-MigContext $ctx
            }

            It 'reports files_failed truthfully when robocopy fails' {
                Mock Invoke-MigRobocopyProcess -ModuleName NotificationMigration -MockWith { $script:calls.Add([string[]]$Arguments); return 16 }
                $ctx = New-RoboCtx
                $rels = @('2019\03\a.html', '2019\03\b.html')
                New-SrcFiles $ctx $rels
                Write-RoboManifest $ctx $rels
                $s = Invoke-MigStageCopy -Ctx $ctx -BatchId '2019-03'
                $s.files_failed | Should -Be 2
                $s.files_copied | Should -Be 0
                $s.bytes | Should -Be 0
                Test-MigSummaryPassed -Summary $s | Should -BeFalse
                Close-MigContext $ctx
            }
        }
    }
}
