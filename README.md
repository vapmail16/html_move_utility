# NotificationMigration

A governed, auditable **copy-and-verify** migration of the HTML notification archive (about 7 years, terabytes) from Windows Server A to Windows Server B. Every file is proven byte-identical by SHA-256, and every stage leaves evidence for audit.

- Spec: [`Notification_Migration_Requirements.md`](Notification_Migration_Requirements.md)
- Contracts and internals: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

---

## 1. Guarantees

| Guarantee | How it is enforced |
|---|---|
| **Copy only.** The source is never created, modified, moved or deleted. | Every write path goes through `Assert-MigPathNotUnderSource`. Config validation rejects a `targetRoot`, `workDir`, `storeDir`, `reportDir` or `logDir` that is inside `sourceRoot` (and a `sourceRoot` inside `targetRoot`). Robocopy flags are checked against `copy.forbiddenFlags`, and a built-in floor (`/MOV /MOVE /MIR /PURGE`) cannot be removed by config. `/MT` and `/LOG` are managed by the tool and rejected in `copy.robocopy.flags`. |
| **No third-party dependencies.** | Only built-in Windows PowerShell 5.1 / PowerShell 7, .NET and `robocopy.exe`. The manifest store is append-only JSON Lines, not SQLite, so no PSSQLite is needed. Pester is needed **only** to run the tests. |
| **Verified per file** | Content (SHA-256 by default, SHA-384/512 configurable), size, created and modified time, attributes, NTFS ACL hash (owner + DACL) and existence. Folders are checked for existence and modified time. The fields compared come from `compare.fileFields` and `compare.dirFields`. |
| **Verified per batch** | File count, folder count and total bytes, source against target. Also missing, extra, size, hash and metadata mismatches, and scan errors. |
| **Verified for HTML** | Long paths, file names (non-ASCII, trailing dot or space, invalid characters, case-only duplicates), relative `src`/`href` assets that exist, absolute links to the old server, zero-byte and malformed files, and a render sample. Findings must be the same on source and target (`htmlChecks.requireSourceTargetParity`). |
| **Maker-checker** | A gated stage cannot start until a **different** user approves the exact completed run of the previous stage (`pipeline.makerCheckerDistinctUsers`). |
| **Tamper-evident logs** | One JSON Lines audit log per run, with UTC timestamps. Each line is hash-chained to the previous line, and a `.sha256` checksum sidecar is written when the run closes. |
| **Resumable** | Stage events, file status and manifests are append-only. The latest record wins, so an interrupted run can be run again, and files that are already verified are not copied again. |

Encoding (UTF-8/UTF-16, BOM) and line endings are covered by the content hash, so they need no separate check.

---

## 2. Assumptions (confirm before production)

> These are decisions the operator and the control owner must confirm. Each one maps to a configuration key.

**(a) Both servers are in the same Active Directory domain.** The default is therefore `compare.acl.mode = "sid"`: ACLs are compared as SDDL, with raw SIDs for owner and DACL.
If the servers are in **different domains**, choose one of these:
- `"account"`: compare ACLs by resolved account names (`DOMAIN\name`) instead of SIDs. Use this when the same account names exist on both sides.
- `"mapped"`: rewrite target SIDs to source SIDs before hashing, using `compare.acl.sidMapFile`. This is a JSON object `{ "<targetSID>": "<sourceSID>" }`, for example:
  ```json
  { "S-1-5-21-2222222222-3333333333-4444444444-1105": "S-1-5-21-1111111111-2222222222-3333333333-1105" }
  ```

**(b) Where the tool runs.** It can run centrally on one admin host and reach both servers over UNC. It can also run locally on each server, for example source inventory on Server A and verify on Server B, for faster hashing: point `paths.sourceRoot`/`targetRoot` at local paths in each server's copy of the config. Stages take a per-batch lock in the store, so two hosts can never run the same batch at the same time. In both cases `paths.workDir` (the store, reports and logs) must be one shared location that every host running a stage can reach. The store is the single record of the migration.

**(c) The source is frozen (read-only) for the final delta.** Until the freeze, new or changed source files are picked up by the `Delta` stage. The final Delta and its reconciliation are valid only after the source ACL has been set to read-only (C-02 evidence).

**(d) Runtime.** Windows PowerShell 5.1 is built into Windows Server and is enough to run the tool. PowerShell 7 is optional and supported. **Pester 5+** is needed only to run the test suite. Windows ships Pester 3.4, which cannot run these tests.

**(e) Robocopy preserving creation time must be confirmed in the pilot.** `/COPY:DATS` + `/DCOPY:T` are expected to preserve created and modified times. If the pilot shows `created` mismatches, either fix the copy flags or remove `created` from `compare.fileFields` with a documented, approved exception. **Do not** raise the tolerance silently. In the same pilot, confirm the ACL comparison. The default flags are `/COPY:DATSO` so the owner is copied too, because `compare.acl.includeOwner` defaults to `true` (compare everything). Copying the owner requires the service account to hold the **Restore files and directories** privilege on Server B. If that privilege is not granted, use `/COPY:DATS` and set `compare.acl.includeOwner` to `false`, recorded as an approved deviation.

