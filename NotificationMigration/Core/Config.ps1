# Layered configuration: config/defaults.json  <-  migration.config.json  <-  -Override hashtable.
# Nothing behavioural is hardcoded in stages; they read everything from the merged config.

$script:MigKnownStages = @('Inventory', 'Batching', 'Copy', 'Verify', 'Reconcile', 'HtmlChecks', 'Delta', 'Report')

function Get-MigrationConfig {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [System.Collections.IDictionary] $Override
    )
    $defaultsPath = Join-Path $script:MigModuleRoot 'config/defaults.json'
    $defaults = ConvertFrom-MigJson ([System.IO.File]::ReadAllText($defaultsPath))

    $fullPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $raw = [System.IO.File]::ReadAllText($fullPath)
    $userCfg = ConvertFrom-MigJson $raw

    $unknown = @(Get-MigUnknownConfigKeys -Defaults $defaults -Config $userCfg)
    if ($Override) { $unknown += @(Get-MigUnknownConfigKeys -Defaults $defaults -Config $Override) }
    if ($unknown.Count -gt 0) { throw ("Invalid configuration: unknown key(s) (typo, or not supported): " + ($unknown -join ', ')) }
    $cfg = Merge-MigHashtable -Base $defaults -Override $userCfg
    if ($Override) { $cfg = Merge-MigHashtable -Base $cfg -Override $Override }

    $cfg['_meta'] = [ordered]@{
        configPath = $fullPath
        configHash = Get-MigStringHash -Text $raw
        loadedUtc  = Get-MigUtcNow
    }
    Resolve-MigConfigPaths -Config $cfg
    Assert-MigConfigValid -Config $cfg
    return $cfg
}

# Sections whose child keys are provider-specific and therefore not fixed by defaults.json.
$script:MigOpenConfigSections = @('batching.options')

function Get-MigUnknownConfigKeys {
    <# Keys in $Config that do not exist in defaults.json (typos would otherwise be silently ignored). #>
    param([System.Collections.IDictionary] $Defaults, [System.Collections.IDictionary] $Config, [string] $Prefix = '')
    foreach ($k in @($Config.Keys)) {
        $path = if ($Prefix) { "$Prefix.$k" } else { [string]$k }
        if ($path -eq '_meta' -or $path -eq '_resolved') { continue }
        if (-not $Defaults.Contains($k)) {
            # A custom HtmlRule provider may bring its own rule section.
            if ($Prefix -eq 'htmlChecks.rules') { continue }
            $path
            continue
        }
        if ($script:MigOpenConfigSections -contains $path) { continue }
        if ($Defaults[$k] -is [System.Collections.IDictionary] -and $Config[$k] -is [System.Collections.IDictionary]) {
            Get-MigUnknownConfigKeys -Defaults $Defaults[$k] -Config $Config[$k] -Prefix $path
        }
    }
}

function Resolve-MigFullPath {
    <# Absolute path resolved against the PowerShell location (not the .NET process cwd). UNC/rooted paths pass through normalised. #>
    param([Parameter(Mandatory = $true)][string] $Path)
    try { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    catch { throw "Cannot resolve path '$Path' (drive not mapped or provider missing?): $($_.Exception.Message)" }
}

function Resolve-MigConfigPaths {
    <#
    Makes sourceRoot / targetRoot / workDir / sidMapFile absolute at load time (so later .NET calls and
    Set-Location cannot change their meaning), then storeDir / reportDir / logDir relative to workDir.
    #>
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Config)
    $p = $Config.paths
    foreach ($key in @('sourceRoot', 'targetRoot', 'workDir')) {
        if (-not [string]::IsNullOrWhiteSpace($p[$key])) { $p[$key] = Resolve-MigFullPath $p[$key] }
    }
    $acl = $Config.compare.acl
    if ($acl -and -not [string]::IsNullOrWhiteSpace($acl.sidMapFile)) { $acl.sidMapFile = Resolve-MigFullPath $acl.sidMapFile }
    $resolved = [ordered]@{}
    foreach ($key in @('storeDir', 'reportDir', 'logDir')) {
        $v = $p[$key]
        if ([string]::IsNullOrWhiteSpace($v) -or [string]::IsNullOrWhiteSpace($p.workDir)) { $resolved[$key] = $v; continue }
        if ([System.IO.Path]::IsPathRooted($v)) { $resolved[$key] = $v }
        else { $resolved[$key] = Join-MigPath -Root $p.workDir -RelPath $v }
    }
    $Config['_resolved'] = $resolved
}

