import { BigQuery, Dataset, Table } from '@google-cloud/bigquery';
import winston from 'winston';
import {
  BackupOptions,
  BackupResult,
  DatasetInfo,
  TableInfo,
} from './types';
import {
  generateBackupDatasetName,
  validateTimeTravelTimestamp,
  calculateExpirationTimestamp,
} from './utils';
import { BACKUP_DATASET_PREFIX } from './constants';

const DEFAULT_EXPIRATION_DAYS = 90; // 3 months

export class BackupService {
  private bq: BigQuery;
  private logger: winston.Logger;

  constructor(projectId: string, logger: winston.Logger) {
    this.bq = new BigQuery({ projectId });
    this.logger = logger;
  }

  /**
   * Lists all datasets in the project or specific datasets
   */
  async listDatasets(datasets?: string[]): Promise<DatasetInfo[]> {
    const datasetInfos: DatasetInfo[] = [];

    if (datasets && datasets.length > 0) {
      // List specific datasets
      for (const datasetId of datasets) {
        try {
          const dataset = this.bq.dataset(datasetId);
          const [exists] = await dataset.exists();
          if (!exists) {
            this.logger.warn(`Dataset ${datasetId} does not exist, skipping.`);
            continue;
          }

          const [metadata] = await dataset.getMetadata();
          datasetInfos.push({
            datasetId,
            location: metadata.location,
            tables: [],
          });
        } catch (error) {
          this.logger.error(`Error accessing dataset ${datasetId}:`, error);
          throw error;
        }
      }
    } else {
      // List all datasets
      this.logger.debug('Listing all datasets in project...');
      const [allDatasets] = await this.bq.getDatasets();
      for (const dataset of allDatasets) {
        // Exclude datasets whose name starts with backup prefix
        if (dataset.id && dataset.id.startsWith(BACKUP_DATASET_PREFIX)) {
          this.logger.debug(`Skipping backup dataset ${dataset.id}`);
          continue;
        }
        const [metadata] = await dataset.getMetadata();
        datasetInfos.push({
          datasetId: dataset.id!,
          location: metadata.location,
          tables: [],
        });
      }
    }

    return datasetInfos;
  }

  /**
   * Lists all tables in a dataset, filtering to only TABLE type
   */
  async listTables(datasetId: string): Promise<TableInfo[]> {
    const dataset = this.bq.dataset(datasetId);
    const [tables] = await dataset.getTables();
    const tableInfos: TableInfo[] = [];

    for (const table of tables) {
      try {
        const [metadata] = await table.getMetadata();
        // Only include TABLE type, exclude views, models, etc.
        if (metadata.type === 'TABLE') {
          tableInfos.push({
            tableId: table.id!,
            type: metadata.type,
            location: metadata.location,
          });
        } else {
          this.logger.debug(
            `Skipping ${table.id} (type: ${metadata.type}) - only TABLE type is backed up`
          );
        }
      } catch (error) {
        this.logger.warn(`Error getting metadata for table ${table.id}:`, error);
      }
    }

    return tableInfos;
  }

  /**
   * Creates a backup dataset
   */
  async createBackupDataset(
    backupDatasetId: string,
    sourceLocation: string,
    dryRun: boolean = false
  ): Promise<Dataset> {
    const location = sourceLocation;
    const dataset = this.bq.dataset(backupDatasetId);

    const [exists] = await dataset.exists();
    if (exists) {
      throw new Error(`Backup dataset ${backupDatasetId} already exists`);
    }

    if (dryRun) {
      this.logger.info(`  [DRY RUN] Would create backup dataset: ${backupDatasetId} in location: ${location}`);
      return dataset;
    } else {
      await dataset.create({
        location,
        description: `Backup dataset created by bq-backup-and-restore`,
      });
    }

    this.logger.debug(`Created backup dataset: ${backupDatasetId} in location: ${location}`);
    return dataset;
  }

  /**
   * Creates a snapshot of a table
   */
  async createTableSnapshot(
    sourceDatasetId: string,
    sourceTableId: string,
    backupDatasetId: string,
    backupTableId: string,
    snapshotTimestamp: Date,
    expirationTimestamp?: Date,
    dryRun?: boolean
  ): Promise<void> {
    const sourceTableRef = `\`${this.bq.projectId}.${sourceDatasetId}.${sourceTableId}\``;
    const backupTableRef = `\`${this.bq.projectId}.${backupDatasetId}.${backupTableId}\``;
    // Ensure timestamp is in UTC for BigQuery SQL
    const timestampMillis = snapshotTimestamp.getTime();

    let snapshotQuery = `CREATE SNAPSHOT TABLE ${backupTableRef}\n`;
    snapshotQuery += `CLONE ${sourceTableRef}\n`;
    snapshotQuery += `FOR SYSTEM_TIME AS OF TIMESTAMP_MILLIS(${timestampMillis})`;

    if (expirationTimestamp) {
      snapshotQuery += `\nOPTIONS(expiration_timestamp = TIMESTAMP_MILLIS(${expirationTimestamp.getTime()}))`;
    }

    this.logger.debug(`Creating snapshot with query:\n${snapshotQuery}`);

    if (dryRun) {
      this.logger.info(`  [DRY RUN] Would create snapshot with query:\n${snapshotQuery}`);
      return;
    } else {
      const [job] = await this.bq.createQueryJob({
        query: snapshotQuery,
        useLegacySql: false,
      });
      await job.promise();
    }
    this.logger.debug(`Snapshot created: ${backupTableRef}`);
  }

