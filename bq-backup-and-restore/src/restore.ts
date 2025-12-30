import { BigQuery, Dataset, Table } from '@google-cloud/bigquery';
import winston from 'winston';
import { BackupInfo } from './list-backups';
import { BACKUP_DATASET_PREFIX } from './constants';

export interface RestoreOptions {
  projectId: string;
  backupTimestamp?: Date;
  overwrite?: boolean;
}

export interface RestoreResult {
  sourceBackupDatasetId: string;
  targetDatasetId: string;
  tablesRestored: number;
  materializedViewsRecreated: number;
  success: boolean;
  errors?: string[];
}

export interface MaterializedViewInfo {
  viewId: string;
  query: string;
  enableRefresh?: boolean;
  refreshIntervalMs?: number;
}

export class RestoreService {
  private bq: BigQuery;
  private logger: winston.Logger;

  constructor(projectId: string, logger: winston.Logger) {
    this.bq = new BigQuery({ projectId });
    this.logger = logger;
  }

  /**
   * Lists all backup datasets for a specific timestamp
   */
  async listBackupsForTimestamp(timestamp: Date): Promise<BackupInfo[]> {
    const [allDatasets] = await this.bq.getDatasets();
    const backupInfos: BackupInfo[] = [];

    // Format timestamp to match backup dataset naming pattern
    const year = timestamp.getUTCFullYear();
    const month = String(timestamp.getUTCMonth() + 1).padStart(2, '0');
    const day = String(timestamp.getUTCDate()).padStart(2, '0');
    const hours = String(timestamp.getUTCHours()).padStart(2, '0');
    const minutes = String(timestamp.getUTCMinutes()).padStart(2, '0');
    const seconds = String(timestamp.getUTCSeconds()).padStart(2, '0');
    const timestampStr = `${year}${month}${day}_${hours}${minutes}${seconds}`;

    for (const dataset of allDatasets) {
      const datasetId = dataset.id!;
      
      // Check if dataset name matches backup pattern and timestamp
      if (!datasetId.startsWith(BACKUP_DATASET_PREFIX)) {
        continue;
      }

      // Check if timestamp matches
      if (!datasetId.includes(timestampStr)) {
        continue;
      }

      try {
        const parts = datasetId.split('_');
        if (parts.length < 5) {
          continue;
        }

        // Extract source dataset name
        const sourceDatasetId = parts.slice(4).join('_');

        backupInfos.push({
          backupDatasetId: datasetId,
          sourceDatasetId,
          timestamp,
        });
      } catch (error) {
        this.logger.warn(`Error processing backup dataset ${datasetId}:`, error);
      }
    }

    return backupInfos;
  }

  /**
   * Lists all tables in a backup dataset (snapshots)
   */
  async listBackupTables(backupDatasetId: string): Promise<string[]> {
    const dataset = this.bq.dataset(backupDatasetId);
    const [tables] = await dataset.getTables();
    const tableIds: string[] = [];

    for (const table of tables) {
      try {
        const [metadata] = await table.getMetadata();
        if (metadata.type === 'SNAPSHOT' ) {
          tableIds.push(table.id!);
        } else {
            this.logger.warn(`Skipping table ${table.id} (type: ${metadata.type}) - only SNAPSHOT type is supported`);
            continue;
        }
      } catch (error) {
        this.logger.warn(`Error getting metadata for table ${table.id}:`, error);
      }
    }

    return tableIds;
  }

  /**
   * Lists all materialized views in a dataset
   */
  async listMaterializedViews(datasetId: string): Promise<MaterializedViewInfo[]> {
    const dataset = this.bq.dataset(datasetId);
    const [tables] = await dataset.getTables();
    const materializedViews: MaterializedViewInfo[] = [];

    for (const table of tables) {
      try {
        const [metadata] = await table.getMetadata();
        if (metadata.type === 'MATERIALIZED_VIEW') {
          const mvQuery = metadata.materializedView?.query;
          if (!mvQuery) {
            this.logger.warn(`Materialized view ${table.id} has no query definition, skipping`);
            continue;
          }

          materializedViews.push({
            viewId: table.id!,
            query: mvQuery,
            enableRefresh: metadata.materializedView?.enableRefresh,
            refreshIntervalMs: metadata.materializedView?.refreshIntervalMs,
          });
        }
      } catch (error) {
        this.logger.warn(`Error getting metadata for table ${table.id}:`, error);
      }
    }

    return materializedViews;
  }

