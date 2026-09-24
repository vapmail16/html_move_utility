# Shared file-system scanner used by Inventory (source), Verify (target) and Delta.
# Walks a tree without following reparse points, then computes metadata + content hash + ACL hash in parallel.

function Test-MigIsDesktopEdition {
    <# Windows PowerShell 5.1 (.NET Framework path handling). Separate function so tests can mock it. #>
    return ($PSVersionTable.PSEdition -eq 'Desktop')
}

function Get-MigDirectoryChildren {
    <# Lists one directory (FileSystemInfo objects, unrolled; callers wrap in @()). Separate function so tests can mock it. #>
    param([Parameter(Mandatory = $true)][string] $Path)
    return (New-Object System.IO.DirectoryInfo($Path)).GetFileSystemInfos()
}

function Get-MigTreeEntries {
    <#
    Streams entries under $Root (optionally only under $RelDir). Output objects:
      @{ rel_path; kind = 'file'|'dir'; full }      for readable entries
      @{ rel_path; kind = 'error'; error }           for directories that could not be listed, and for
                                                     case-only duplicate names (see below)
    Reparse points (junctions/symlinks) are emitted as entries but never descended into.
    Children are sorted by name (ordinal, ignoring case), so output order is stable across runs and editions.
    Case-only duplicates inside one folder ('A.html' and 'a.html' on a case-sensitive source) would collapse
    into one record of the case-insensitive manifest. The first is emitted as normal; every other one is
    emitted as kind 'error' with error 'case_duplicate_of:<first name>' (never descended into), so it becomes
    a scan_error exception instead of being lost silently.
    Long paths: with $UseLongPath the \\?\ prefix is used. Safety net for Windows PowerShell 5.1 on legacy
    .NET path handling: if the FIRST enumeration with the prefix throws ArgumentException/NotSupportedException,
    it is retried once without the prefix (with a warning) and the rest of the walk runs without it.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [string] $RelDir = '',
        [string[]] $ExcludePatterns = @(),
        [bool] $IncludeDirectories = $true,
        [bool] $UseLongPath = $true
    )
    $excludes = @($ExcludePatterns | Where-Object { $_ } | ForEach-Object { New-Object regex($_, 'IgnoreCase') })
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push((ConvertTo-MigCanonicalRelPath $RelDir))
    $first = $true
    $cmp = [StringComparer]::OrdinalIgnoreCase
    while ($stack.Count -gt 0) {
        $rel = $stack.Pop()
        $plain = Join-MigPath -Root $Root -RelPath $rel
        $full = Get-MigLongPath -Path $plain -Enabled $UseLongPath
        try {
            try {
                $children = @(Get-MigDirectoryChildren -Path $full)
            } catch {
                $inner = $_.Exception
                while ($inner -is [System.Management.Automation.MethodInvocationException] -and $null -ne $inner.InnerException) { $inner = $inner.InnerException }
                $legacy = ($inner -is [System.ArgumentException] -or $inner -is [System.NotSupportedException])
                if (-not ($first -and $UseLongPath -and $full -ne $plain -and $legacy -and (Test-MigIsDesktopEdition))) { throw }
                Write-Warning ("Long-path prefix rejected by this .NET runtime ({0}); walking '{1}' without the \\?\ prefix. Paths over 260 characters may fail (enable long-path support or use PowerShell 7)." -f $inner.Message, $Root)
                $UseLongPath = $false
                $children = @(Get-MigDirectoryChildren -Path $plain)
            }
        } catch {
            @{ rel_path = $rel; kind = 'error'; error = $_.Exception.Message }
            $first = $false
            continue
        }
        $first = $false
        $names = New-Object string[] $children.Length
        for ($i = 0; $i -lt $children.Length; $i++) { $names[$i] = $children[$i].Name }
        # Non-generic overload: the generic one may convert (copy) the items array, leaving it unsorted.
        [Array]::Sort([Array]$names, [Array]$children, [System.Collections.IComparer]$cmp)
        $prevName = $null
        for ($i = 0; $i -lt $children.Length; $i++) {
            $c = $children[$i]
            $name = $names[$i]
            if ($rel) { $childRel = $rel + '\' + $name } else { $childRel = $name }
            $skip = $false
            foreach ($rx in $excludes) { if ($rx.IsMatch($childRel)) { $skip = $true; break } }
            if ($skip) { continue }
            if ($null -ne $prevName -and $cmp.Equals($prevName, $name)) {
                @{ rel_path = $childRel; kind = 'error'; error = ('case_duplicate_of:' + $prevName) }
                continue
            }
            $prevName = $name
            $isDir = ($c.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0
            if ($isDir) {
                if ($IncludeDirectories) { @{ rel_path = $childRel; kind = 'dir'; full = $c.FullName } }
                if (($c.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($childRel) }
            } else {
                @{ rel_path = $childRel; kind = 'file'; full = $c.FullName }
            }
        }
    }
}

function Get-MigHashBufferSize {
    <#
    Read buffer for hashing one file: min(file length, bufferSizeKB * 1024), at least 4096 bytes. A 1 MB buffer
    per small file was 2.2x slower (allocation per file). The scan worker inlines the same formula.
    #>
    param([long] $Length, [long] $BufferBytes)
    return [int][Math]::Max([long]4096, [Math]::Min($Length, $BufferBytes))
}

# Runs inside a runspace: must be self-contained. $Item = array of entries, $A = options hashtable.
$script:MigScanWorker = {
    param($Item, $A)
    $isDesktop = $PSVersionTable.PSEdition -eq 'Desktop'
    $sections = [System.Security.AccessControl.AccessControlSections]'Access'
    if ($A.AclIncludeOwner) { $sections = [System.Security.AccessControl.AccessControlSections]'Access, Owner' }
    function HashText([string] $t) {
        $h = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($t)))).Replace('-', '') } finally { $h.Dispose() }
    }
    foreach ($e in $Item) {
        $rec = [ordered]@{
            rel_path = $e.rel_path; kind = $e.kind; batch_id = $null; side = $A.Side
            size_bytes = $null; created_utc = $null; modified_utc = $null; attributes = $null
            acl_hash = $null; hash = $null; hash_algo = $null; scanned_utc = [DateTime]::UtcNow.ToString('o'); error = $null
        }
        try {
            if ($e.kind -eq 'dir') { $fsi = New-Object System.IO.DirectoryInfo($e.full) } else { $fsi = New-Object System.IO.FileInfo($e.full) }
            $fsi.Refresh()
            $rec.created_utc = $fsi.CreationTimeUtc.ToString('o')
            $rec.modified_utc = $fsi.LastWriteTimeUtc.ToString('o')
            $attrs = $fsi.Attributes
            foreach ($ign in $A.IgnoreAttributes) { $attrs = $attrs -band (-bnot [int][System.IO.FileAttributes]$ign) }
            $rec.attributes = ([System.IO.FileAttributes]$attrs).ToString()

            if ($e.kind -eq 'file') {
                $rec.size_bytes = $fsi.Length
                $alg = switch ($A.HashAlgorithm) {
                    'SHA384' { [System.Security.Cryptography.SHA384]::Create() }
                    'SHA512' { [System.Security.Cryptography.SHA512]::Create() }
                    default  { [System.Security.Cryptography.SHA256]::Create() }
                }
                # Same formula as Get-MigHashBufferSize (runspaces cannot call module functions).
                $bufSize = [int][Math]::Max([long]4096, [Math]::Min([long]$fsi.Length, [long]$A.BufferBytes))
                $fs = New-Object System.IO.FileStream($e.full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                    ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete), $bufSize, [System.IO.FileOptions]::SequentialScan)
                try { $rec.hash = ([BitConverter]::ToString($alg.ComputeHash($fs))).Replace('-', ''); $rec.hash_algo = $A.HashAlgorithm }
                finally { $fs.Dispose(); $alg.Dispose() }
            }

            if ($A.AclReader -eq 'windows') {
                if ($isDesktop) {
                    if ($e.kind -eq 'dir') { $sec = [System.IO.Directory]::GetAccessControl($e.full, $sections) }
                    else { $sec = [System.IO.File]::GetAccessControl($e.full, $sections) }
                } else {
                    $sec = [System.IO.FileSystemAclExtensions]::GetAccessControl($fsi, $sections)
                }
                switch ($A.AclMode) {
                    'account' {
                        $owner = ''
                        if ($A.AclIncludeOwner) { $owner = try { $sec.GetOwner([System.Security.Principal.NTAccount]).Value } catch { $sec.GetOwner([System.Security.Principal.SecurityIdentifier]).Value } }
                        $rules = foreach ($r in $sec.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])) {
                            '{0}|{1}|{2}|{3}|{4}|{5}' -f $r.IdentityReference.Value, [int]$r.FileSystemRights, $r.AccessControlType, $r.InheritanceFlags, $r.PropagationFlags, $r.IsInherited
                        }
                        $norm = 'O:' + $owner + ';P:' + $sec.AreAccessRulesProtected + ';' + ((@($rules) | Sort-Object) -join ';')
                    }
                    default {
                        $norm = $sec.GetSecurityDescriptorSddlForm($sections)
                        if ($A.AclMode -eq 'mapped' -and $A.SidMap) {
                            $norm = [regex]::Replace($norm, 'S-1-[0-9-]+', { param($m) if ($A.SidMap.ContainsKey($m.Value)) { $A.SidMap[$m.Value] } else { $m.Value } })
                        }
                    }
                }
                $rec.acl_hash = HashText $norm
            }
        } catch {
            $rec.error = $_.Exception.Message
        }
        $rec
    }
}

