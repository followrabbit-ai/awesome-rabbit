import { BigQuery } from '@google-cloud/bigquery';
import winston from 'winston';
import { BACKUP_DATASET_PREFIX } from './constants';

export interface BackupInfo {
  backupDatasetId: string;
  sourceDatasetId: string;
  timestamp: Date;
}

export class ListBackupsService {
  private bq: BigQuery;
  private logger: winston.Logger;

  constructor(projectId: string, logger: winston.Logger) {
    this.bq = new BigQuery({ projectId });
    this.logger = logger;
  }

  /**
   * Lists all backup datasets in the project
   */
  async listBackups(): Promise<BackupInfo[]> {
    const [allDatasets] = await this.bq.getDatasets();
    const backupInfos: BackupInfo[] = [];

    for (const dataset of allDatasets) {
      this.logger.debug(`Processing dataset: ${dataset.id}`);
      const datasetId = dataset.id!;
      
      // Check if dataset name matches backup pattern: zzz_backup_yyyyMMdd_hhmmss_{{source_dataset}}
      if (!datasetId.startsWith(BACKUP_DATASET_PREFIX)) {
        continue;
      }

      try {
        // Extract source dataset name from backup dataset name
        // Pattern: zzz_backup_yyyyMMdd_hhmmss_{{source_dataset}}
        const parts = datasetId.split('_');
        if (parts.length < 5) {
          continue; // Invalid backup dataset name format (need at least: zzz, backup, yyyyMMdd, hhmmss, source)
        }

        // Reconstruct source dataset name (everything after timestamp)
        // parts[0] = "zzz", parts[1] = "backup", parts[2] = "yyyyMMdd", parts[3] = "hhmmss"
        const timestampPart = `${parts[2]}_${parts[3]}`; // yyyyMMdd_hhmmss
        const sourceDatasetId = parts.slice(4).join('_');

        // Parse timestamp from backup dataset name
        // Format: yyyyMMdd_hhmmss
        try {
          const [datePart, timePart] = timestampPart.split('_');
          if (!datePart || !timePart || datePart.length !== 8 || timePart.length !== 6) {
            this.logger.debug(`Invalid timestamp format in dataset name: ${datasetId}`);
            continue;
          }

          const year = parseInt(datePart.substring(0, 4), 10);
          const month = parseInt(datePart.substring(4, 6), 10) - 1; // Month is 0-indexed
          const day = parseInt(datePart.substring(6, 8), 10);
          const hours = parseInt(timePart.substring(0, 2), 10);
          const minutes = parseInt(timePart.substring(2, 4), 10);
          const seconds = parseInt(timePart.substring(4, 6), 10);

          const timestamp = new Date(Date.UTC(year, month, day, hours, minutes, seconds));
          
          if (isNaN(timestamp.getTime())) {
            this.logger.debug(`Invalid timestamp parsed from dataset name: ${datasetId}`);
            continue;
          }

          backupInfos.push({
            backupDatasetId: datasetId,
            sourceDatasetId,
            timestamp,
          });
        } catch (parseError) {
          // If timestamp parsing failed, skip this dataset
          this.logger.debug(`Error parsing timestamp from dataset ${datasetId}:`, parseError);
          continue;
        }
      } catch (error) {
        this.logger.warn(`Error processing backup dataset ${datasetId}:`, error);
      }
    }

    // Sort by timestamp (newest first)
    backupInfos.sort((a, b) => b.timestamp.getTime() - a.timestamp.getTime());

    return backupInfos;
  }

  /**
   * Formats and displays backup information
   */
  displayBackups(backups: BackupInfo[]): void {
    if (backups.length === 0) {
      this.logger.info('No backup datasets found in this project.');
      return;
    }

    this.logger.info(`Found ${backups.length} backup dataset(s):\n`);
    
    for (const backup of backups) {
      this.logger.info(`Backup Dataset: ${backup.backupDatasetId}`);
      this.logger.info(`  Source Dataset: ${backup.sourceDatasetId}`);
      this.logger.info(`  Backup Timestamp: ${backup.timestamp.toISOString()}`);
      this.logger.info('');
    }
  }
}

