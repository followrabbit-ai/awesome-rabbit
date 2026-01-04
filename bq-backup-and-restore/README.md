# bq-backup-and-restore

A command-line tool for creating and restoring backups of BigQuery datasets. This tool provides a simple way to backup entire datasets (tables only) and restore them when needed.

## Overview

`bq-backup-and-restore` is a TypeScript/Node.js CLI tool that enables you to:
- Create backups of BigQuery datasets (all tables within a dataset)
- Backup all datasets in a project or specific datasets
- Create point-in-time backups using BigQuery's time travel feature (last 7 days)
- List and manage backup datasets
- Restore datasets from backups (interactive or with explicit timestamp)
- Delete backups by timestamp

## Project Structure

```
bq-backup-and-restore/
├── src/
│   ├── index.ts          # CLI entry point with commander.js
│   ├── backup.ts         # Core backup functionality
│   ├── list-backups.ts   # List backups functionality
│   ├── logger.ts         # Winston logging configuration
│   ├── types.ts          # TypeScript type definitions
│   └── utils.ts          # Utility functions
├── package.json          # Dependencies and scripts
├── tsconfig.json         # TypeScript configuration
├── .gitignore           # Git ignore rules
└── README.md            # User documentation
```

## Design

### Backup Mechanism

#### Current State Backups
When creating a backup without a user-specified timestamp, the tool uses BigQuery's native **table snapshots** feature with a consistent timestamp:
1. Captures the backup start timestamp when the operation begins
2. Lists all tables in the source dataset(s)
3. Filters to include only `TABLE` type objects (excludes views, materialized views, models, etc.)
4. Creates a new dataset with the naming pattern: `zzz_backup_yyyyMMdd_hhmmss_{{source_dataset}}` (using the backup start timestamp)
5. Creates a snapshot of each table using `CREATE SNAPSHOT TABLE ... CLONE ... FOR SYSTEM_TIME AS OF <backup_start_timestamp> OPTIONS(expiration_timestamp = <expiration>)`
6. **All tables in the backup use the same timestamp**, ensuring data consistency across all tables in the backup
7. Snapshots are created with an expiration timestamp (default: 3 months from backup time, configurable via `--expiration-days`)
8. Snapshots are storage-efficient as they only store differences from the base table
9. Snapshots can be retained beyond the 7-day time travel window

**Why use a timestamp for "current state" backups?**
- **Data Consistency**: All tables in a backup reflect the exact same point in time
- **Prevents Inconsistencies**: Without a timestamp, tables backed up sequentially could reflect slightly different states if data changes during the backup process
- **Reproducibility**: The backup represents a consistent snapshot of the dataset at a specific moment