  /**
   * Recreates a materialized view with the same definition
   */
  async recreateMaterializedView(
    datasetId: string,
    viewId: string,
    query: string,
    enableRefresh?: boolean,
    refreshIntervalMs?: number
  ): Promise<void> {
    const viewRef = `\`${this.bq.projectId}.${datasetId}.${viewId}\``;
    const dataset = this.bq.dataset(datasetId);
    const view = dataset.table(viewId);

    // Delete existing materialized view
    const [exists] = await view.exists();
    if (exists) {
      await view.delete();
      this.logger.debug(`Deleted existing materialized view: ${viewRef}`);
    }

    // Recreate with same definition
    let createQuery = `CREATE MATERIALIZED VIEW ${viewRef} AS\n${query}`;

    // Add refresh options if they were set
    const options: string[] = [];
    if (enableRefresh !== undefined) {
      options.push(`enable_refresh = ${enableRefresh}`);
    }
    if (refreshIntervalMs !== undefined) {
      options.push(`refresh_interval_ms = ${refreshIntervalMs}`);
    }
    if (options.length > 0) {
      createQuery += `\nOPTIONS(${options.join(', ')})`;
    }

    this.logger.debug(`Recreating materialized view with query:\n${createQuery}`);

    const [job] = await this.bq.createQueryJob({
      query: createQuery,
      useLegacySql: false,
    });

    await job.promise();
    this.logger.debug(`Materialized view recreated: ${viewRef}`);
  }

  /**
   * Recreates all materialized views in a dataset that reference restored tables
   */
  async recreateMaterializedViewsInDataset(datasetId: string): Promise<number> {
    try {
      const materializedViews = await this.listMaterializedViews(datasetId);
      
      if (materializedViews.length === 0) {
        this.logger.debug(`No materialized views found in dataset ${datasetId}`);
        return 0;
      }

      this.logger.info(`  - Found ${materializedViews.length} materialized view(s) to recreate in dataset ${datasetId}`);

      let recreatedCount = 0;
      for (const mv of materializedViews) {
        try {
          await this.recreateMaterializedView(
            datasetId,
            mv.viewId,
            mv.query,
            mv.enableRefresh,
            mv.refreshIntervalMs
          );
          this.logger.info(`  - Recreated materialized view: ${mv.viewId} ✓`);
          recreatedCount++;
        } catch (error) {
          this.logger.error(`  - Failed to recreate materialized view ${mv.viewId}: ${error}`);
        }
      }

      return recreatedCount;
    } catch (error) {
      this.logger.warn(`Error recreating materialized views in dataset ${datasetId}: ${error}`);
      return 0;
    }
  }

  /**
   * Restores a snapshot table to a regular table
   */
  async restoreTable(
    sourceBackupDatasetId: string,
    sourceTableId: string,
    targetDatasetId: string,
    targetTableId: string,
    overwrite: boolean
  ): Promise<void> {
    const sourceTableRef = `\`${this.bq.projectId}.${sourceBackupDatasetId}.${sourceTableId}\``;
    const targetTableRef = `\`${this.bq.projectId}.${targetDatasetId}.${targetTableId}\``;

    // Check if target table exists
    const targetDataset = this.bq.dataset(targetDatasetId);
    const targetTable = targetDataset.table(targetTableId);
    const [targetExists] = await targetTable.exists();

    if (targetExists && !overwrite) {
      throw new Error(`Target table ${targetTableRef} already exists. Use --overwrite to replace it.`);
    }

    let restoreQuery: string;
    
    if (overwrite) {
      // Use CREATE OR REPLACE for atomic overwrite
      restoreQuery = `CREATE OR REPLACE TABLE ${targetTableRef}\n`;
    } else {
      // Use CREATE TABLE (will fail if exists, but we already checked above)
      restoreQuery = `CREATE TABLE ${targetTableRef}\n`;
    }
    restoreQuery += `CLONE ${sourceTableRef}`;

    this.logger.debug(`Restoring table with query:\n${restoreQuery}`);

    const [job] = await this.bq.createQueryJob({
      query: restoreQuery,
      useLegacySql: false,
    });

    await job.promise();
    this.logger.debug(`Table restored: ${targetTableRef}`);
  }