Other operating assumptions:
- Long-path support is enabled on both servers. `paths.useLongPathPrefix = true` makes the tool use `\\?\` / `\\?\UNC\` paths.
- The tool runs under a dedicated least-privilege service account. It needs read access on the source (including ACL read), write access on the target and `workDir`, and no delete rights on the source. Credentials are never stored in config or logs.
- Operator identity is taken from the Windows session (`DOMAIN\user`). The reviewer runs the approval commands under **their own** account.

---

## 3. Installation

1. Copy the `NotificationMigration` folder to the migration host, for example `D:\Migration\tool\NotificationMigration`. You can also place it under `C:\Program Files\WindowsPowerShell\Modules\`.
2. If the files were downloaded, unblock them: `Get-ChildItem D:\Migration\tool -Recurse | Unblock-File`.
3. Import the module:
   ```powershell
   Import-Module D:\Migration\tool\NotificationMigration\NotificationMigration.psd1 -DisableNameChecking
   ```
   `-DisableNameChecking` hides the warning about the unapproved verb in `Migrate-Notifications`.
4. Copy `migration.config.sample.json` to `migration.config.json` and edit it (see §4). Keep the config next to the work directory under change control. Its SHA-256 is written to every audit log (`run.started.config_hash`).

Exported commands: `Migrate-Notifications`, `Approve-MigrationGate`, `Get-MigrationStatus`, `Get-MigrationException`, `Set-MigrationException` and `Test-MigrationAuditLog`. Each one takes `-Config` (default `.\migration.config.json`), except `Test-MigrationAuditLog`, which takes `-Path`.

---

## 4. Configuration reference

Configuration is layered as `NotificationMigration/config/defaults.json` ← `migration.config.json` ← `-Override @{...}`. Dictionaries merge. Arrays and scalars **replace** the default, so if you override an array such as `compare.fileFields`, list every value you want. The loader validates everything at once and reports every problem in one error.

- `migration.config.sample.json` is a production-style example with UNC paths, throttling and old-host names.
- `config/migration.config.dev.json` is for local testing on a non-Windows workstation (see §11).

### paths
| Key | Default | Meaning / validation |
|---|---|---|
| `paths.sourceRoot` | `null` | **Required.** Root of the archive to copy, e.g. `\\\\SRV-NOTIF-01\\Notifications$` in JSON. Never written to. |
| `paths.targetRoot` | `null` | **Required.** Destination root. Must not be inside `sourceRoot`, and `sourceRoot` must not be inside it. |
| `paths.workDir` | `null` | **Required.** Shared working folder for the store, reports and logs. Must not be inside `sourceRoot`. |
| `paths.storeDir` | `"store"` | Manifest/state store. A relative value is resolved under `workDir`. |
| `paths.reportDir` | `"reports"` | CSV/HTML/JSON reports. A relative value is resolved under `workDir`. |
| `paths.logDir` | `"logs"` | Audit logs (`run-<utc>-<runId>.jsonl` + `.sha256`). A relative value is resolved under `workDir`. |
| `paths.useLongPathPrefix` | `true` | Use `\\?\` paths on Windows so that paths over 260 characters work. |

### pipeline
| Key | Default | Meaning / validation |
|---|---|---|
| `pipeline.stages` | `Inventory Batching Copy Verify Reconcile HtmlChecks Report` | Order used by `-Stage All` and for readiness chaining (each stage needs the previous one completed and, if gated, approved). Only known stage names are allowed. `Delta` and the final `Report` are not chained: they need an approved Inventory. |
| `pipeline.gates` | `Inventory Delta Batching Copy Verify Reconcile HtmlChecks` | Stages whose latest real run must be approved (`Approve-MigrationGate`) before the next stage can start. Approvals are only accepted if provable in the hash-chained audit log. Re-running an upstream stage that changes a batch invalidates later approvals for that batch. |
| `pipeline.makerCheckerDistinctUsers` | `true` | The approver must differ from the operator who ran the stage (C-08). Keep this `true` in production. |
| `pipeline.requireSuccessToApprove` | `true` | Refuse to approve a run whose summary did not pass (`passed=false`, `parity=false` or `files_failed>0`) unless `-Override` is given with a justification of 20+ characters. Overrides are listed in the final report. |
| `pipeline.dryRunStages` | `Inventory Batching Report` | Stages run by `-Stage All -DryRun`. Only read-only stages are allowed (Inventory, Batching, Report, Delta). |

### freeze
| Key | Default | Meaning / validation |
|---|---|---|
| `freeze.allowedWriters` | `NT AUTHORITY\SYSTEM BUILTIN\Administrators CREATOR OWNER` | Principals (wildcards allowed) that may keep write/delete rights on `sourceRoot` when `Register-MigrationFreeze` checks that the source is frozen (C-02). Anyone else with write rights fails the freeze check. |

### inventory
| Key | Default | Meaning / validation |
|---|---|---|
| `inventory.threads` | `8` | Parallel hashing runspaces (≥ 1). Reduced by active throttle windows. |
| `inventory.chunkSize` | `500` | Files per parallel work item (≥ 1). |
| `inventory.manifestCacheRecords` | `2000000` | Maximum manifest records held in the Inventory/Delta index cache across batches (LRU; the batch in use is never evicted). `<= 0` = unlimited. |
| `inventory.detectBy` | `size modified` | Fields that decide whether a file changed since the last inventory (`size`, `modified`, `created`, `attributes`, `hash`). Changed files are always re-hashed. With `hash`, every file is re-hashed. |
| `inventory.hash.algorithm` | `"SHA256"` | `SHA256`, `SHA384` or `SHA512`. |
| `inventory.hash.bufferSizeKB` | `64` | Maximum read buffer per file while hashing; the buffer is `min(file size, this)` with a 4 KB floor. 64 KB measured fastest for small HTML files. |
| `inventory.aclReader` | `"windows"` | `windows` (read NTFS ACLs) or `none` (no ACL hash. Use `none` only for non-Windows testing, and remove `acl` from `compare.fileFields`). |
| `inventory.includeDirectories` | `true` | Record folders in the manifest, for folder counts and folder metadata. |
| `inventory.excludePatterns` | `[]` | Case-insensitive regexes matched against the canonical `\`-separated relative path. Matches are not inventoried, so every exclusion must be approved. |
| `inventory.skipUnchanged` | `true` | On a re-run, reuse the previous manifest record when the file looks unchanged instead of hashing it again (resume). |

### batching
| Key | Default | Meaning / validation |
|---|---|---|
| `batching.strategy` | `"regex"` | Name of a registered Batch provider. Required. |
| `batching.options` | see `defaults.json` | Strategy-specific options. `regex`: `pattern` (named groups), `template` (e.g. `{y}-{m}`), `unmatchedBatchId`, optional `parentDirBatchId` (batch for folders above the batch level). `yearMonth`/`year`: `dateField` (`modified_utc` or `created_utc`). `folderDepth`: `depth` (≥ 1). Batch ids may only contain `A-Z a-z 0-9 . _ -`. |

### copy
| Key | Default | Meaning / validation |
|---|---|---|
| `copy.engine` | `"robocopy"` | Copy provider: `robocopy` (production), or `dotnet` (only for non-Windows testing). |
| `copy.maxRetries` | `3` | Automatic re-copy attempts per failed or mismatched file before it goes to the exception register (≥ 0). |
| `copy.chunkSize` | `5000` | Maximum files per copy work unit. The plan is chunked by folder so Robocopy runs once per folder in whole-folder mode where possible. |
| `copy.splitFolderFactor` | `10` | A folder is only split across work units when it holds more than `chunkSize × splitFolderFactor` planned files. |
| `copy.robocopy.executable` | `"robocopy.exe"` | Path to Robocopy. |
| `copy.robocopy.flags` | `/COPY:DATSO /DCOPY:T /R:3 /W:5 /NP /FP /BYTES /TS /UNICODE` | Extra Robocopy flags. Forbidden flags are rejected. `/MT` and `/LOG*` are rejected because the tool sets them. |
| `copy.robocopy.threads` | `16` | Value for `/MT:n`. |
| `copy.robocopy.successExitCodeMax` | `7` | Robocopy exit codes up to this value count as success. 8 and above is failure. |
| `copy.robocopy.maxCommandLineChars` | `8000` | Upper bound for one Robocopy command line when file names must be listed (512–30000). |
| `copy.robocopy.allowedFlags` | `/COPY /COPYALL /DCOPY /R /W /NP /FP /BYTES /TS /UNICODE /NFL /NDL /NJH /NJS /V /X /XJ /XJD /XJF /SL /SJ /B /ZB /Z /J /EFSRAW /NOOFFLOAD /COMPRESS /TEE /ETA` | Allow-list of flag names an operator may put in `copy.robocopy.flags`. Tool-managed flags (`/MT`, `/IPG`, `/L`, `/IS`, `/IT`, `/XF`, `/UNILOG+`) are added by the tool. A built-in floor always forbids `/MOV /MOVE /MIR /PURGE /JOB /SAVE /S /E /LEV /XX /SECFIX /CREATE /A+ /A- /IA /FFT` and any flag entry containing whitespace. |
| `copy.forbiddenFlags` | `/MOV /MOVE /MIR /PURGE /CREATE` | Extra flags to reject, on top of the built-in floor (which config cannot remove). |

### reconcile
| Key | Default | Meaning / validation |
|---|---|---|
| `reconcile.autoRetry` | `true` | Re-copy (forced) and re-verify mismatched/missing files inside Reconcile, up to `copy.maxRetries`, before opening exceptions. |
| `reconcile.compactStore` | `true` | After a real Reconcile, compact the batch's target manifest (and status events) to the latest record per file. The previous file is archived with a checksum, so no evidence is lost. |

### throttle
| Key | Default | Meaning / validation |
|---|---|---|
| `throttle.enabled` | `false` | Apply business-hours windows. |
| `throttle.timeZone` | `"Local"` | `Local` or `UTC`. The clock used to evaluate windows. |
| `throttle.windows` | see `defaults.json` | List of `{ days, from, to, threads, ipgMs }`. While a window is active, hashing/copy threads are capped at `threads` and Robocopy gets `/IPG:ipgMs`. Times `HH:mm`; a window may cross midnight. |

### compare
| Key | Default | Meaning / validation |
|---|---|---|
| `compare.fileFields` | `exists size hash created modified attributes acl` | Fields compared for files: `exists size hash created modified attributes acl`. `exists`, `size` and `hash` are mandatory. `acl` requires `inventory.aclReader = windows`. |
| `compare.dirFields` | `exists modified` | Folder fields compared. Same allowed set. |
| `compare.timestampToleranceSec` | `0` | Allowed timestamp difference in seconds (≥ 0). Any non-zero value needs control-owner approval. |
| `compare.ignoreAttributes` | `[]` | `FileAttributes` names removed before comparing, for example `Archive`. Each entry narrows C-05 and must be approved. |
| `compare.acl.mode` | `"sid"` | `sid`, `account` or `mapped`. See assumption (a). |
| `compare.acl.sidMapFile` | `null` | Required when mode is `mapped`. JSON `{ "<targetSID>": "<sourceSID>" }`. |
| `compare.acl.includeOwner` | `true` | Include the owner in the ACL comparison. Requires an owner-copying Robocopy flag (`/COPY:...O` or `/COPYALL`), which needs the Restore privilege on the target. |

### delta
| Key | Default | Meaning / validation |
|---|---|---|
| `delta.detectBy` | `size modified` | Fields that mark a source file as changed since its manifest record. Allowed: `size`, `modified`, `created`, `attributes`, `hash`. |

### htmlChecks
| Key | Default | Meaning / validation |
|---|---|---|
| `htmlChecks.fileExtensions` | `.htm .html` | Files parsed by the HTML rules. |
| `htmlChecks.requireSourceTargetParity` | `true` | Every finding difference between source and target (per rule, per file, including longPath) opens an `html_parity` exception, and the stage reports `parity = false`. |
| `htmlChecks.chunkSize` | `5000` | Files per HTML-check work unit; each file is read once per side and shared by all content rules. |
| `htmlChecks.rules.longPath.enabled` | `true` | Flag files whose full path on either side exceeds `maxLength`. A file long on one side only is a parity difference. |
| `htmlChecks.rules.longPath.maxLength` | `260` | Path length limit (characters). |
| `htmlChecks.rules.fileName.enabled` | `true` | Check file names. |
| `htmlChecks.rules.fileName.flagNonAscii` | `true` | Flag names with non-ASCII characters. |
| `htmlChecks.rules.fileName.flagTrailingDotSpace` | `true` | Flag names ending in a dot or space. |
| `htmlChecks.rules.fileName.flagLeadingSpace` | `true` | Flag names starting with a space. |
| `htmlChecks.rules.fileName.flagControlChars` | `true` | Flag names containing control characters (error). |
| `htmlChecks.rules.fileName.flagCaseDuplicates` | `true` | Flag names that differ only by case within one folder. |
| `htmlChecks.rules.fileName.invalidChars` | `"<>:"\|?*"` | Characters invalid on Windows (only reachable on non-Windows sources). |
| `htmlChecks.rules.fileName.specialChars` | `"&#%;{}~$!'@+=,[]^`"` | Legal but risky characters to flag (warning). |
| `htmlChecks.rules.fileName.reservedNames` | `CON PRN AUX NUL COM1 COM2 COM3 COM4 COM5 COM6 COM7 COM8 COM9 LPT1 LPT2 LPT3 LPT4 LPT5 LPT6 LPT7 LPT8 LPT9` | Reserved device names (with or without extension), flagged as errors. |
| `htmlChecks.rules.linkedAssets.enabled` | `true` | Check that relative `src`/`href`/CSS/srcset references resolve to files that exist on the same side. |
| `htmlChecks.rules.linkedAssets.attributes` | `src href background poster` | HTML attributes whose values are treated as asset references. |
| `htmlChecks.rules.linkedAssets.parseCssUrls` | `true` | Also check `url(...)` in style attributes and `<style>` blocks. |
| `htmlChecks.rules.linkedAssets.parseSrcset` | `true` | Also check `srcset` candidates. |
| `htmlChecks.rules.linkedAssets.maxBytesToParse` | `null` | Skip (and report `skipped_large`) files above this size; `null` = use `malformed.maxBytesToParse`. |
| `htmlChecks.rules.linkedAssets.ignoreSchemes` | `http https mailto javascript data tel #` | References with these schemes (and anchors) are ignored. |
| `htmlChecks.rules.absoluteLinks.enabled` | `true` | Report (never rewrite) links hard-coded to the old server. A warning is shown if enabled with all three lists empty. |
| `htmlChecks.rules.absoluteLinks.oldHosts` | `[]` | Old server host names (case-insensitive). |
| `htmlChecks.rules.absoluteLinks.oldUncPrefixes` | `[]` | Old UNC prefixes, e.g. `\\\\OLDSRV\\share`. |
| `htmlChecks.rules.absoluteLinks.oldIpAddresses` | `[]` | Old server IP addresses. |
| `htmlChecks.rules.absoluteLinks.maxBytesToParse` | `null` | Skip (and report `skipped_large`) files above this size; `null` = use `malformed.maxBytesToParse`. |
| `htmlChecks.rules.zeroByte.enabled` | `true` | Report zero-byte files; counts must match on both sides. |
| `htmlChecks.rules.malformed.enabled` | `true` | Report unreadable, binary-looking or structurally incomplete HTML. |
| `htmlChecks.rules.malformed.requireTags` | `html` | Tags an HTML file must contain. |
| `htmlChecks.rules.malformed.maxBytesToParse` | `10485760` | Files above this size are reported as `skipped_large` instead of parsed. |
| `htmlChecks.rules.renderSample.enabled` | `true` | Render-check a deterministic sample per batch. The same sample (from files present on both sides) is used for source and target. |
| `htmlChecks.rules.renderSample.rate` | `0.001` | Sample fraction (0–1). |
| `htmlChecks.rules.renderSample.minPerBatch` | `1` | Minimum sample size per batch. |
| `htmlChecks.rules.renderSample.seed` | `42` | Seed for the deterministic sample. |
| `htmlChecks.rules.renderSample.renderer` | `"parse"` | `parse` (structural check, no browser) or `edgeHeadless` (Edge `--headless --dump-dom`). |
| `htmlChecks.rules.renderSample.strictRenderer` | `false` | Fail the stage if `edgeHeadless` is configured but Edge is not found (instead of falling back to `parse`). |
| `htmlChecks.rules.renderSample.edgePath` | `null` | Path to msedge.exe; `null` = search PATH. |
| `htmlChecks.rules.renderSample.timeoutSec` | `30` | Per-file render timeout. |

