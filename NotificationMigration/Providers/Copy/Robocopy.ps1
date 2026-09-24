# Copy provider 'robocopy' (FR-03). Production copy engine on Windows.
# Robocopy cannot take a file list spanning directories, so the plan is grouped by parent directory and
# each directory gets its own invocation:  robocopy <src\dir> <tgt\dir> [names...] <flags>   (never /S or /E)
#  - file names are chunked so the command line stays well under the Windows 32k limit
#    (copy.robocopy.maxCommandLineChars);
#  - when the plan covers exactly the files present in the source directory, no names are passed (whole-folder
#    mode: one process per folder, still no /S). The Copy stage chunks by folder so this is the normal case; the
#    source directory is enumerated once per folder and not at all for folders listed in $Plan.SplitDirs;
#  - plan directories with no planned files run with '/XF *' so the directory (and /DCOPY:T timestamps) are
#    applied without copying any file.
# Flags come from copy.robocopy.flags; /MT from copy.robocopy.threads (capped by throttle windows); /IPG from the
# active throttle window; /L in dry run; /IS /IT when the plan forces a re-copy; logging is always
# /UNILOG+:<logDir>\robocopy\<batch>-<runId>.log. Every final argument list passes Assert-MigCopyFlagsSafe and
# every destination passes Assert-MigPathNotUnderSource before robocopy is started.
# Exit codes 0..copy.robocopy.successExitCodeMax are success; anything higher is a failure, in
# which case the log is parsed for per-file ERROR lines; if none can be attributed, every file of that
# invocation is treated as failed.
# Evidence (C-07): after every invocation the log gets a '<log>.sha256' sidecar (Get-MigFileHash).

function Invoke-MigRobocopyProcess {
    <# Runs robocopy and returns its exit code. Kept tiny so tests can Mock it. #>
    param([Parameter(Mandatory = $true)][string] $Executable, [Parameter(Mandatory = $true)][string[]] $Arguments)
    $null = & $Executable @Arguments 2>&1
    return [int]$LASTEXITCODE
}

function Test-MigRobocopyWholeDir {
    <#
    True when the files directly inside the source directory are exactly $Names (case-insensitive). Streams the
    listing (read-only, no array of names) and stops at the first file that is not planned. $false if unlistable.
    #>
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)] $Names)
    try {
        $di = New-Object System.IO.DirectoryInfo($Path)
        if (-not $di.Exists) { return $false }
        $n = 0
        foreach ($f in $di.EnumerateFiles()) {
            if (-not $Names.Contains($f.Name)) { return $false }
            $n++
        }
        return ($n -eq $Names.Count)
    } catch { return $false }
}

function Write-MigLogChecksum {
    <# Writes '<log>.sha256' ('<hash>  <file name>') next to a log file. Returns the sidecar path, or $null. #>
    param([Parameter(Mandatory = $true)][string] $Path)
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $sidecar = $Path + '.sha256'
    [System.IO.File]::WriteAllText($sidecar, ('{0}  {1}' -f (Get-MigFileHash -Path $Path), [System.IO.Path]::GetFileName($Path)) + "`n")
    return $sidecar
}

function Get-MigRobocopyDirPath {
    <# Native directory path for robocopy: no \\?\ prefix (robocopy handles long paths) and never a trailing '\'. #>
    param([Parameter(Mandatory = $true)][string] $Root, [AllowEmptyString()][string] $RelDir)
    $p = Remove-MigLongPathPrefix (Join-MigPath -Root $Root -RelPath $RelDir)
    if ($p.EndsWith(':')) { $p += '\.' }          # 'D:' would mean "current dir on D:"; 'D:\' would escape the closing quote
    return $p
}

function Get-MigRobocopyOptions {
    <# Options part of the command line (everything after source/destination/names). #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $LogPath, [bool] $DryRun, [bool] $Force, [bool] $DirectoryOnly)
    $cfg = $Ctx.Config
    $opts = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-MigConfigSetting -Config $cfg -Path 'copy.robocopy.flags')) { if ($f) { $opts.Add([string]$f) } }
    $threads = [int](Get-MigConfigSetting -Config $cfg -Path 'copy.robocopy.threads')
    $threads = [Math]::Max(1, [Math]::Min(128, (Get-MigEffectiveThreads -Ctx $Ctx -Default $threads)))
    $opts.Add("/MT:$threads")
    $w = Get-MigActiveThrottleWindow -Config $cfg
    if ($w -and $w['ipgMs'] -and [int]$w['ipgMs'] -gt 0) { $opts.Add("/IPG:$([int]$w['ipgMs'])") }
    if ($Force) { $opts.Add('/IS'); $opts.Add('/IT') }
    if ($DryRun) { $opts.Add('/L') }
    if ($DirectoryOnly) { $opts.Add('/XF'); $opts.Add('*') }
    $opts.Add("/UNILOG+:$LogPath")
    return , $opts.ToArray()
}