function Get-MigSidMap {
    <# Loads compare.acl.sidMapFile: JSON object { "<target SID>": "<source SID>" }. #>
    param([Parameter(Mandatory = $true)] $Config)
    $f = $Config.compare.acl.sidMapFile
    if ($Config.compare.acl.mode -ne 'mapped' -or [string]::IsNullOrWhiteSpace($f)) { return $null }
    $h = @{}
    $m = ConvertFrom-MigJson ([System.IO.File]::ReadAllText($f))
    foreach ($k in $m.Keys) { $h[$k] = [string]$m[$k] }
    return $h
}

function Get-MigScanRecords {
    <#
    Computes manifest records for $Entries (from Get-MigTreeEntries) in parallel.
    Error entries from the walk are passed through as records with kind 'error'.
    batch_id is NOT set here; callers assign it.
    #>
    param(
        [Parameter(Mandatory = $true)] $Ctx,
        [Parameter(Mandatory = $true)][ValidateSet('source', 'target')][string] $Side,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries,
        [int] $Threads = 0
    )
    $cfg = $Ctx.Config
    if ($Threads -lt 1) { $Threads = Get-MigEffectiveThreads -Ctx $Ctx -Default ([int]$cfg.inventory.threads) }
    $sidMap = $null
    if ($Side -eq 'target') { $sidMap = $Ctx.SidMap }
    $workerArgs = @{
        Side             = $Side
        HashAlgorithm    = ([string]$cfg.inventory.hash.algorithm).ToUpperInvariant()
        BufferBytes      = [int]$cfg.inventory.hash.bufferSizeKB * 1024
        AclReader        = $cfg.inventory.aclReader
        AclMode          = $cfg.compare.acl.mode
        AclIncludeOwner  = ($cfg.compare.acl.includeOwner -ne $false)
        SidMap           = $sidMap
        IgnoreAttributes = @($cfg.compare.ignoreAttributes)
    }
    $errors = @($Entries | Where-Object { $_.kind -eq 'error' } | ForEach-Object {
        [ordered]@{ rel_path = $_.rel_path; kind = 'error'; batch_id = $null; side = $Side; scanned_utc = Get-MigUtcNow; error = $_.error }
    })
    $work = @($Entries | Where-Object { $_.kind -ne 'error' })
    $chunkSize = [Math]::Max(1, [int]$cfg.inventory.chunkSize)
    $chunks = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $work.Count; $i += $chunkSize) {
        $slice = [object[]]@($work[$i..([Math]::Min($i + $chunkSize, $work.Count) - 1)])
        $chunks.Add($slice)
    }
    $records = @(Invoke-MigParallel -Items $chunks.ToArray() -ScriptBlock $script:MigScanWorker -Threads $Threads -Arguments $workerArgs)
    return @($records + $errors)
}

function Get-MigEffectiveThreads {
    <# Applies throttle windows (config.throttle) to a default thread count. #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][int] $Default, [DateTime] $Now = [DateTime]::Now)
    $w = Get-MigActiveThrottleWindow -Config $Ctx.Config -Now $Now
    $t = Get-MigValue $w 'threads'
    if ($t) { return [Math]::Min($Default, [int]$t) }
    return $Default
}

function Get-MigActiveThrottleWindow {
    param([Parameter(Mandatory = $true)] $Config, [DateTime] $Now = [DateTime]::Now)
    $t = $Config.throttle
    if (-not $t -or -not $t.enabled) { return $null }
    if ($t.timeZone -eq 'UTC') { $Now = $Now.ToUniversalTime() }
    $day = $Now.DayOfWeek.ToString().Substring(0, 3)
    foreach ($w in @($t.windows)) {
        if (@($w.days) -notcontains $day) { continue }
        $from = [TimeSpan]::Parse($w.from); $to = [TimeSpan]::Parse($w.to); $tod = $Now.TimeOfDay
        if (($from -le $to -and $tod -ge $from -and $tod -lt $to) -or ($from -gt $to -and ($tod -ge $from -or $tod -lt $to))) { return $w }
    }
    return $null
}