  /**
   * Restores all backups for a specific timestamp
   */
  async restoreBackups(options: RestoreOptions): Promise<RestoreResult[]> {
    const results: RestoreResult[] = [];

    if (!options.backupTimestamp) {
      throw new Error('Backup timestamp is required');
    }

    // List all backup datasets for this timestamp
    const backups = await this.listBackupsForTimestamp(options.backupTimestamp);
    
    if (backups.length === 0) {
      throw new Error(`No backup datasets found for timestamp: ${options.backupTimestamp.toISOString()}`);
    }

    this.logger.info(`Found ${backups.length} backup dataset(s) for timestamp ${options.backupTimestamp.toISOString()}`);

    for (const backup of backups) {
      const result: RestoreResult = {
        sourceBackupDatasetId: backup.backupDatasetId,
        targetDatasetId: backup.sourceDatasetId,
        tablesRestored: 0,
        materializedViewsRecreated: 0,
        success: false,
        errors: [],
      };

      try {
        // List tables in backup dataset
        const tableIds = await this.listBackupTables(backup.backupDatasetId);
        this.logger.info(`Restoring from backup: ${backup.backupDatasetId}`);
        this.logger.info(`  - Found ${tableIds.length} table(s) to restore`);
        this.logger.info(`  - Target dataset: ${result.targetDatasetId}`);

        if (tableIds.length === 0) {
          this.logger.warn(`  - No tables to restore in backup ${backup.backupDatasetId}`);
          result.success = true;
          results.push(result);
          continue;
        }

        // Ensure target dataset exists
        const targetDataset = this.bq.dataset(result.targetDatasetId);
        const [targetExists] = await targetDataset.exists();
        
        if (!targetExists) {
          // Get location from backup dataset
          const backupDataset = this.bq.dataset(backup.backupDatasetId);
          const [backupMetadata] = await backupDataset.getMetadata();
          
          await targetDataset.create({
            location: backupMetadata.location || 'US',
            description: `Restored from backup ${backup.backupDatasetId}`,
          });
          this.logger.info(`  - Created target dataset: ${result.targetDatasetId}`);
        }

        // Restore each table
        const restorePromises = tableIds.map(async (tableId) => {
          try {
            await this.restoreTable(
              backup.backupDatasetId,
              tableId,
              result.targetDatasetId,
              tableId, // Same table name
              options.overwrite || false
            );
            this.logger.info(`  - Restored table: ${tableId} ✓`);
            return { success: true, tableId };
          } catch (error) {
            const errorMsg = `Failed to restore table ${tableId}: ${error}`;
            this.logger.error(`  - ${errorMsg}`);
            return { success: false, tableId, error: errorMsg };
          }
        });

        const restoreResults = await Promise.all(restorePromises);
        const successful = restoreResults.filter((r) => r.success).length;
        const failed = restoreResults.filter((r) => !r.success);

        result.tablesRestored = successful;
        
        // Recreate materialized views in the target dataset after tables are restored
        this.logger.info(`  - Recreating materialized views in dataset ${result.targetDatasetId}...`);
        const materializedViewsRecreated = await this.recreateMaterializedViewsInDataset(result.targetDatasetId);
        result.materializedViewsRecreated = materializedViewsRecreated;

        result.success = failed.length === 0;

        if (failed.length > 0) {
          result.errors = failed.map((f) => f.error || 'Unknown error');
          this.logger.warn(
            `  - Completed with ${failed.length} error(s) out of ${tableIds.length} table(s)`
          );
        } else {
          this.logger.info(
            `  - Successfully restored ${successful} table(s) to ${result.targetDatasetId}`
          );
        }

        if (materializedViewsRecreated > 0) {
          this.logger.info(
            `  - Recreated ${materializedViewsRecreated} materialized view(s) in ${result.targetDatasetId}`
          );
        }
      } catch (error) {
        const errorMsg = `Error restoring from backup ${backup.backupDatasetId}: ${error}`;
        this.logger.error(errorMsg);
        result.errors = [errorMsg];
        result.success = false;
      }

      results.push(result);
    }

    return results;
  }
}

