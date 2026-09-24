# Copy provider 'dotnet': System.IO.File.Copy per file. Intended for tests and non-Windows hosts;
# production copies should use 'robocopy' (FR-03). Same result contract as every Copy provider:
#   @{ exit_code; succeeded; copied = [rel_path]; failed = [@{ rel_path; error }]; log_path; exit_codes; log_files }
# Preserves CreationTimeUtc, LastWriteTimeUtc and Attributes (and the DACL on Windows when ACLs are in use).
# Only files named in the plan are ever overwritten; nothing on the target is deleted; nothing under
# sourceRoot is ever opened for writing.

$script:MigDotNetWarnedRuns = @{}

function Copy-MigSecurityDotNet {
    <#
    Copies the DACL (like robocopy /COPY:S) and, with $IncludeOwner, the owner (/COPY:O) from $Source to $Target.
    Windows only. Setting an owner other than yourself needs SeRestorePrivilege; failures surface as copy failures.
    #>
    param([Parameter(Mandatory = $true)][string] $Source, [Parameter(Mandatory = $true)][string] $Target, [bool] $IsDirectory, [bool] $IncludeOwner = $true)
    $sections = [System.Security.AccessControl.AccessControlSections]::Access
    if ($IncludeOwner) { $sections = $sections -bor [System.Security.AccessControl.AccessControlSections]::Owner }
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        if ($IsDirectory) { [System.IO.Directory]::SetAccessControl($Target, [System.IO.Directory]::GetAccessControl($Source, $sections)) }
        else { [System.IO.File]::SetAccessControl($Target, [System.IO.File]::GetAccessControl($Source, $sections)) }
    } else {
        if ($IsDirectory) {
            $sec = [System.IO.FileSystemAclExtensions]::GetAccessControl((New-Object System.IO.DirectoryInfo($Source)), $sections)
            [System.IO.FileSystemAclExtensions]::SetAccessControl((New-Object System.IO.DirectoryInfo($Target)), $sec)
        } else {
            $sec = [System.IO.FileSystemAclExtensions]::GetAccessControl((New-Object System.IO.FileInfo($Source)), $sections)
            [System.IO.FileSystemAclExtensions]::SetAccessControl((New-Object System.IO.FileInfo($Target)), $sec)
        }
    }
}