### report
| Key | Default | Meaning / validation |
|---|---|---|
| `report.formats` | `csv html` | Allowed: `csv`, `html`, `json`. |
| `report.htmlMaxRows` | `2000` | Maximum rows per HTML table (a note points to the full CSV). `<= 0` = no cap. CSVs are never capped. |
| `report.finalIncludeDetails` | `false` | Include per-file issues/findings in the final report (they are always in the batch reports). |
| `report.finalTargetSweep` | `true` | During a real `-Final`, walk the whole target for files outside every batch (`Find-MigTargetOrphans`) and count them in AC-3. |

### audit
| Key | Default | Meaning / validation |
|---|---|---|
| `audit.hashChain` | `true` | Hash-chain each audit line. Keep this `true`: `Test-MigrationAuditLog` expects chained logs. |
| `audit.hashAlgorithm` | `"SHA256"` | Chain and sidecar algorithm. `Test-MigrationAuditLog` verifies with SHA256. |

## 5. Work directory layout (the migration record)

```
<workDir>\
  store\
    batches.jsonl          batch plan + state (latest per batch wins)
    stages.jsonl           started / completed / failed per stage and scope (run_id, operator, summary)
    gates.jsonl            maker-checker decisions
    exceptions.jsonl       exception register (latest per id wins)
    batches\<batchId>\
      source.manifest.jsonl  target.manifest.jsonl  status.events.jsonl
      reconcile.results.jsonl  htmlchecks.source.jsonl  htmlchecks.target.jsonl  htmlchecks.parity.jsonl
  reports\                 per-batch and final CSV / HTML (/ JSON)
  logs\                    run-<utc>-<runId>.jsonl  +  .sha256 sidecar
```

