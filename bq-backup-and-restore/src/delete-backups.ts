import { BigQuery } from '@google-cloud/bigquery';
import winston from 'winston';
import * as readline from 'readline';
import { BackupInfo } from './list-backups';

export interface BackupGroup {
  timestamp: Date;
  timestampStr: string;
  backups: BackupInfo[];
}

export class DeleteBackupsService {
  private bq: BigQuery;
  private logger: winston.Logger;

  constructor(projectId: string, logger: winston.Logger) {
    this.bq = new BigQuery({ projectId });
    this.logger = logger;
  }

  /**
   * Groups backups by timestamp
   */
  groupBackupsByTimestamp(backups: BackupInfo[]): BackupGroup[] {
    const groups = new Map<string, BackupGroup>();

    for (const backup of backups) {
      // Use ISO string as key for grouping
      const timestampKey = backup.timestamp.toISOString();
      
      if (!groups.has(timestampKey)) {
        groups.set(timestampKey, {
          timestamp: backup.timestamp,
          timestampStr: backup.timestamp.toISOString(),
          backups: [],
        });
      }
      
      groups.get(timestampKey)!.backups.push(backup);
    }

    // Sort by timestamp (newest first)
    return Array.from(groups.values()).sort(
      (a, b) => b.timestamp.getTime() - a.timestamp.getTime()
    );
  }

  /**
   * Displays backup groups for user selection
   */
  displayBackupGroups(groups: BackupGroup[]): void {
    if (groups.length === 0) {
      this.logger.info('No backup datasets found in this project.');
      return;
    }

    this.logger.info(`Found ${groups.length} backup timestamp(s):\n`);

    groups.forEach((group, index) => {
      this.logger.info(`[${index + 1}] ${group.timestampStr}`);
      this.logger.info(`    Datasets (${group.backups.length}):`);
      group.backups.forEach((backup) => {
        this.logger.info(`      - ${backup.backupDatasetId} (source: ${backup.sourceDatasetId})`);
      });
      this.logger.info('');
    });
  }

  /**
   * Prompts user to select a backup group by index
   */
  async promptForSelection(maxIndex: number): Promise<number> {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });

    return new Promise((resolve) => {
      rl.question(`Select backup timestamp to delete (1-${maxIndex}, or 'q' to quit): `, (answer) => {
        rl.close();
        
        if (answer.toLowerCase() === 'q' || answer.toLowerCase() === 'quit') {
          this.logger.info('Operation cancelled.');
          process.exit(0);
        }

        const index = parseInt(answer, 10);
        if (isNaN(index) || index < 1 || index > maxIndex) {
          this.logger.error(`Invalid selection. Please enter a number between 1 and ${maxIndex}.`);
          process.exit(1);
        }

        resolve(index - 1); // Convert to 0-based index
      });
    });
  }

  /**
   * Deletes a backup dataset
   */
  async deleteBackupDataset(backupDatasetId: string): Promise<void> {
    const dataset = this.bq.dataset(backupDatasetId);
    
    const [exists] = await dataset.exists();
    if (!exists) {
      this.logger.warn(`Backup dataset ${backupDatasetId} does not exist, skipping.`);
      return;
    }

    await dataset.delete({ force: true });
    this.logger.info(`Deleted backup dataset: ${backupDatasetId}`);
  }

  /**
   * Deletes all backups for a specific timestamp
   */
  async deleteBackupsForTimestamp(backups: BackupInfo[]): Promise<void> {
    this.logger.info(`\nDeleting ${backups.length} backup dataset(s)...`);

    let successCount = 0;
    let errorCount = 0;

    for (const backup of backups) {
      try {
        await this.deleteBackupDataset(backup.backupDatasetId);
        successCount++;
      } catch (error) {
        errorCount++;
        this.logger.error(`Failed to delete ${backup.backupDatasetId}: ${error}`);
      }
    }

    this.logger.info(`\nDeletion complete: ${successCount} succeeded, ${errorCount} failed`);
    
    if (errorCount > 0) {
      process.exit(1);
    }
  }
}