**Benefits of using snapshots:**
- **Storage efficient**: Only stores incremental changes, not full copies
- **Fast creation**: Snapshot creation is nearly instantaneous
- **Long retention**: Can be retained indefinitely (unlike time travel's 7-day limit)
- **Read-only**: Snapshots are immutable, ensuring data integrity

#### Point-in-Time Backups
When a timestamp is explicitly provided by the user, the tool leverages BigQuery's **time travel** feature:
1. Validates that the timestamp is within the last 7 days (BigQuery's time travel retention period)
2. For each table, creates a snapshot using time travel: `CREATE SNAPSHOT TABLE ... CLONE ... FOR SYSTEM_TIME AS OF <user_specified_timestamp> OPTIONS(expiration_timestamp = <expiration>)`
3. **All tables use the same user-specified timestamp**, ensuring consistency
4. Snapshots are created with an expiration timestamp (default: 3 months from backup time, configurable via `--expiration-days`)
5. The snapshot captures the table state at the specified historical point in time
6. This allows you to restore tables to a specific historical state

**Note**: The difference between "current state" and "point-in-time" backups is:
- **Current state**: Uses the timestamp when the backup operation starts (captured automatically)
- **Point-in-time**: Uses a timestamp explicitly provided by the user (for historical backups)

#### Dataset Naming Convention
- Format: `zzz_backup_yyyyMMdd_hhmmss_{{source_dataset}}`
- Example: `zzz_backup_20241215_143022_my_dataset`
- The `zzz_` prefix ensures backup datasets appear at the end of dataset lists
- The timestamp format ensures:
  - Chronological sorting
  - No special characters that could cause issues
  - Clear identification of backup time

### Table Filtering
The tool only backs up tables that have `type === 'TABLE'`, excluding:
- Views (`VIEW`)
- Materialized Views (`MATERIALIZED_VIEW`)
- Models (`MODEL`)
- External tables (handled separately if needed)
- Snapshots

### Error Handling
- Validates project and dataset existence before starting
- Handles partial failures gracefully (continues with remaining tables)
- Provides detailed error messages for troubleshooting
- Logs all operations for audit purposes

### Performance Considerations
- Operations run in parallel where possible (multiple tables)
- Uses BigQuery's native snapshot feature for near-instantaneous backups
- Snapshots are created using `CREATE SNAPSHOT TABLE` SQL statements
- Progress indicators for operations

### Snapshot Creation
The tool uses BigQuery's native snapshot feature with SQL:
```sql
CREATE SNAPSHOT TABLE `project.backup_dataset.table`
CLONE `project.source_dataset.table`
FOR SYSTEM_TIME AS OF TIMESTAMP('YYYY-MM-DD HH:MM:SS')
OPTIONS(expiration_timestamp = TIMESTAMP('YYYY-MM-DD HH:MM:SS'))
```

## Installation

### Prerequisites
- Node.js >= 25.0.0
- npm or yarn
- Google Cloud SDK installed and authenticated
- Appropriate BigQuery permissions:
  - `bigquery.datasets.get`
  - `bigquery.datasets.create`
  - `bigquery.tables.get`
  - `bigquery.tables.create`
  - `bigquery.tables.updateData` (for creating snapshots)
  - `bigquery.jobs.create`

### Setup

```bash
cd bq-backup-and-restore
npm install
npm run build
```

## User Guide

### Running Commands

When using `npm start` to run commands, you must use `--` to separate npm arguments from script arguments. This tells npm to pass everything after `--` to the script.

**Correct usage:**
```bash
npm start -- list-backups --project-id=my-project-id
```

**Alternative: Run the built binary directly**
```bash
node build/index.js list-backups --project-id=my-project-id
```

**Or use npx (if installed globally)**
```bash
npx bq-backup-and-restore list-backups --project-id=my-project-id
```

### Backup Functionality

#### Basic Usage

**Backup all datasets in a project:**
```bash
npm start -- backup --project-id=my-project-id
```

**Backup specific datasets:**
```bash
npm start -- backup --project-id=my-project-id --datasets=dataset1,dataset2,dataset3
```

**Backup current state (explicit):**
```bash
npm start -- backup --project-id=my-project-id --datasets=my_dataset
```

**Backup point-in-time (last 7 days):**
```bash
npm start -- backup --project-id=my-project-id --datasets=my_dataset --timestamp="2024-12-15T14:30:22Z"
```

#### Command Options

| Option | Required | Description | Example |
|--------|----------|-------------|---------|
| `--project-id` | Yes | GCP project ID containing the datasets | `--project-id=my-gcp-project` |
| `--datasets` | No | Comma-separated list of dataset IDs. If omitted, backs up all datasets in the project | `--datasets=dataset1,dataset2` |
| `--timestamp` | No | ISO 8601 timestamp for point-in-time backup. Must be within last 7 days. If omitted, backs up current state | `--timestamp="2024-12-15T14:30:22Z"` |
| `--expiration-days` | No | Number of days to retain snapshots before automatic deletion. Default: 90 days (3 months). Set to 0 for indefinite retention (not recommended) | `--expiration-days=30` |
| `--log-level` | No | Logging level: debug, info, warn, error. Default: info | `--log-level=debug` |
| `--dry-run` | No | Show what would be done without making any changes | `--dry-run` |

#### Examples

**Example 1: Backup all datasets in a project**
```bash
npm start -- backup --project-id=production-project
```

Output:
```
Starting backup operation...
Backup start timestamp: 2024-12-15T14:30:22Z
Found 5 datasets in project: production-project
Backing up dataset: analytics
  - Found 12 tables
  - Creating backup dataset: zzz_backup_20241215_143022_analytics
  - Creating snapshot at 2024-12-15T14:30:22Z: users_table ✓
  - Creating snapshot at 2024-12-15T14:30:22Z: orders_table ✓
  ...
Backup completed successfully!
Backup dataset: zzz_backup_20241215_143022_analytics
All tables backed up as snapshots at consistent timestamp: 2024-12-15T14:30:22Z
```

**Example 2: Backup specific dataset with point-in-time**
```bash
npm start -- backup \
  --project-id=production-project \
  --datasets=analytics \
  --timestamp="2024-12-15T10:00:00Z"
```

**Example 3: Backup multiple datasets**
```bash
npm start -- backup \
  --project-id=production-project \
  --datasets=analytics,warehouse,staging
```

**Example 4: Backup with custom snapshot expiration**
```bash
# Use default expiration (3 months / 90 days)
npm start -- backup --project-id=production-project --datasets=analytics

# Custom expiration: 30 days
npm start -- backup \
  --project-id=production-project \
  --datasets=analytics \
  --expiration-days=30

# Custom expiration: 6 months (180 days)
npm start -- backup \
  --project-id=production-project \
  --datasets=analytics \
  --expiration-days=180

# Retain indefinitely (not recommended - will incur ongoing storage costs)
npm start -- backup \
  --project-id=production-project \
  --datasets=analytics \
  --expiration-days=0
```

**Example 5: Backup with dry-run (preview without making changes)**
```bash
npm start -- backup \
  --project-id=production-project \
  --datasets=analytics \
  --dry-run
```

This will show what would be backed up without actually creating any backup datasets or snapshots.

By default, snapshots expire after 3 months (90 days) to help manage storage costs. You can customize this or set to 0 for indefinite retention.

#### Timestamp Format

The timestamp must be in ISO 8601 format:
- `YYYY-MM-DDTHH:mm:ssZ` (UTC)
- `YYYY-MM-DDTHH:mm:ss+00:00` (UTC with timezone)
- `YYYY-MM-DDTHH:mm:ss-05:00` (with timezone offset)

Examples:
- `2024-12-15T14:30:22Z`
- `2024-12-15T14:30:22+00:00`
- `2024-12-15T09:30:22-05:00`

**Important Notes:**
- **Timestamp Consistency**: All tables in a backup use the same timestamp to ensure data consistency
  - For "current state" backups: Uses the backup start timestamp (captured automatically)
  - For "point-in-time" backups: Uses the user-specified timestamp
- User-specified timestamps must be within the last 7 days (BigQuery's time travel retention)
- The tool will validate user-specified timestamps before starting the backup
- Time travel is only available for tables, not views or other objects

#### Backup Dataset Structure

After a backup, you'll have:
```
project-id/
├── source_dataset/
│   ├── table1
│   ├── table2
│   └── ...
└── zzz_backup_20241215_143022_source_dataset/
    ├── table1  (snapshot of table1)
    ├── table2  (snapshot of table2)
    └── ...
```

**Note:** The tables in the backup dataset are snapshots, not regular tables. They are read-only and storage-efficient, storing only the differences from the base tables.

#### Listing Backups

To see all backup datasets in a project:
```bash
npm start -- list-backups --project-id=my-project-id
```

This will show:
- Backup dataset names
- Source dataset names
- Backup timestamps
- Number of tables in each backup
- Location of each backup

You can also control logging verbosity:
```bash
npm start -- list-backups --project-id=my-project-id --log-level=debug
```

### Delete Backups Functionality

The `delete-backups` command allows you to delete backups grouped by timestamp. It provides an interactive interface to safely select and delete backup datasets.

#### Basic Usage

**Delete backups by timestamp:**
```bash
npm start -- delete-backups --project-id=my-project-id
```

The command will:
1. List all backup datasets grouped by their backup timestamp
2. Display each timestamp with its associated backup datasets
3. Prompt you to select a timestamp by index number
4. Ask for confirmation before deletion
5. Delete all backup datasets for the selected timestamp

#### Command Options

| Option | Required | Description | Example |
|--------|----------|-------------|---------|
| `--project-id` | Yes | GCP project ID | `--project-id=my-gcp-project` |
| `--log-level` | No | Logging level: debug, info, warn, error. Default: info | `--log-level=debug` |
| `--dry-run` | No | Show what would be deleted without making any changes | `--dry-run` |

#### Examples

**Example 1: Delete backups interactively**
```bash
npm start -- delete-backups --project-id=production-project
```

Output:
```
Listing backups in project: production-project...

Found 3 backup timestamp(s):

[1] 2024-12-15T14:30:22.000Z
    Datasets (2):
      - zzz_backup_20241215_143022_analytics (source: analytics)
      - zzz_backup_20241215_143022_warehouse (source: warehouse)

[2] 2024-12-14T10:00:00.000Z
    Datasets (1):
      - zzz_backup_20241214_100000_staging (source: staging)

[3] 2024-12-13T08:15:30.000Z
    Datasets (1):
      - zzz_backup_20241213_081530_analytics (source: analytics)

Select backup timestamp to delete (1-3, or 'q' to quit): 2

Selected backup timestamp: 2024-12-14T10:00:00.000Z
This will delete 1 backup dataset(s).
Are you sure you want to delete these backups? (yes/no): yes

Deleting 1 backup dataset(s)...
Deleted backup dataset: zzz_backup_20241214_100000_staging

Deletion complete: 1 succeeded, 0 failed
All selected backups have been deleted successfully.
```

**Example 2: Cancel deletion**
```bash
npm start -- delete-backups --project-id=production-project
```

If you enter 'q' or 'quit' when prompted, or answer 'no' to the confirmation, the operation will be cancelled.

**Example 3: Delete with dry-run (preview without making changes)**
```bash
npm start -- delete-backups --project-id=production-project --dry-run
```

This will show what would be deleted without actually deleting any backup datasets.

#### Safety Features

- **Interactive selection**: You must explicitly select which timestamp to delete
- **Confirmation required**: You must confirm with 'yes' before deletion proceeds
- **Grouped by timestamp**: All backups from the same backup operation are grouped together
- **Clear display**: Shows exactly which datasets will be deleted before confirmation

### Restore Functionality

The `restore` command allows you to restore datasets from backup snapshots. You can restore to the original dataset name or specify a different target dataset.

#### Basic Usage

**Restore with interactive backup selection:**
```bash
npm start -- restore --project-id=my-project-id
```

**Restore with explicit backup timestamp:**
```bash
npm start -- restore --project-id=my-project-id --backup-timestamp="2024-12-15T14:30:22Z"
```

**Restore with overwrite (replace existing tables):**
```bash
npm start -- restore --project-id=my-project-id --backup-timestamp="2024-12-15T14:30:22Z" --overwrite
```

#### Command Options

| Option | Required | Description | Example |
|--------|----------|-------------|---------|
| `--project-id` | Yes | GCP project ID | `--project-id=my-gcp-project` |
| `--backup-timestamp` | No | ISO 8601 timestamp of the backup to restore. If omitted, lists available backups for interactive selection | `--backup-timestamp="2024-12-15T14:30:22Z"` |
| `--overwrite` | No | Overwrite existing tables if they exist. Default: false (fails if table exists) | `--overwrite` |
| `--log-level` | No | Logging level: debug, info, warn, error. Default: info | `--log-level=debug` |
| `--dry-run` | No | Show what would be restored without making any changes | `--dry-run` |
| `--dry-run` | No | Show what would be restored without making any changes | `--dry-run` |

#### Examples

**Example 1: Interactive restore (no timestamp specified)**
```bash
npm start -- restore --project-id=production-project
```

Output:
```
Listing backups in project: production-project...

Found 3 backup timestamp(s):

[1] 2024-12-15T14:30:22.000Z
    Datasets (2):
      - zzz_backup_20241215_143022_analytics (source: analytics)
      - zzz_backup_20241215_143022_warehouse (source: warehouse)

[2] 2024-12-14T10:00:00.000Z
    Datasets (1):
      - zzz_backup_20241214_100000_staging (source: staging)

Select backup timestamp to restore (1-2, or 'q' to quit): 1

Selected backup timestamp: 2024-12-15T14:30:22.000Z
Starting restore operation...
Found 2 backup dataset(s) for timestamp 2024-12-15T14:30:22.000Z
Restoring from backup: zzz_backup_20241215_143022_analytics
  - Found 12 table(s) to restore
  - Target dataset: analytics
  - Restored table: users_table ✓
  - Restored table: orders_table ✓
  ...
  - Recreating materialized views in dataset analytics...
  - Found 3 materialized view(s) to recreate in dataset analytics
  - Recreated materialized view: mv_reservation_hourly ✓
  - Recreated materialized view: mv_usage_summary ✓
  - Recreated materialized view: mv_daily_stats ✓
  - Successfully restored 12 table(s) to analytics
  - Recreated 3 materialized view(s) in analytics
Restore completed successfully!
```

**Example 2: Restore with explicit timestamp**
```bash
npm start -- restore \
  --project-id=production-project \
  --backup-timestamp="2024-12-15T14:30:22Z"
```

**Example 4: Restore with overwrite**
```bash
npm start -- restore \
  --project-id=production-project \
  --backup-timestamp="2024-12-15T14:30:22Z" \
  --overwrite
```

This will replace existing tables if they already exist in the target dataset.

**Example 5: Restore with dry-run (preview without making changes)**
```bash
npm start -- restore \
  --project-id=production-project \
  --backup-timestamp="2024-12-15T14:30:22Z" \
  --dry-run
```

This will show what would be restored, including which tables and materialized views would be recreated, without actually performing the restore operation.

#### How Restore Works

1. **Snapshot to Table Conversion**: Restores convert snapshot tables back to regular tables
2. **Table Cloning**: Uses BigQuery's `CLONE` operation for efficient restoration
3. **Atomic Overwrite**: When `--overwrite` is used, `CREATE OR REPLACE TABLE` is used for atomic replacement (no time gap)
4. **Dataset Creation**: Automatically creates the target dataset if it doesn't exist (uses location from backup)
5. **Consistent Restoration**: All tables from the same backup timestamp are restored together
6. **Materialized View Recreation**: After restoring tables, automatically recreates all materialized views in the restored datasets that reference the restored tables

#### Materialized View Handling

**Automatic Recreation:**
- After restoring tables in a dataset, the tool automatically:
  1. Scans the restored dataset for materialized views
  2. Extracts the query definition and refresh settings from each materialized view
  3. Deletes the existing materialized view
  4. Recreates it with the same definition and settings

This ensures that materialized views continue to work correctly after table restoration, as BigQuery requires materialized views to be recreated when their underlying tables are deleted and recreated.

**Important Warning:**
> ⚠️ **Materialized views outside restored datasets**: The tool only automatically recreates materialized views that are **within the same dataset** as the restored tables. If you have materialized views in other datasets that reference the restored tables, you must **manually recreate them** after the restore operation completes. These materialized views will fail with errors like:
> ```
> Materialized view project:other_dataset.mv_name references table project:restored_dataset.table_name 
> which was deleted and recreated. The view must be deleted and recreated as well.
> ```

#### Important Notes

- **Existing Tables**: By default, restore fails if target tables already exist. Use `--overwrite` to replace them
- **Multiple Backups**: If multiple datasets were backed up at the same timestamp, all will be restored
- **Location**: Target datasets are created in the same location as the backup dataset
- **Materialized Views**: Automatically recreated in restored datasets. Views in other datasets must be manually recreated

## Troubleshooting

### Common Issues

**Error: "Dataset not found"**
- Verify the project ID and dataset names are correct
- Ensure you have appropriate permissions
- Check that the dataset exists in the specified project

**Error: "Timestamp is outside time travel retention period"**
- BigQuery time travel only supports the last 7 days
- Use a more recent timestamp
- For older backups, you'll need to use existing backups or snapshots

**Error: "Insufficient permissions"**
- Ensure your account has the required BigQuery permissions
- Check IAM roles: `roles/bigquery.dataEditor` or `roles/bigquery.admin`

**Backup takes too long**
- Snapshot creation is typically very fast, but large datasets with many tables may take time
- The tool shows progress for each table
- Consider backing up datasets individually if needed

### Logs

Control logging verbosity using the `--log-level` option:
```bash
# Debug level (most verbose)
npm start -- backup --project-id=my-project --log-level=debug

# Info level (default)
npm start -- backup --project-id=my-project --log-level=info

# Warn level (only warnings and errors)
npm start -- backup --project-id=my-project --log-level=warn

# Error level (only errors)
npm start -- backup --project-id=my-project --log-level=error
```

The tool uses [Winston](https://github.com/winstonjs/winston) for logging with colorized console output and structured formatting.

## Limitations

1. **Time Travel Window**: Point-in-time backups are limited to the last 7 days (BigQuery's time travel retention period)
2. **Table Types**: Only standard tables are backed up (views, models, etc. are excluded). Snapshots cannot be created from views or materialized views
3. **Storage Costs**: While snapshots are storage-efficient (only storing differences), they still consume storage and incur costs. Monitor snapshot retention to manage costs
4. **Snapshot Retention**: Snapshots default to 3 months (90 days) expiration. You can customize this with `--expiration-days` or set to 0 for indefinite retention (not recommended due to storage costs)
5. **Concurrent Operations**: Large datasets with many tables may take time; the tool processes tables in parallel but respects BigQuery quotas
6. **Snapshot Limitations**: Snapshots are read-only and cannot be modified. To restore, you'll need to clone the snapshot back to a regular table

## Dependencies

- `@google-cloud/bigquery`: ^7.9.1 - BigQuery client library
- `commander`: ^12.1.0 - CLI framework
- `winston`: ^3.11.0 - Logging framework
- `typescript`: ^5.2.2 - TypeScript compiler
- Node.js: >= 25.0.0

## Contributing

Contributions are welcome! Please see the main [awesome-rabbit README](../README.md) for contribution guidelines.

## License

This project is licensed under the Apache 2.0 License - see the [LICENSE](../LICENSE) file for details.