Archive the whole `workDir` together with the migration record at sign-off.

---

## 6. Runbook

The steps follow the spec: run the oldest year first as the pilot, then the batches in order. Every gate needs reviewer approval. Below, **operator** = maker and **reviewer** = checker (a different account).

```powershell
Import-Module D:\Migration\tool\NotificationMigration\NotificationMigration.psd1 -DisableNameChecking
$cfg = 'D:\Migration\migration.config.json'
```

### Step 1: Dry run (FR-10)
Inventories the source and plans batches. Nothing is copied, and nothing is written to the target.
```powershell
Migrate-Notifications -Stage All -DryRun -Config $cfg     # Inventory + Batching + Report only
Get-MigrationStatus -Config $cfg
```
Review the batch plan (file, folder and byte counts per batch, zero-byte and scan-error counts) and the size estimate in `reports\`. A dry run **cannot be approved**, and later stages refuse to run on a dry-run-only Inventory. Resolve any scan errors (permissions, paths) before continuing.

### Step 2: Inventory and batching for real (C-01)
```powershell
# operator
Migrate-Notifications -Stage Inventory -Config $cfg
# reviewer
Approve-MigrationGate -Stage Inventory -Config $cfg -Comment 'Source manifest reviewed: counts match estimate, 0 scan errors'
# operator
Migrate-Notifications -Stage Batching -Config $cfg
# reviewer
Approve-MigrationGate -Stage Batching -Config $cfg -Comment 'Batch plan approved'
```

### Step 3: Pilot, oldest year end to end
Run each batch of the pilot year, for example `2019-01` … `2019-12`. After each stage, the reviewer approves that batch's gate.
```powershell
$b = '2019-01'
Migrate-Notifications -Stage Copy       -Batch $b -Config $cfg ; Approve-MigrationGate -Stage Copy       -Batch $b -Config $cfg -Comment 'Robocopy exit codes OK'
Migrate-Notifications -Stage Verify     -Batch $b -Config $cfg ; Approve-MigrationGate -Stage Verify     -Batch $b -Config $cfg -Comment 'Target scanned'
Migrate-Notifications -Stage Reconcile  -Batch $b -Config $cfg ; Approve-MigrationGate -Stage Reconcile  -Batch $b -Config $cfg -Comment '0 missing/extra/hash; metadata OK'
Migrate-Notifications -Stage HtmlChecks -Batch $b -Config $cfg ; Approve-MigrationGate -Stage HtmlChecks -Batch $b -Config $cfg -Comment 'Findings reviewed, parity OK'
Migrate-Notifications -Stage Report     -Batch $b -Config $cfg
```
(The `Approve-MigrationGate` calls are run by the reviewer under their own account.) `-Batch` accepts several ids, e.g. `-Batch 2019-01,2019-02`. If you leave `-Batch` out, a batch stage runs for every batch.

Pilot exit criteria:
- Measured throughput and a full-run estimate.
- Confirmation of assumption (e): creation time and ACL owner.
- Every `absoluteLinks` host listed.
- Zero open exceptions.

Record the pilot decision as the Reconcile/HtmlChecks gate comments.

### Step 4: Bulk
Run the remaining batches in order, with the same five commands per batch. Alternatively, let the pipeline advance every batch whose gate is already approved:
```powershell
Migrate-Notifications -Stage All -Config $cfg     # stops at any gate that is not approved yet; re-run after approvals
Get-MigrationStatus -Config $cfg | Format-Table
```
A mismatch loops back automatically. Reconcile re-copies and re-verifies up to `copy.maxRetries` times (`reconcile.autoRetry`), and puts the remaining items in the exception register. After an interruption, run the same command again. Verified files are skipped (FR-07).

### Step 5: Freeze and Delta (FR-08, C-02)
1. The source owner sets the source share/NTFS ACL to **read-only**, then records it. The tool reads the ACL and fails if anyone outside `freeze.allowedWriters` can still write or delete:
```powershell
Register-MigrationFreeze -Config $cfg -Comment 'Source read-only under CHG-1234'
```
2. Detect files added or changed since the manifest. The reviewer approves the Delta, then Batching is re-run so the plan includes the new files:
```powershell
$d = Migrate-Notifications -Stage Delta -Config $cfg
$d.ran[0].summary.affected_batches          # only these batches must run again
Approve-MigrationGate -Stage Delta -Config $cfg -Comment 'Delta reviewed'          # reviewer
Migrate-Notifications -Stage Batching -Config $cfg
Approve-MigrationGate -Stage Batching -Config $cfg -Comment 'Re-plan after delta'  # reviewer
```
3. Re-run Step 3's commands, with approvals, for each **affected** batch. Unaffected batches keep their approvals and results; the gates and the final report only invalidate batches listed in `affected_batches`.

### Step 6: Final report
```powershell
Migrate-Notifications -Stage Report -Final -Config $cfg   # summary.passed = every acceptance criterion met
Export-MigrationManifest -Config $cfg                     # C-01: manifest CSV + checksum per batch
Get-MigrationException -Config $cfg -Status open    # must return nothing
Test-MigrationAuditLog -Path 'D:\Migration\work\logs'   # every row Valid = True
```
Acceptance, from the spec:
- Source and target file counts and total bytes are equal, per batch and overall.
- 100% SHA-256 match, with zero missing and zero extra.
- Metadata matches, or the differences are approved exceptions.
- HTML findings are reviewed.
- The exception register is closed.
- Reports and logs are archived with checksums.

### Step 7: Sign-off, cutover, retention
- **Sign-off (C-09):** three different people sign the latest final report, each under their own account. Anyone who operated a stage cannot sign as control owner. The final report shows the sign-off table (pending roles included).
```powershell
Approve-MigrationSignOff -Role SourceOwner  -Config $cfg -Comment 'Source complete'
Approve-MigrationSignOff -Role TargetOwner  -Config $cfg -Comment 'Target accepted'
Approve-MigrationSignOff -Role ControlOwner -Config $cfg -Comment 'Controls evidenced'
```
- **Cutover:** point the notification application at Server B. This is outside the tool.
- **Retention (C-10):** record the retention ticket, keep the source read-only for the agreed period, then decommission.
```powershell
Register-MigrationRetention -Config $cfg -Ticket 'CHG-5678' -RetainUntil '2027-03-31'
```

---

## 7. Maker-checker (C-08)

- `Migrate-Notifications` records the operator (`DOMAIN\user`) and the `run_id` of each completed stage.
- `Approve-MigrationGate` approves the **latest real (non-dry-run) completed run** of that stage for that scope. A global scope applies to `Inventory`, `Batching` and `Delta`. Other stages take `-Batch <id>`. `-Comment` is mandatory.
- If the approver is the same user who ran the stage, the approval fails with `MAKER-CHECKER: ... cannot also approve it` (while `pipeline.makerCheckerDistinctUsers` is `true`).
- Re-running a stage creates a new run, and **that new run needs a new approval**. A newer failed or interrupted run blocks the next stage until it is re-run.
- **Chain freshness:** if an upstream stage re-runs and changes a batch (e.g. Inventory or Delta lists it in `affected_batches`, or Copy re-runs for it), every later stage of that batch must run and be approved again.
- **Only passing runs can be approved** (`pipeline.requireSuccessToApprove`): a Reconcile with `passed = false`, HtmlChecks with `parity = false` or a Copy with failed files is refused unless the reviewer adds `-Override` and a justification of at least 20 characters. Overrides are listed in the final report.
- **Tamper evidence:** an approval only counts if the same decision is present in the hash-chained audit log (`audit_ref`). A line added to `gates.jsonl` by hand is rejected as possible tampering.
- A rejection blocks the next stage until the stage is re-run and approved:
  ```powershell
  Approve-MigrationGate -Stage Reconcile -Batch 2019-03 -Reject -Comment 'Hash mismatch on 2 files; re-copy' -Config $cfg
  ```
- Every decision is stored in `store\gates.jsonl` (stage, scope, run_id, maker, checker, decision, comment, stage summary, UTC time). It is also written to the audit log as `gate.decision`.

---

## 8. Exceptions (C-06)

```powershell
Get-MigrationException -Config $cfg -Status open                   # everything outstanding
Get-MigrationException -Config $cfg -Batch 2019-03                 # one batch, any status
Set-MigrationException -Config $cfg -Id <id> -Owner 'CORP\jdoe'    # assign an owner
Set-MigrationException -Config $cfg -Id <id> -Status resolved -Resolution 'Re-copied manually; hash verified in run 3fa2...'
Set-MigrationException -Config $cfg -Id <id> -Status accepted -Resolution 'Owner SID differs by design; approved by control owner (CHG-1234)'
```
- Statuses are `open`, `resolved` and `accepted`. A `-Resolution` is mandatory to close an exception.
  - `accepted`: the difference stays and is approved. It is never re-opened, and the final report treats the covered item (e.g. an accepted extra file) as approved.
  - `resolved`: someone fixed it. The next Reconcile re-checks the file; if it still differs, a new exception is opened.
- The register is kept per batch (`store\batches\<id>\exceptions.jsonl`). Each item has a fingerprint (batch, path, category), so re-runs never create duplicates.
- Every update is written to the register (latest record wins, and the history is kept) and to the audit log as `exception.updated`.
- `Get-MigrationStatus` shows the open-exception count per batch.

---

## 9. Status and audit-log verification

```powershell
Get-MigrationStatus -Config $cfg | Format-Table
# Scope     Inventory           Batching            Copy                Verify ... OpenExceptions
# global    completed/approved  completed/approved
# 2019-01                                          completed/approved  completed ...         0