  /**
   * Backs up a single dataset
   */
  async backupDataset(options: BackupOptions): Promise<BackupResult[]> {
    const results: BackupResult[] = [];
    // Ensure timestamp is in UTC - use current UTC time if not provided
    const backupTimestamp = options.timestamp || new Date(Date.now());

    this.logger.info(`Backup timestamp: ${backupTimestamp.toISOString()}`);

    const expirationDays = options.expirationDays ?? DEFAULT_EXPIRATION_DAYS;
    const expirationTimestamp = calculateExpirationTimestamp(backupTimestamp, expirationDays);

    // Validate timestamp if provided
    if (options.timestamp) {
      if (!validateTimeTravelTimestamp(options.timestamp, this.logger)) {
        throw new Error('Invalid timestamp for time travel');
      }
    }

    this.logger.info(`Backup start timestamp: ${backupTimestamp.toISOString()}`);
    if (expirationTimestamp) {
      this.logger.info(
        `Snapshots will expire on: ${expirationTimestamp.toISOString()} (${expirationDays} days)`
      );
    } else {
      this.logger.info('Snapshots will be retained indefinitely');
    }

    // List datasets to backup
    const datasets = await this.listDatasets(options.datasets);
    this.logger.info(`Found ${datasets.length} dataset(s) to backup`);

    for (const datasetInfo of datasets) {
      const result: BackupResult = {
        backupDatasetId: '',
        sourceDatasetId: datasetInfo.datasetId,
        timestamp: backupTimestamp,
        tablesBackedUp: 0,
        success: false,
        errors: [],
      };

      try {
        // List tables in the dataset
        const tables = await this.listTables(datasetInfo.datasetId);
        this.logger.info(`Backing up dataset: ${datasetInfo.datasetId}`);
        this.logger.info(`  - Found ${tables.length} table(s)`);

        if (tables.length === 0) {
          this.logger.warn(`  - No tables to backup in dataset ${datasetInfo.datasetId}`);
          result.success = true;
          results.push(result);
          continue;
        }

        // Generate backup dataset name
        const backupDatasetId = generateBackupDatasetName(
          datasetInfo.datasetId,
          backupTimestamp
        );
        result.backupDatasetId = backupDatasetId;

        // Create backup dataset - location is required
        if (!datasetInfo.location) {
          throw new Error(`Dataset ${datasetInfo.datasetId} does not have a location specified`);
        }

        await this.createBackupDataset(
          backupDatasetId,
          datasetInfo.location,
          options.dryRun
        );
        this.logger.info(`  - Created backup dataset: ${backupDatasetId}`);

        // Create snapshots for each table
        const snapshotPromises = tables.map(async (table) => {
          try {
            await this.createTableSnapshot(
              datasetInfo.datasetId,
              table.tableId,
              backupDatasetId,
              table.tableId, // Same table name in backup
              backupTimestamp,
              expirationTimestamp,
              options.dryRun
            );
            this.logger.info(
              `  - Created snapshot at ${backupTimestamp.toISOString()}: ${table.tableId} ✓`
            );
            return { success: true, tableId: table.tableId };
          } catch (error) {
            const errorMsg = `Failed to create snapshot for ${table.tableId}: ${error}`;
            this.logger.error(`  - ${errorMsg}`);
            return { success: false, tableId: table.tableId, error: errorMsg };
          }
        });

        const snapshotResults = await Promise.all(snapshotPromises);
        const successful = snapshotResults.filter((r) => r.success).length;
        const failed = snapshotResults.filter((r) => !r.success);

        result.tablesBackedUp = successful;
        result.success = failed.length === 0;

        if (failed.length > 0) {
          result.errors = failed.map((f) => f.error || 'Unknown error');
          this.logger.warn(
            `  - Completed with ${failed.length} error(s) out of ${tables.length} table(s)`
          );
        } else {
          this.logger.info(
            `  - Successfully backed up ${successful} table(s) to ${backupDatasetId}`
          );
        }
      } catch (error) {
        const errorMsg = `Error backing up dataset ${datasetInfo.datasetId}: ${error}`;
        this.logger.error(errorMsg, error);
        result.errors = [errorMsg];
        result.success = false;
      }
      results.push(result);
    }

    return results;
  }
}

