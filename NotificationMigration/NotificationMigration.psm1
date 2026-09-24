# NotificationMigration module loader.
# Load order: Core (contracts + services) -> Providers (register themselves) -> Stages -> Public commands.
Set-StrictMode -Version 2.0

$script:MigModuleRoot = $PSScriptRoot
$script:MigModuleVersion = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'NotificationMigration.psd1')).ModuleVersion

$coreOrder = @('Common', 'Safety', 'Config', 'Registry', 'Parallel', 'Store', 'Audit', 'Scanner', 'Gates', 'Context')
foreach ($name in $coreOrder) { . (Join-Path $PSScriptRoot "Core/$name.ps1") }

foreach ($folder in @('Providers', 'Stages', 'Public')) {
    $dir = Join-Path $PSScriptRoot $folder
    if (Test-Path -LiteralPath $dir) {
        Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -Recurse | Sort-Object FullName | ForEach-Object { . $_.FullName }
    }
}