Test-MigrationAuditLog -Path 'D:\Migration\work\logs'                       # every run-*.jsonl in the folder
Test-MigrationAuditLog -Path 'D:\Migration\work\logs\run-20260923T101500Z-3fa2c1d0e9ab.jsonl'
# Path  Valid  Lines  Error
```
`Valid = False` means one of the following, and the `Error` column says which line:
- a line was edited, removed or reordered (the hash chain is broken), or
- the file no longer matches its `.sha256` sidecar.

---

## 10. Controls → evidence

| Control | Evidence produced | Where |
|---|---|---|
| **C-01** Source manifest with SHA-256 before any copy | Source manifest per batch with its checksum recorded at Inventory/Delta; CSV export with checksum sidecar. The audit trail shows Inventory `completed` + gate `approved` before any Copy `stage.started`. | `store\batches\<id>\source.manifest.jsonl`, `store\manifest.checksums.jsonl`, `reports\manifests\*.csv` + sidecar, `store\stages.jsonl`, `store\gates.jsonl` |
| **C-02** Copy only, source never modified | Config validation, Robocopy flag allow-list + forbidden floor, source write guard. The config hash is in every `run.started` event. Freeze record with the source ACL and its hash. | `migration.config.json`, `logs\run-*.jsonl` (`config_hash`), `store\freeze.jsonl`, final report |
| **C-03** 100% SHA-256 match | Reconcile totals with `hash_mismatch = 0`, `missing = 0`, `extra = 0`, and the per-issue rows. | `store\batches.jsonl` (`reconcile`), `store\batches\<id>\reconcile.results.jsonl`, batch + final reports |
| **C-04** File count, bytes and folder count per batch | `source_files/target_files`, `source_bytes/target_bytes`, `source_dirs/target_dirs` | `store\batches.jsonl` (`plan`, `reconcile`), reports |
| **C-05** Timestamp, attribute and ACL comparison | Rows with category `metadata_mismatch`, and the `field` (`created`, `modified`, `attributes`, `acl`) | `reconcile.results.jsonl`, reports |
| **C-06** Exception register closed | Register with owner, status and resolution. `Get-MigrationException -Status open` is empty. | `store\batches\<id>\exceptions.jsonl`, final report |
| **C-07** Immutable, timestamped logs | Hash-chained JSONL per run, `.sha256` sidecar (interrupted runs are sealed at the next run and listed), Robocopy logs with sidecars, evidence manifest of every store file | `logs\`, `logs\robocopy\`, final report `evidence.manifest.csv` |
| **C-08** Maker-checker | Gate records with maker ≠ checker, run_id, comment, override flag, and a reference to the audit-log line | `store\gates.jsonl`, `gate.decision` audit events |
| **C-09** Three-party sign-off | Three distinct signers on the final report run | `store\signoff.jsonl`, final report sign-off table |
| **C-10** Source retained | Retention ticket and retain-until date | `store\retention.jsonl`, final report |

HTML checks evidence is in `htmlchecks.source|target|parity.<runId>.jsonl` and the batch reports.

---

## 10a. Scale guidance

Measured on a test workstation with local disks (50,000 files in one batch): about 15 minutes for the full pipeline, under 1.5 GB of memory per stage. Stages hold one batch's manifests in memory (roughly 3 KB per file), so:

- **Keep batches under about 200,000 files.** If a month holds more, batch by day: `batching.options.template = "{y}-{m}-{d}"` with a pattern that captures the day folder, e.g. `^(?<y>\d{4})[\\/](?<m>\d{2})[\\/](?<d>\d{2})`.
- Store files are compacted after each Reconcile (`reconcile.compactStore`); the previous versions are archived with checksums.
- The pilot report estimates the remaining duration from measured Copy throughput.
- Real UNC throughput will be lower than local disk; use the pilot numbers, not these.

---

## 11. Local testing (Windows or non-Windows workstation)

Use `config/migration.config.dev.json`. It sets:
- `aclReader: none`, with no `acl` in `fileFields`
- `copy.engine: dotnet`
- `makerCheckerDistinctUsers: false`, so that one developer can approve their own gates

**Do not use it in production.** Its paths are relative (`./.dev/source`, `./.dev/target`, `./.dev/work`), so run from the repository root.

```powershell
pwsh -NoProfile
./tools/New-SyntheticDataset.ps1 -Path ./.dev/source -Years (2019..2020) -MonthsPerYear 2 -FilesPerMonth 20 -Seed 7 -OldHost 'OLDSERVER01'
Import-Module ./NotificationMigration/NotificationMigration.psd1 -Force -DisableNameChecking
Migrate-Notifications -Stage Inventory -Config ./config/migration.config.dev.json
Approve-MigrationGate -Stage Inventory -Config ./config/migration.config.dev.json -Comment 'dev'
# ... Batching, then per batch Copy / Verify / Reconcile / HtmlChecks as in §6
./tools/Invoke-FaultInjection.ps1 -TargetRoot ./.dev/target -SourceRoot ./.dev/source -Fault Corrupt -Seed 3
Migrate-Notifications -Stage Reconcile -Batch 2019-01 -Config ./config/migration.config.dev.json   # must report the injected fault
```

**`tools/New-SyntheticDataset.ps1`** writes a deterministic `yyyy\MM\dd\*.html` tree with assets. It returns a summary object: `TotalFiles`, `TotalBytes`, `EdgeCases` counts, `Skipped` and `Files` with tags. Rules:
- The same `-Seed` produces byte-identical output, including timestamps.
- The target folder must be empty unless you pass `-Force`.

It covers these edge cases. Each one can be switched off with a `-Skip<Case>` switch:
- long paths over 260 characters (`\\?\` on Windows)
- deep nesting
- Unicode names (accented, CJK, emoji)
- trailing space or dot. Skipped with a warning where the platform refuses.
- case-only duplicates. Only created on case-sensitive file systems. Otherwise skipped with a warning.
- zero-byte files
- malformed HTML: no `<html>` element, binary NULs, truncated file
- UTF-8 BOM, UTF-16 LE, CRLF and LF files
- existing relative CSS and images
- a missing asset
- absolute links to `-OldHost` (`\\host\...`, `http://host/...`, `file://host/...`)
- a large file (`-LargeFileMB`)
- an unbatched root file