function Get-MigArgLength {
    param([string[]] $Arguments)
    $n = 0
    foreach ($a in $Arguments) { $n += $a.Length + 3 }   # quotes + separating space
    return $n
}

function New-MigRobocopyInvocations {
    <#
    Pure planning step (no process started): returns invocations @{ RelDir; Mode ('names'|'whole'|'dironly');
    Names; RelPaths; Source; Destination; Arguments }.
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [AllowEmptyCollection()][string[]] $RelPaths = @(), [AllowEmptyCollection()][string[]] $Directories = @(),
          [Parameter(Mandatory = $true)][string] $LogPath, [bool] $DryRun, [bool] $Force, [AllowEmptyCollection()][string[]] $SplitDirs = @())
    $cfg = $Ctx.Config
    $srcRoot = [string]$cfg.paths.sourceRoot
    $tgtRoot = [string]$cfg.paths.targetRoot
    $exe = [string](Get-MigConfigSetting -Config $cfg -Path 'copy.robocopy.executable')
    $maxChars = [int](Get-MigConfigSetting -Config $cfg -Path 'copy.robocopy.maxCommandLineChars')
    if ($maxChars -lt 512) { $maxChars = 512 }
    if ($maxChars -gt 30000) { $maxChars = 30000 }
    $useLong = [bool](Get-MigConfigSetting -Config $cfg -Path 'paths.useLongPathPrefix')
    $split = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $SplitDirs) { if ($null -ne $d) { [void]$split.Add((ConvertTo-MigCanonicalRelPath $d)) } }

    # Group file names by parent directory (ordered, case-insensitive, de-duplicated).
    $groups = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rel in $RelPaths) {
        if (-not $rel) { continue }
        $c = ConvertTo-MigCanonicalRelPath $rel
        $parent = Get-MigParentRelPath $c
        if (-not $groups.ContainsKey($parent)) { $groups[$parent] = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
        [void]$groups[$parent].Add($c.Substring($c.LastIndexOf('\') + 1))
    }
    $dirOnly = New-Object System.Collections.Generic.List[string]
    $dirSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $Directories) {
        if ($null -eq $d) { continue }
        $c = ConvertTo-MigCanonicalRelPath $d
        if (-not $groups.ContainsKey($c) -and $dirSeen.Add($c)) { $dirOnly.Add($c) }
    }

    $out = New-Object System.Collections.Generic.List[object]
    $optsNames = Get-MigRobocopyOptions -Ctx $Ctx -LogPath $LogPath -DryRun $DryRun -Force $Force -DirectoryOnly $false
    foreach ($relDir in $groups.Keys) {
        $set = $groups[$relDir]
        $names = [string[]]@($set | Sort-Object)
        $src = Get-MigRobocopyDirPath -Root $srcRoot -RelDir $relDir
        $dst = Get-MigRobocopyDirPath -Root $tgtRoot -RelDir $relDir
        $toRel = @(foreach ($n in $names) { if ($relDir) { $relDir + '\' + $n } else { $n } })

        # Whole directory only when the plan names exactly the files that exist there (nothing excluded / other
        # batch / already verified). A folder split over several plans can never be whole: it is not listed.
        $whole = $false
        if ($names.Count -gt 0 -and -not $split.Contains($relDir)) {
            $whole = Test-MigRobocopyWholeDir -Path (Get-MigLongPath -Path (Join-MigPath -Root $srcRoot -RelPath $relDir) -Enabled $useLong) -Names $set
        }
        if ($whole) {
            $out.Add(@{ RelDir = $relDir; Mode = 'whole'; Names = @(); RelPaths = $toRel; Source = $src; Destination = $dst
                        Arguments = [string[]](@($src, $dst) + $optsNames) })
            continue
        }
        $base = $exe.Length + (Get-MigArgLength -Arguments (@($src, $dst) + $optsNames))
        $chunk = New-Object System.Collections.Generic.List[string]
        $len = $base
        for ($i = 0; $i -le $names.Count; $i++) {
            $flush = ($i -eq $names.Count)
            if (-not $flush) {
                $add = $names[$i].Length + 3
                if ($chunk.Count -gt 0 -and ($len + $add) -gt $maxChars) { $flush = $true; $i-- }
                else { $chunk.Add($names[$i]); $len += $add; continue }
            }
            if ($chunk.Count -gt 0) {
                $cn = $chunk.ToArray()
                $cr = @(foreach ($n in $cn) { if ($relDir) { $relDir + '\' + $n } else { $n } })
                $out.Add(@{ RelDir = $relDir; Mode = 'names'; Names = $cn; RelPaths = $cr; Source = $src; Destination = $dst
                            Arguments = [string[]](@($src, $dst) + $cn + $optsNames) })
            }
            $chunk = New-Object System.Collections.Generic.List[string]
            $len = $base
        }
    }
    if ($dirOnly.Count -gt 0) {
        $optsDir = Get-MigRobocopyOptions -Ctx $Ctx -LogPath $LogPath -DryRun $DryRun -Force $Force -DirectoryOnly $true
        # Deepest first so creating a child directory does not disturb an already-stamped parent.
        foreach ($relDir in ($dirOnly | Sort-Object { Get-MigRelPathDepth $_ } -Descending)) {
            $src = Get-MigRobocopyDirPath -Root $srcRoot -RelDir $relDir
            $dst = Get-MigRobocopyDirPath -Root $tgtRoot -RelDir $relDir
            $out.Add(@{ RelDir = $relDir; Mode = 'dironly'; Names = @(); RelPaths = @($relDir); Source = $src; Destination = $dst
                        Arguments = [string[]](@($src, $dst) + $optsDir) })
        }
    }
    return , $out.ToArray()
}

function Read-MigRobocopyLogSlice {
    <# Text appended to a UTF-16 (/UNILOG) log after byte $Offset. '' when the log does not exist. #>
    param([Parameter(Mandatory = $true)][string] $Path, [long] $Offset = 0)
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        if ($Offset -gt $fs.Length) { $Offset = 0 }
        if ($Offset % 2 -ne 0) { $Offset-- }
        [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ($fs.Length - $Offset)
        $read = 0
        while ($read -lt $buf.Length) { $n = $fs.Read($buf, $read, $buf.Length - $read); if ($n -le 0) { break }; $read += $n }
    } finally { $fs.Dispose() }
    return [System.Text.Encoding]::Unicode.GetString($buf, 0, $read).TrimStart([char]0xFEFF)
}

function ConvertFrom-MigRobocopyLog {
    <#
    Extracts error entries from robocopy log text:
      2024/01/31 10:00:00 ERROR 5 (0x00000005) Copying File D:\src\2019\03\a.html
      Access is denied.
    Returns @{ code; action; path; message; final } per ERROR line. 'final' is set when the error was followed
    by 'ERROR: RETRY LIMIT EXCEEDED.' (robocopy gave up), as opposed to a transient error that was retried.
    #>
    param([AllowEmptyString()][string] $Text)
    $out = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Text)) { return , $out.ToArray() }
    $rx = New-Object regex('ERROR\s+(\d+)\s+\((0x[0-9A-Fa-f]+)\)\s+(.*?)\s*((?:[A-Za-z]:[\\/]|\\\\|/).*?)\s*$')
    $lines = $Text -split "`r?`n"
    $last = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match 'RETRY LIMIT EXCEEDED') { if ($last) { $last.final = $true }; continue }
        $m = $rx.Match($line)
        if (-not $m.Success) { continue }
        $msg = $null
        for ($j = $i + 1; $j -lt $lines.Count; $j++) { if ($lines[$j].Trim()) { $msg = $lines[$j].Trim(); break } }
        $last = @{ code = [int]$m.Groups[1].Value; hex = $m.Groups[2].Value; action = $m.Groups[3].Value.Trim(); path = $m.Groups[4].Value; message = $msg; final = $false }
        $out.Add($last)
    }
    return , $out.ToArray()
}

function Get-MigRobocopyFailedRelPaths {
    <#
    Maps parsed log errors to rel_paths of one invocation. Returns Dictionary[rel_path -> error text].
    When any error is marked final (retry limit exceeded) only final errors count; otherwise every error counts.
    #>
    param([Parameter(Mandatory = $true)] $Invocation, [AllowEmptyCollection()][object[]] $Errors = @())
    $d = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $Invocation.RelPaths) { [void]$wanted.Add($r) }
    $errs = @($Errors)
    if (@($errs | Where-Object { $_.final }).Count -gt 0) { $errs = @($errs | Where-Object { $_.final }) }
    foreach ($e in $errs) {
        $p = ConvertTo-MigCanonicalRelPath ([string]$e.path)
        $rel = $null
        foreach ($base in @($Invocation.Source, $Invocation.Destination)) {
            $b = (ConvertTo-MigCanonicalRelPath $base).TrimEnd('\')
            if ($b.EndsWith('\.')) { $b = $b.Substring(0, $b.Length - 2) }
            if ($p.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $name = $p.Substring($b.Length + 1)
                if ($Invocation.RelDir) { $rel = $Invocation.RelDir + '\' + $name } else { $rel = $name }
                break
            }
            if ($p.Equals($b, [StringComparison]::OrdinalIgnoreCase) -and $Invocation.Mode -eq 'dironly') { $rel = $Invocation.RelDir; break }
        }
        if ($rel -and $wanted.Contains($rel)) {
            $d[$rel] = ('robocopy ERROR {0} ({1}) {2}: {3}' -f $e.code, $e.hex, $e.action, $e.message)
        }
    }
    return , $d
}

function Invoke-MigRobocopyCopy {
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)] $Plan)
    $cfg = $Ctx.Config
    $srcRoot = [string]$cfg.paths.sourceRoot
    $exe = [string](Get-MigConfigSetting -Config $cfg -Path 'copy.robocopy.executable')
    $okMax = [int](Get-MigConfigSetting -Config $cfg -Path 'copy.robocopy.successExitCodeMax')
    $forbidden = @(Get-MigConfigSetting -Config $cfg -Path 'copy.forbiddenFlags')
    $dry = [bool]$Plan['DryRun']
    $force = [bool]$Plan['Force']

    $logDir = Join-Path $cfg._resolved.logDir 'robocopy'
    Assert-MigPathNotUnderSource -Path $logDir -SourceRoot $srcRoot
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logPath = Join-Path $logDir ('{0}-{1}.log' -f $BatchId, $Ctx.RunId)

    $rels = Get-MigCopyPlanRelPaths -Ctx $Ctx -BatchId $BatchId -Plan $Plan
    $dirs = Get-MigCopyPlanDirectories -Ctx $Ctx -BatchId $BatchId -Plan $Plan
    $splitDirs = [string[]]@(Get-MigValue $Plan 'SplitDirs' @())
    $invs = New-MigRobocopyInvocations -Ctx $Ctx -RelPaths $rels -Directories $dirs -LogPath $logPath -DryRun $dry -Force $force -SplitDirs $splitDirs

    # Safety first: refuse the whole plan if any invocation is unsafe, before anything runs.
    foreach ($inv in $invs) {
        Assert-MigCopyFlagsSafe -Flags $inv.Arguments -ForbiddenFlags $forbidden
        Assert-MigPathNotUnderSource -Path $inv.Destination -SourceRoot $srcRoot
    }

    $copied = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[object]
    $codes = New-Object System.Collections.Generic.List[int]
    $sidecar = $null
    foreach ($inv in $invs) {
        $offset = 0L
        if ([System.IO.File]::Exists($logPath)) { $offset = (New-Object System.IO.FileInfo($logPath)).Length }
        $launchError = $null
        try { $code = [int](Invoke-MigRobocopyProcess -Executable $exe -Arguments $inv.Arguments) }
        catch { $code = -1; $launchError = $_.Exception.Message }
        $codes.Add($code)
        # Evidence (C-07): refresh the log checksum after every invocation, so the sidecar always matches the log.
        try { $sc = Write-MigLogChecksum -Path $logPath; if ($sc) { $sidecar = $sc } }
        catch { Write-Warning "Robocopy: could not write the checksum sidecar for '$logPath': $($_.Exception.Message)" }
        if ($code -ge 0 -and $code -le $okMax) {
            if ($inv.Mode -ne 'dironly') { foreach ($r in $inv.RelPaths) { $copied.Add($r) } }
            continue
        }
        $errs = ConvertFrom-MigRobocopyLog -Text (Read-MigRobocopyLogSlice -Path $logPath -Offset $offset)
        $byFile = Get-MigRobocopyFailedRelPaths -Invocation $inv -Errors $errs
        $generic = "robocopy exit code $code"
        if ($launchError) { $generic = "robocopy could not be started: $launchError" }
        foreach ($r in $inv.RelPaths) {
            if ($byFile.Count -eq 0) { $failed.Add(@{ rel_path = $r; error = $generic }) }
            elseif ($byFile.ContainsKey($r)) { $failed.Add(@{ rel_path = $r; error = $byFile[$r] + " (exit code $code)" }) }
            elseif ($inv.Mode -ne 'dironly') { $copied.Add($r) }
        }
    }
    $max = 0
    foreach ($c in $codes) { if ($c -gt $max) { $max = $c } }
    if ($codes -contains -1) { $max = -1 }
    return @{
        exit_code = $max; succeeded = ($failed.Count -eq 0); copied = $copied.ToArray(); failed = $failed.ToArray()
        log_path = $logPath; exit_codes = @($codes | Select-Object -Unique); log_files = @($logPath); log_sidecars = @($sidecar | Where-Object { $_ })
        invocations = $invs.Count; dry_run = $dry
    }
}

Register-MigProvider -Kind Copy -Name 'robocopy' -ScriptBlock {
    param($Ctx, $BatchId, $Plan)
    Invoke-MigRobocopyCopy -Ctx $Ctx -BatchId $BatchId -Plan $Plan
}
