# NotificationMigration — Architecture & Contracts

Source spec: `../Notification_Migration_Requirements.md`. This file is the contract every module is built against.

## Hard rules
- **Copy only.** Nothing under `paths.sourceRoot` is ever created, modified or deleted. Every write path goes through `Assert-MigPathNotUnderSource`.
- **Nothing hardcoded.** Every behavioural value comes from config (`config/defaults.json` merged with the user's `migration.config.json`). Add new keys to `defaults.json` **and** validate them in `Core/Config.ps1`.
- **No third-party dependencies.** Only built-in PowerShell, .NET and Robocopy.
- **Windows PowerShell 5.1 compatible** (and PowerShell 7). No `?:`, `??`, `?.`, `-AsHashtable` (except behind a version check), `ForEach-Object -Parallel`, `using namespace` after code, or `Get-FileHash` over long paths. `Set-StrictMode -Version 2.0` is on.
- **No `.GetNewClosure()`** inside the module (it hides private module functions).
- Timestamps are UTC ISO-8601 (`Get-MigUtcNow`, `.ToString('o')`).

## Layout
```
NotificationMigration/
  NotificationMigration.psd1/.psm1   loader: Core -> Providers -> Stages -> Public
  config/defaults.json               every default value
  Core/        Common Safety Config Registry Parallel Store Audit Scanner Gates Context
  Providers/   Batch/ Copy/ Compare/ HtmlRule/ Report/   (each file calls Register-MigProvider)
  Stages/      Inventory Batching Copy Verify Reconcile HtmlChecks Delta Report
  Public/      Commands.ps1 (Migrate-Notifications, Approve-MigrationGate, Get-MigrationStatus, ...)
tests/Unit/  tests/Integration/
tools/New-SyntheticDataset.ps1
```

## Run context `$Ctx`
`Config` (merged hashtable; resolved dirs in `$Ctx.Config._resolved.storeDir|reportDir|logDir`), `Store`, `Audit`, `RunId`, `Operator`, `DryRun`, `SidMap`.
Create in tests with `New-MigContext -ConfigPath <file> [-Override @{...}] [-DryRun] [-Operator 'x']`; close with `Close-MigContext`.

## Stage functions (called by `Invoke-MigStageRun`, which handles gates + stage events + audit)
| Function | Scope | Returns |
|---|---|---|
| `Invoke-MigStageInventory -Ctx` | global | summary hashtable |
| `Invoke-MigStageBatching -Ctx` | global | summary |
| `Invoke-MigStageCopy -Ctx -BatchId` | batch | summary |
| `Invoke-MigStageVerify -Ctx -BatchId` | batch | summary |
| `Invoke-MigStageReconcile -Ctx -BatchId` | batch | summary (must include `passed` bool) |
| `Invoke-MigStageHtmlChecks -Ctx -BatchId` | batch | summary (must include `parity` bool) |
| `Invoke-MigStageDelta -Ctx` | global | summary (must include `affected_batches`) |
| `Invoke-MigStageReport -Ctx [-BatchId] [-Final]` | batch or global | summary (must include `files` written) |

Stage functions must **not** call gate/stage-event functions themselves. They write audit events for notable actions with `Write-MigAudit -Audit $Ctx.Audit -Operator $Ctx.Operator -Event '<stage>.<what>' -Data @{...}`.

## Store (Core/Store.ps1) — JSON lines, append-only, latest record per key wins
- Manifest record (`Write-MigManifest` / `Read-MigManifest` → `Dictionary[rel_path]`, case-insensitive):
  `rel_path, kind ('file'|'dir'|'error'), batch_id, side, size_bytes, created_utc, modified_utc, attributes, acl_hash, hash, hash_algo, scanned_utc, error, deleted`
- `rel_path` is canonical: `\`-separated, relative to the root, no leading `\`. Use `Join-MigPath -Root -RelPath` to get a native full path.
- File status (`Add-MigFileStatus` / `Get-MigFileStatus`): `pending | copied | verified | mismatch | exception`. `attempts` = number of `copied` events.
- Batch info (`Set-MigBatchInfo -BatchId -Data @{...}` merges keys; `Get-MigBatches`). Keys used:
  - `plan` (Batching): `@{ file_count; dir_count; total_bytes; zero_byte_count; error_count }`
  - `state`: `planned | copying | copied | verified | reconciled | mismatch | delta_pending`
  - `copy` (Copy): `@{ files_attempted; files_copied; files_failed; exit_codes; log_files }`
  - `verify` (Verify): `@{ files; dirs; bytes; errors }`
  - `reconcile` (Reconcile): `@{ passed; run_id; source_files; target_files; source_bytes; target_bytes; source_dirs; target_dirs; missing; extra; size_mismatch; hash_mismatch; metadata_mismatch; scan_errors; retried; exceptions_opened }`
  - `htmlChecks` (HtmlChecks): `@{ parity; run_id; source_findings; target_findings; parity_differences; by_rule = @{ rule = count } }`
- Per-batch result files (via `Add-MigStoreRecords -BatchId <id> -Name <file>`):
  - `reconcile.results.jsonl`: one record per issue `@{ run_id; rel_path; kind; category; field; source_value; target_value; detail; ts_utc }`
    categories: `missing | extra | size_mismatch | hash_mismatch | metadata_mismatch | scan_error`
  - `htmlchecks.source.jsonl`, `htmlchecks.target.jsonl`: findings `@{ run_id; rule; rel_path; severity; detail }`
  - `htmlchecks.parity.jsonl`: `@{ run_id; rule; rel_path; detail; only_on ('source'|'target') }`
  Readers use only the records whose `run_id` equals the latest run recorded in batch info.
- Exception register: `Add-MigException -BatchId -RelPath -Category -Detail [-Owner] -RunId`, `Get-MigExceptions`, `Update-MigException`.

## Providers (Core/Registry.ps1 has the exact scriptblock signatures)
Selected by config: `batching.strategy`, `copy.engine`, `compare.fileFields/dirFields`, `htmlChecks.rules.<name>.enabled`, `report.formats`.

## Scanner (Core/Scanner.ps1)
- `Get-MigTreeEntries -Root [-RelDir] [-ExcludePatterns] [-IncludeDirectories] [-UseLongPath]` streams `@{rel_path; kind; full}`.
- `Get-MigScanRecords -Ctx -Side source|target -Entries <array>` → manifest records (hash, metadata, acl_hash) computed in parallel. `batch_id` is left `$null`; the caller sets it.
- `Get-MigEffectiveThreads -Ctx -Default n` applies `throttle` windows; `Get-MigActiveThrottleWindow` gives `ipgMs`.

## Testing locally (non-Windows workstation)
- PowerShell 7 (`pwsh`) or Windows PowerShell 5.1 (`powershell.exe`)
- Pester 5+ syntax (Pester 6.2 installed). Run: `pwsh -NoProfile -c "Invoke-Pester ./tests/Unit/X.Tests.ps1 -Output Detailed"`
- Tests import the module with `Import-Module $PSScriptRoot/../../NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking` and reach private functions with `InModuleScope NotificationMigration { ... }`.
- Use `inventory.aclReader = 'none'` and `compare.fileFields` without `acl` on non-Windows. Use `copy.engine = 'dotnet'` on non-Windows (Robocopy is Windows-only).
- Use `$TestDrive` for data; never touch real paths.

## Stage state notes
- Copy leaves batch `state = 'copying'` when any file failed, `copied` otherwise. Verify sets `state = 'verified'`.
- Reconcile retries (when `reconcile.autoRetry`) force a re-copy (`Plan.Force`) because Robocopy would skip a corrupted file with the same size and timestamp. With `autoRetry = false`, unresolved files get status `mismatch` and no exception; the next Copy run force-re-copies them.
- `attempts` (Get-MigFileStatus) counts `copied` events and failed attempts (`copy_failed = $true`).
- Directories get status events too; adding/removing a file on target changes its parent directory's mtime, which Reconcile reports as `metadata_mismatch` and auto-retry repairs by restoring source timestamps.
- Dry run for Copy/Verify/Reconcile/Delta writes nothing to the store; Inventory and Batching do (they only read the source).

## Store files for governance and resilience
- `batches/<id>/exceptions.jsonl`: per-batch exception register (was global), with a `fingerprint` per item.
- `batches/<id>/archive/*.jsonl` + `.sha256`: pre-compaction copies kept as evidence (`Compress-MigStoreFile`).
- `batches/<id>/reconcile.results.<runId>.jsonl`, `htmlchecks.<side>.<runId>.jsonl`: per-run result files, pointed to by batch info.
- `locks/<scope>.lock`: per-scope exclusive lock held while a stage runs.
- `freeze.jsonl`, `signoff.jsonl`, `retention.jsonl`: governance records (C-02, C-09, C-10), each with an `audit_ref`.
- `auditcheck.jsonl`: cache of successful audit-log verifications (file + sidecar hash + length + mtime), written by the final report.
- Every `stages.jsonl` / `gates.jsonl` record carries `audit_ref` = `@{log; seq; hash}` of its audit line; gates only accept approvals provable in the audit log.
- Batch states: `inventoried` (new batch from Inventory) → `planned` (Batching) → `copying`/`copied` → `verified` → `reconciled` | `mismatch`; `delta_pending` when Inventory/Delta changed files in an existing batch (also sets `reconcile.stale`).
- `manifest.checksums.jsonl` records: `{batch_id; file; algorithm; hash; run_id; ts_utc}` (algorithm = `inventory.hash.algorithm`).
- `Export-MigManifestCsv` / public `Export-MigrationManifest`: C-01 manifest CSV + checksum sidecar under `<reportDir>/manifests/`.
- Case-only duplicate names (case-sensitive sources) are emitted by the scanner as `error` entries `case_duplicate_of:<name>` and become `scan_error` exceptions; they are never written to the (case-insensitive) manifest.
- Inventory/Delta summaries carry `affected_batches`; gates and the final report only invalidate those batches. Delta also carries `source_files`/`source_bytes` for the final cross-check.
- HtmlChecks: parity includes longPath (`side_specific` is display-only); rules share one read per file via `$Options._htmlCache` (contract in `Providers/HtmlRule/HtmlRuleCommon.ps1`).
- A Delta that completed after the Inventory is the input Batching depends on; `Delta` is gated by default.