**`tools/Invoke-FaultInjection.ps1`** applies one fault to the **target only**:

| `-Fault` | What it does | Expected category |
|---|---|---|
| `Corrupt` | Flips one byte. Size and timestamps are kept. | `hash_mismatch` |
| `Delete` | Deletes the file. | `missing` |
| `Extra` | Creates a new file. | `extra` |
| `Timestamp` | Shifts the modified time by `-ShiftSeconds`. | `metadata_mismatch` |
| `Attributes` | Toggles ReadOnly. | `metadata_mismatch` |

Without `-RelPath`, the file is picked deterministically from `-Seed`. The script refuses to run when `-TargetRoot` and `-SourceRoot` are the same or nested, and it supports `-WhatIf`.

---

## 12. Extending: providers

Stages never hard-code a strategy. They look up a **provider** by the name in config. To add one, drop a `.ps1` into `NotificationMigration/Providers/<Kind>/`. It is loaded automatically and must call `Register-MigProvider`. Signatures are defined in `Core/Registry.ps1`:

| Kind | Selected by | Scriptblock | Returns |
|---|---|---|---|
| `Batch` | `batching.strategy` | `param($RelPath, $Record, $Options)` | batch id (use `ConvertTo-MigSafeBatchId`) |
| `Copy` | `copy.engine` | `param($Ctx, $BatchId, $Plan)` | `@{ exit_code; succeeded; copied; failed; log_path }` |
| `Compare` | names in `compare.fileFields` / `dirFields` | `param($Ctx, $Source, $Target, $Options)` | `$null` if equal, else a detail string |
| `HtmlRule` | `htmlChecks.rules.<name>.enabled` | `param($Ctx, $BatchId, $Side, $Root, $Records, $Options)` | findings `@{ rule; rel_path; severity; detail }`, with no absolute paths |
| `Report` | `report.formats` | `param($Ctx, $Report, $OutDir, $BaseName)` | written file paths |