function Assert-MigConfigValid {
    <# Throws one error listing every problem, so the operator can fix the config in one pass. #>
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Config)
    $errors = New-Object System.Collections.Generic.List[string]
    $p = $Config.paths

    foreach ($k in @('sourceRoot', 'targetRoot', 'workDir')) {
        if ([string]::IsNullOrWhiteSpace($p[$k])) { $errors.Add("paths.$k is required.") }
    }
    if (-not [string]::IsNullOrWhiteSpace($p.sourceRoot) -and -not [string]::IsNullOrWhiteSpace($p.targetRoot)) {
        if (Test-MigPathUnder -Path $p.targetRoot -Root $p.sourceRoot) { $errors.Add('paths.targetRoot must not be inside sourceRoot.') }
        if (Test-MigPathUnder -Path $p.sourceRoot -Root $p.targetRoot) { $errors.Add('paths.sourceRoot must not be inside targetRoot.') }
    }
    if (-not [string]::IsNullOrWhiteSpace($p.sourceRoot)) {
        foreach ($k in @('workDir')) {
            if (-not [string]::IsNullOrWhiteSpace($p[$k]) -and (Test-MigPathUnder -Path $p[$k] -Root $p.sourceRoot)) { $errors.Add("paths.$k must not be inside sourceRoot.") }
        }
        foreach ($k in @('storeDir', 'reportDir', 'logDir')) {
            $v = $Config._resolved[$k]
            if (-not [string]::IsNullOrWhiteSpace($v) -and (Test-MigPathUnder -Path $v -Root $p.sourceRoot)) { $errors.Add("paths.$k must not be inside sourceRoot.") }
        }
    }

    foreach ($s in @($Config.pipeline.stages)) { if ($script:MigKnownStages -notcontains $s) { $errors.Add("pipeline.stages: unknown stage '$s'.") } }
    foreach ($g in @($Config.pipeline.gates)) { if ($script:MigKnownStages -notcontains $g) { $errors.Add("pipeline.gates: unknown stage '$g'.") } }

    $inv = $Config.inventory
    if (@('windows', 'none') -notcontains $inv.aclReader) { $errors.Add("inventory.aclReader must be 'windows' or 'none'.") }
    if ([int]$inv.threads -lt 1) { $errors.Add('inventory.threads must be >= 1.') }
    if ([int]$inv.chunkSize -lt 1) { $errors.Add('inventory.chunkSize must be >= 1.') }
    if (@('SHA256', 'SHA384', 'SHA512') -notcontains ([string]$inv.hash.algorithm).ToUpperInvariant()) { $errors.Add('inventory.hash.algorithm must be SHA256, SHA384 or SHA512.') }

    # Provider-backed settings are validated against what is registered, so adding a provider needs no edit here.
    $batchNames = Get-MigProviderNames -Kind Batch
    if ([string]::IsNullOrWhiteSpace($Config.batching.strategy)) { $errors.Add('batching.strategy is required.') }
    elseif ($batchNames.Count -gt 0 -and $batchNames -notcontains $Config.batching.strategy) { $errors.Add("batching.strategy '$($Config.batching.strategy)' is not a registered Batch provider ($($batchNames -join ', ')).") }
    $bo = $Config.batching.options
    switch ($Config.batching.strategy) {
        'regex' {
            $pattern = [string](Get-MigValue $bo 'pattern')
            if ([string]::IsNullOrWhiteSpace($pattern)) { $errors.Add('batching.options.pattern is required for the regex strategy.') }
            else { try { [void](New-Object regex($pattern)) } catch { $errors.Add("batching.options.pattern does not compile: $($_.Exception.Message)") } }
            if ([string]::IsNullOrWhiteSpace([string](Get-MigValue $bo 'template'))) { $errors.Add('batching.options.template is required for the regex strategy.') }
        }
        'folderDepth' { if ([int](Get-MigValue $bo 'depth' 0) -lt 1) { $errors.Add('batching.options.depth must be >= 1 for the folderDepth strategy.') } }
        { @('year', 'yearMonth') -contains $_ } {
            $df = Get-MigValue $bo 'dateField'
            if ($null -ne $df -and @('modified_utc', 'created_utc') -notcontains $df) { $errors.Add("batching.options.dateField must be 'modified_utc' or 'created_utc'.") }
        }
    }
    if ($inv.Contains('manifestCacheRecords') -and $inv.manifestCacheRecords -isnot [int] -and $inv.manifestCacheRecords -isnot [long]) { $errors.Add('inventory.manifestCacheRecords must be an integer (records held in the manifest index cache; <= 0 = unlimited).') }
    $copyNames = Get-MigProviderNames -Kind Copy
    if ($copyNames.Count -gt 0 -and $copyNames -notcontains $Config.copy.engine) { $errors.Add("copy.engine '$($Config.copy.engine)' is not a registered Copy provider ($($copyNames -join ', ')).") }

    $cp = $Config.copy
    if ([int]$cp.maxRetries -lt 0) { $errors.Add('copy.maxRetries must be >= 0.') }
    if ($cp.engine -eq 'robocopy') {
        try { Assert-MigCopyFlagsSafe -Flags @($cp.robocopy.flags) -ForbiddenFlags @($cp.forbiddenFlags) }
        catch { $errors.Add($_.Exception.Message) }
        foreach ($f in @($cp.robocopy.flags)) {
            if ($f -match '^/MT(:|$)') { $errors.Add("copy.robocopy.flags: set threads via copy.robocopy.threads, not '$f'.") }
            if ($f -match '^/(LOG|LOG\+|UNILOG|UNILOG\+)(:|$)') { $errors.Add("copy.robocopy.flags: logging is managed by the tool, remove '$f'.") }
        }
    }

    if ($cp.engine -eq 'robocopy' -and $cp.robocopy) {
        try { Assert-MigCopyFlagsAllowed -Flags @($cp.robocopy.flags) -AllowedFlags @($cp.robocopy.allowedFlags) } catch { $errors.Add($_.Exception.Message) }
    }
    # Cross-checks: settings that silently contradict each other.
    $aclCompared = (@($Config.compare.fileFields) + @($Config.compare.dirFields)) -contains 'acl'
    if ($aclCompared -and $inv.aclReader -eq 'none') { $errors.Add("compare fields include 'acl' but inventory.aclReader is 'none' (ACLs would never be compared). Remove 'acl' or set aclReader 'windows'.") }
    if ($aclCompared -and (Get-MigValue $Config.compare.acl 'includeOwner' $true) -and $cp.engine -eq 'robocopy') {
        $copyFlag = @($cp.robocopy.flags | Where-Object { $_ -match '^/COPY(ALL|:)' }) | Select-Object -First 1
        if (-not $copyFlag -or ($copyFlag -notmatch '^/COPYALL$' -and $copyFlag -notmatch '^/COPY:[A-Z]*O')) {
            $errors.Add("compare.acl.includeOwner is true but copy.robocopy.flags do not copy the owner (need /COPY:...O or /COPYALL).")
        }
    }
    foreach ($req in @('exists', 'size', 'hash')) {
        if (@($Config.compare.fileFields) -notcontains $req) { $errors.Add("compare.fileFields must include '$req' (acceptance requires byte-identical copies).") }
    }
    $rsCfg = $Config.htmlChecks.rules.renderSample
    if ($rsCfg -and @('parse', 'edgeHeadless') -notcontains (Get-MigValue $rsCfg 'renderer' 'parse')) { $errors.Add("htmlChecks.rules.renderSample.renderer must be 'parse' or 'edgeHeadless'.") }
    $al = $Config.htmlChecks.rules.absoluteLinks
    if ($al -and (Get-MigValue $al 'enabled' $false) -and @(@(Get-MigValue $al 'oldHosts' @()) + @(Get-MigValue $al 'oldUncPrefixes' @()) + @(Get-MigValue $al 'oldIpAddresses' @()) | Where-Object { $_ }).Count -eq 0) {
        Write-Warning 'htmlChecks.rules.absoluteLinks is enabled but oldHosts, oldUncPrefixes and oldIpAddresses are all empty: it cannot find anything. Set the old server names.'
    }
    foreach ($k in @('pipeline.dryRunStages')) {
        foreach ($st in @($Config.pipeline.dryRunStages)) { if (@('Inventory', 'Batching', 'Report', 'Delta') -notcontains $st) { $errors.Add("pipeline.dryRunStages: '$st' is not allowed (only read-only stages: Inventory, Batching, Report, Delta).") } }
    }

    $allowedFileFields = Get-MigProviderNames -Kind Compare
    if ($allowedFileFields.Count -eq 0) { $allowedFileFields = @('exists', 'size', 'hash', 'created', 'modified', 'attributes', 'acl') }
    foreach ($f in @($Config.compare.fileFields)) { if ($allowedFileFields -notcontains $f) { $errors.Add("compare.fileFields: unknown field '$f'.") } }
    foreach ($f in @($Config.compare.dirFields)) { if ($allowedFileFields -notcontains $f) { $errors.Add("compare.dirFields: unknown field '$f'.") } }
    if ([double]$Config.compare.timestampToleranceSec -lt 0) { $errors.Add('compare.timestampToleranceSec must be >= 0.') }
    $acl = $Config.compare.acl
    if (@('sid', 'account', 'mapped') -notcontains $acl.mode) { $errors.Add("compare.acl.mode must be 'sid', 'account' or 'mapped'.") }
    if ($acl.mode -eq 'mapped' -and [string]::IsNullOrWhiteSpace($acl.sidMapFile)) { $errors.Add("compare.acl.sidMapFile is required when compare.acl.mode is 'mapped'.") }

    foreach ($f in @(Get-MigValue $inv 'detectBy' @())) { if (@('size', 'modified', 'created', 'attributes', 'hash') -notcontains $f) { $errors.Add("inventory.detectBy: unknown field '$f'.") } }
    foreach ($f in @($Config.delta.detectBy)) { if (@('size', 'modified', 'created', 'attributes', 'hash') -notcontains $f) { $errors.Add("delta.detectBy: unknown field '$f'.") } }

    $rs = $Config.htmlChecks.rules.renderSample
    if ($rs -and ([double]$rs.rate -lt 0 -or [double]$rs.rate -gt 1)) { $errors.Add('htmlChecks.rules.renderSample.rate must be between 0 and 1.') }

    $rp = $Config.report
    if ($null -ne (Get-MigValue $rp 'htmlMaxRows') -and (Get-MigValue $rp 'htmlMaxRows') -isnot [int] -and (Get-MigValue $rp 'htmlMaxRows') -isnot [long]) { $errors.Add('report.htmlMaxRows must be an integer (0 or less = no cap).') }
    foreach ($k in @('finalIncludeDetails', 'finalTargetSweep')) {
        if ($null -ne (Get-MigValue $rp $k) -and (Get-MigValue $rp $k) -isnot [bool]) { $errors.Add("report.$k must be true or false.") }
    }
    $hc = $Config.htmlChecks
    if ($null -ne (Get-MigValue $hc 'chunkSize') -and [int](Get-MigValue $hc 'chunkSize') -lt 1) { $errors.Add('htmlChecks.chunkSize must be >= 1.') }
    $hr = Get-MigValue $hc 'rules' @{}
    if ($null -ne (Get-MigValue (Get-MigValue $hr 'renderSample') 'strictRenderer') -and (Get-MigValue (Get-MigValue $hr 'renderSample') 'strictRenderer') -isnot [bool]) { $errors.Add('htmlChecks.rules.renderSample.strictRenderer must be true or false.') }
    foreach ($rule in @('malformed', 'linkedAssets', 'absoluteLinks')) {
        $mb = Get-MigValue (Get-MigValue $hr $rule) 'maxBytesToParse'
        if ($null -ne $mb -and [long]$mb -lt 0) { $errors.Add("htmlChecks.rules.$rule.maxBytesToParse must be null or >= 0.") }
    }
    $rn = Get-MigValue (Get-MigValue $hr 'fileName') 'reservedNames'
    if ($null -ne $rn -and $rn -isnot [System.Collections.IList]) { $errors.Add('htmlChecks.rules.fileName.reservedNames must be a list.') }
    $reportNames = Get-MigProviderNames -Kind Report
    if ($reportNames.Count -eq 0) { $reportNames = @('csv', 'html', 'json') }
    foreach ($f in @($Config.report.formats)) { if ($reportNames -notcontains $f) { $errors.Add("report.formats: unknown format '$f' (registered: $($reportNames -join ', ')).") } }
    $ruleNames = Get-MigProviderNames -Kind HtmlRule
    if ($ruleNames.Count -gt 0 -and $Config.htmlChecks.rules) {
        foreach ($r in @($Config.htmlChecks.rules.Keys)) { if ($ruleNames -notcontains $r) { $errors.Add("htmlChecks.rules: '$r' is not a registered HtmlRule provider.") } }
    }

    if ($null -ne $cp.chunkSize -and [int]$cp.chunkSize -lt 1) { $errors.Add('copy.chunkSize must be >= 1.') }
    $sff = Get-MigValue $cp 'splitFolderFactor'
    if ($null -ne $sff -and (($sff -isnot [int] -and $sff -isnot [long]) -or [long]$sff -lt 1)) { $errors.Add('copy.splitFolderFactor must be an integer >= 1.') }
    $cs = Get-MigValue $Config.reconcile 'compactStore'
    if ($null -ne $cs -and $cs -isnot [bool]) { $errors.Add('reconcile.compactStore must be true or false.') }
    if ($cp.robocopy) {
        if ($null -ne $cp.robocopy.maxCommandLineChars -and ([int]$cp.robocopy.maxCommandLineChars -lt 512 -or [int]$cp.robocopy.maxCommandLineChars -gt 30000)) { $errors.Add('copy.robocopy.maxCommandLineChars must be 512-30000.') }
        if ([int]$cp.robocopy.threads -lt 1 -or [int]$cp.robocopy.threads -gt 128) { $errors.Add('copy.robocopy.threads must be 1-128.') }
        if ([int]$cp.robocopy.successExitCodeMax -lt 0 -or [int]$cp.robocopy.successExitCodeMax -gt 7) { $errors.Add('copy.robocopy.successExitCodeMax must be 0-7 (8+ always means failure).') }
    }
    $th = $Config.throttle
    if ($th) {
        if (@('Local', 'UTC') -notcontains $th.timeZone) { $errors.Add("throttle.timeZone must be 'Local' or 'UTC'.") }
        foreach ($w in @($th.windows)) {
            foreach ($t in @($w.from, $w.to)) { $ts = [TimeSpan]::Zero; if (-not [TimeSpan]::TryParse([string]$t, [ref]$ts)) { $errors.Add("throttle.windows: invalid time '$t' (use HH:mm).") } }
            foreach ($d in @($w.days)) { if (@('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun') -notcontains $d) { $errors.Add("throttle.windows: invalid day '$d'.") } }
            if ($null -ne (Get-MigValue $w 'threads') -and [int](Get-MigValue $w 'threads') -lt 1) { $errors.Add('throttle.windows.threads must be >= 1.') }
        }
    }
    if ($null -ne $acl.includeOwner -and $acl.includeOwner -isnot [bool]) { $errors.Add('compare.acl.includeOwner must be true or false.') }

    if ($errors.Count -gt 0) {
        throw ("Invalid configuration:`n - " + ($errors -join "`n - "))
    }
}
