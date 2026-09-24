@{
    RootModule           = 'NotificationMigration.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6f1c2b8e-3d4a-4c1e-9b7a-2e5f8d0c4a11'
    Author               = 'Notification Migration Team'
    Description          = 'Governed, auditable copy-and-verify migration of HTML notification archives (Robocopy + SHA-256 reconciliation). No third-party dependencies.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Migrate-Notifications'
        'Approve-MigrationGate'
        'Get-MigrationStatus'
        'Get-MigrationException'
        'Set-MigrationException'
        'Test-MigrationAuditLog'
        'Register-MigrationFreeze'
        'Approve-MigrationSignOff'
        'Register-MigrationRetention'
        'Export-MigrationManifest'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