Example: batches by year only.
```powershell
# NotificationMigration/Providers/Batch/Year.ps1
Register-MigProvider -Kind Batch -Name 'year' -ScriptBlock {
    param($RelPath, $Record, $Options)
    if ($RelPath -match '^(\d{4})\\') { return ConvertTo-MigSafeBatchId $Matches[1] }
    return $Options.unmatchedBatchId
}
```
Then set `"batching": { "strategy": "year", "options": { "unmatchedBatchId": "UNBATCHED" } }`.

Rules for providers:
- **Config validation.** `compare.fileFields`/`dirFields` and `report.formats` are validated against fixed lists in `Core/Config.ps1`. A new Compare field or Report format also needs its name added there, and any new config key goes into `config/defaults.json`.
- **Platform and style.** Providers must follow the architecture's hard rules: PS 5.1 compatible, no `.GetNewClosure()`, and nothing hard-coded.

---

## 13. Running the tests

Pester 5+ is needed only on the test machine. Windows ships 3.4. Install it with:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

On an offline host, use `Save-Module` elsewhere and copy the module over.

```powershell
Invoke-Pester ./tests -Output Detailed                      # everything
Invoke-Pester ./tests/Unit -Output Detailed                 # unit tests only
Invoke-Pester ./tests/Integration -Output Detailed         # end-to-end: every stage, gates, fault injection, final report
```

Tests use `$TestDrive` and the synthetic dataset. They never touch real paths. On non-Windows they use the dev settings (`aclReader none`, `copy.engine dotnet`).

---

## 14. Repository layout

```
migration.config.sample.json        production-style example config
config/migration.config.dev.json    local testing config (relative ./.dev paths)
Notification_Migration_Requirements.md   the spec
docs/ARCHITECTURE.md                contracts for contributors
NotificationMigration/
  NotificationMigration.psd1/.psm1  module manifest + loader (Core -> Providers -> Stages -> Public)
  config/defaults.json              every default value
  Core/        Common Safety Config Registry Parallel Store Audit Scanner Gates Context
  Providers/   Batch/ Copy/ Compare/ HtmlRule/ Report/
  Stages/      Inventory Batching Copy Verify Reconcile HtmlChecks Delta Report
  Public/      Commands.ps1
tests/Unit/  tests/Integration/
tools/New-SyntheticDataset.ps1      edge-case test data generator
tools/Invoke-FaultInjection.ps1     target-only fault injector
```