function Copy-MigFileDotNet {
    <# Copies one file with metadata. $Source/$Target are native (optionally \\?\-prefixed) full paths. #>
    param([Parameter(Mandatory = $true)][string] $Source, [Parameter(Mandatory = $true)][string] $Target,
          [Parameter(Mandatory = $true)][string] $SourceRoot, [bool] $CopyAcl, [bool] $IncludeOwner = $true)
    Assert-MigPathNotUnderSource -Path $Target -SourceRoot $SourceRoot
    $si = New-Object System.IO.FileInfo($Source)
    if (-not $si.Exists) { throw "Source file not found: $Source" }
    $parent = [System.IO.Path]::GetDirectoryName($Target)
    if ($parent -and -not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    if ([System.IO.File]::Exists($Target)) {
        # A read-only/hidden/system target (from an earlier copy of this same planned file) blocks overwrite.
        [System.IO.File]::SetAttributes($Target, [System.IO.FileAttributes]::Normal)
    }
    [System.IO.File]::Copy($Source, $Target, $true)
    [System.IO.File]::SetCreationTimeUtc($Target, $si.CreationTimeUtc)
    [System.IO.File]::SetLastWriteTimeUtc($Target, $si.LastWriteTimeUtc)
    if ($CopyAcl) { Copy-MigSecurityDotNet -Source $Source -Target $Target -IsDirectory $false -IncludeOwner $IncludeOwner }
    [System.IO.File]::SetAttributes($Target, $si.Attributes)
}

function Set-MigDirectoryMetadataDotNet {
    <# Applies source directory timestamps/attributes (and DACL) to the target directory. #>
    param([Parameter(Mandatory = $true)][string] $Source, [Parameter(Mandatory = $true)][string] $Target, [bool] $CopyAcl, [bool] $IncludeOwner = $true)
    $si = New-Object System.IO.DirectoryInfo($Source)
    if (-not $si.Exists) { return }
    if ($CopyAcl) { Copy-MigSecurityDotNet -Source $Source -Target $Target -IsDirectory $true -IncludeOwner $IncludeOwner }
    [System.IO.Directory]::SetCreationTimeUtc($Target, $si.CreationTimeUtc)
    [System.IO.Directory]::SetLastWriteTimeUtc($Target, $si.LastWriteTimeUtc)
    $ti = New-Object System.IO.DirectoryInfo($Target)
    if ($ti.Attributes -ne $si.Attributes) { $ti.Attributes = $si.Attributes }
}

function Invoke-MigDotNetCopy {
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)] $Plan)
    if (-not $script:MigDotNetWarnedRuns.ContainsKey([string]$Ctx.RunId)) {
        $script:MigDotNetWarnedRuns[[string]$Ctx.RunId] = $true
        Write-Warning "copy.engine 'dotnet' is intended for testing and non-Windows hosts. Use 'robocopy' in production (FR-03)."
    }
    $cfg = $Ctx.Config
    $srcRoot = [string]$cfg.paths.sourceRoot
    $tgtRoot = [string]$cfg.paths.targetRoot
    $useLong = [bool](Get-MigConfigSetting -Config $cfg -Path 'paths.useLongPathPrefix')
    $copyAcl = (Test-MigIsWindows) -and ((Get-MigConfigSetting -Config $cfg -Path 'inventory.aclReader') -eq 'windows')
    $includeOwner = ((Get-MigConfigSetting -Config $cfg -Path 'compare.acl.includeOwner') -ne $false)
    Assert-MigPathNotUnderSource -Path $tgtRoot -SourceRoot $srcRoot

    $rels = Get-MigCopyPlanRelPaths -Ctx $Ctx -BatchId $BatchId -Plan $Plan
    $dirs = Get-MigCopyPlanDirectories -Ctx $Ctx -BatchId $BatchId -Plan $Plan
    if ($Plan['DryRun']) {
        return @{ exit_code = 0; succeeded = $true; copied = @($rels); failed = @(); log_path = $null; exit_codes = @(0); log_files = @(); dry_run = $true }
    }

    $copied = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[object]
    $failedDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($d in ($dirs | Sort-Object { Get-MigRelPathDepth $_ })) {
        $t = Get-MigLongPath -Path (Join-MigPath -Root $tgtRoot -RelPath $d) -Enabled $useLong
        try {
            Assert-MigPathNotUnderSource -Path $t -SourceRoot $srcRoot
            if (-not [System.IO.Directory]::Exists($t)) { [void][System.IO.Directory]::CreateDirectory($t) }
        } catch {
            [void]$failedDirs.Add($d)
            $failed.Add(@{ rel_path = $d; error = $_.Exception.Message })
        }
    }

    foreach ($rel in $rels) {
        $s = Get-MigLongPath -Path (Join-MigPath -Root $srcRoot -RelPath $rel) -Enabled $useLong
        $t = Get-MigLongPath -Path (Join-MigPath -Root $tgtRoot -RelPath $rel) -Enabled $useLong
        try {
            Copy-MigFileDotNet -Source $s -Target $t -SourceRoot $srcRoot -CopyAcl $copyAcl -IncludeOwner $includeOwner
            $copied.Add($rel)
        } catch {
            $failed.Add(@{ rel_path = $rel; error = $_.Exception.Message })
        }
    }

    # Directory timestamps change when children are created, so apply them last, deepest first.
    $stamp = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $dirs) { if (-not $failedDirs.Contains($d)) { [void]$stamp.Add($d) } }
    foreach ($rel in $copied) {
        $p = Get-MigParentRelPath $rel
        while ($p) { [void]$stamp.Add($p); $p = Get-MigParentRelPath $p }
    }
    $planDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $dirs) { [void]$planDirs.Add($d) }
    foreach ($d in (@($stamp) | Sort-Object { Get-MigRelPathDepth $_ } -Descending)) {
        $s = Get-MigLongPath -Path (Join-MigPath -Root $srcRoot -RelPath $d) -Enabled $useLong
        $t = Get-MigLongPath -Path (Join-MigPath -Root $tgtRoot -RelPath $d) -Enabled $useLong
        try {
            Assert-MigPathNotUnderSource -Path $t -SourceRoot $srcRoot
            if ([System.IO.Directory]::Exists($t)) { Set-MigDirectoryMetadataDotNet -Source $s -Target $t -CopyAcl $copyAcl -IncludeOwner $includeOwner }
        } catch {
            if ($planDirs.Contains($d)) { $failed.Add(@{ rel_path = $d; error = $_.Exception.Message }) }
        }
    }

    $code = 0
    if ($failed.Count -gt 0) { $code = 8 }
    return @{
        exit_code = $code; succeeded = ($failed.Count -eq 0); copied = $copied.ToArray(); failed = $failed.ToArray()
        log_path = $null; exit_codes = @($code); log_files = @()
    }
}

Register-MigProvider -Kind Copy -Name 'dotnet' -ScriptBlock {
    param($Ctx, $BatchId, $Plan)
    Invoke-MigDotNetCopy -Ctx $Ctx -BatchId $BatchId -Plan $Plan
}
