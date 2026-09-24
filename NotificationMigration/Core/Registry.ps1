# Provider registry. Each provider file in Providers/<Kind>/ calls Register-MigProvider at module load.
# Config selects providers by name, so new strategies/rules/formats are added without touching stages.
#
# Provider contracts (scriptblock parameters -> return value):
#   Batch    : param($RelPath, $Record, $Options)                  -> batch id (use ConvertTo-MigSafeBatchId)
#   Copy     : param($Ctx, $BatchId, $Plan)                         -> @{ succeeded; copied=[rel_path]; failed=[@{rel_path;error}];
#                                                                        exit_codes=[int]; log_files=[path]; dry_run }
#              $Plan = @{ RelPaths = [rel_path]; Directories = [rel dir]; DryRun = bool; Force = bool; SplitDirs = [rel dir] }
#              SplitDirs = folders too large for one work unit: copy by name lists, never list the folder.
#              Result may also carry log_sidecars=[path] and invocations=int.
#              Force = always re-copy even if the target looks identical (robocopy /IS /IT); used for retries of
#              mismatched files. Directories may appear in 'failed'.
#   Compare  : param($Ctx, $Source, $Target, $Options)              -> $null when equal, else mismatch detail string
#   HtmlRule : param($Ctx, $BatchId, $Side, $Root, $Records, $Options) -> findings [@{ rule; rel_path; severity; detail }]
#              Findings must be side-independent (no absolute paths) so source/target parity can be compared.
#              The stage passes shared per-chunk data in $Options (_htmlCache, _knownPaths, _sample); see
#              Providers/HtmlRule/HtmlRuleCommon.ps1 for that contract.
#   Report   : param($Ctx, $Report, $OutDir, $BaseName)             -> [written file paths]

$script:MigProviders = @{}

function Register-MigProvider {
    param([Parameter(Mandatory = $true)][ValidateSet('Batch', 'Copy', 'Compare', 'HtmlRule', 'Report')][string] $Kind,
          [Parameter(Mandatory = $true)][string] $Name,
          [Parameter(Mandatory = $true)][scriptblock] $ScriptBlock)
    if (-not $script:MigProviders.ContainsKey($Kind)) { $script:MigProviders[$Kind] = @{} }
    $script:MigProviders[$Kind][$Name] = $ScriptBlock
}

function Get-MigProvider {
    param([Parameter(Mandatory = $true)][string] $Kind, [Parameter(Mandatory = $true)][string] $Name)
    if (-not $script:MigProviders.ContainsKey($Kind) -or -not $script:MigProviders[$Kind].ContainsKey($Name)) {
        $known = @()
        if ($script:MigProviders.ContainsKey($Kind)) { $known = @($script:MigProviders[$Kind].Keys | Sort-Object) }
        throw "No $Kind provider named '$Name'. Registered: $($known -join ', ')"
    }
    return $script:MigProviders[$Kind][$Name]
}

function Get-MigProviderNames {
    param([Parameter(Mandatory = $true)][string] $Kind)
    if (-not $script:MigProviders.ContainsKey($Kind)) { return @() }
    return @($script:MigProviders[$Kind].Keys | Sort-Object)
}
