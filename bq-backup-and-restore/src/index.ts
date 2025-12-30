#!/usr/bin/env node

import { Command } from 'commander';
import * as readline from 'readline';
import { BackupService } from './backup';
import { ListBackupsService } from './list-backups';
import { DeleteBackupsService } from './delete-backups';
import { RestoreService } from './restore';
import { createLogger, parseLogLevel, LogLevel } from './logger';
import { parseTimestamp } from './utils';

const program = new Command();

program
  .name('bq-backup-and-restore')
  .description('A command-line tool for creating and restoring backups of BigQuery datasets')
  .version('0.1.0');

// Backup command
program
  .command('backup')
  .description('Create backups of BigQuery datasets')
  .requiredOption('--project-id <projectId>', 'GCP project ID containing the datasets')
  .option('--datasets <datasets>', 'Comma-separated list of dataset IDs. If omitted, backs up all datasets')
  .option('--timestamp <timestamp>', 'ISO 8601 timestamp for point-in-time backup (must be within last 7 days)')
  .option('--expiration-days <days>', 'Number of days to retain snapshots. Default: 90 (3 months). Set to 0 for indefinite retention', '90')
  .option('--log-level <level>', 'Logging level: debug, info, warn, error. Default: info', 'info')
  .action(async (options: { projectId: string; datasets?: string; timestamp?: string; expirationDays?: string; logLevel: string }) => {
    let logLevel: LogLevel;
    try {
      logLevel = parseLogLevel(options.logLevel);
    } catch (error) {
      console.error(`Invalid log level: ${error}`);
      process.exit(1);
    }
    
    const logger = createLogger(logLevel);
    
    try {
      // Parse datasets
      const datasets = options.datasets
        ? options.datasets.split(',').map((d: string) => d.trim())
        : undefined;

      // Parse timestamp if provided
      let timestamp: Date | undefined;
      if (options.timestamp) {
        try {
          timestamp = parseTimestamp(options.timestamp);
        } catch (error) {
          logger.error(`Invalid timestamp format: ${error}`);
          process.exit(1);
        }
      }

      // Parse expiration days
      const expirationDays = options.expirationDays
        ? parseInt(options.expirationDays, 10)
        : undefined;

      if (expirationDays !== undefined && expirationDays < 0) {
        logger.error('expiration-days must be >= 0');
        process.exit(1);
      }

      // Create backup service
      const backupService = new BackupService(options.projectId, logger);

      // Perform backup
      logger.info('Starting backup operation...');
      const results = await backupService.backupDataset({
        projectId: options.projectId,
        datasets,
        timestamp,
        expirationDays,
      });

      // Display results
      logger.info('\nBackup Summary:');
      let totalSuccess = 0;
      let totalFailed = 0;
      let totalTables = 0;

      for (const result of results) {
        if (result.success) {
          totalSuccess++;
          logger.info(`✓ ${result.sourceDatasetId} -> ${result.backupDatasetId} (${result.tablesBackedUp} tables)`);
        } else {
          totalFailed++;
          logger.error(`✗ ${result.sourceDatasetId} -> ${result.backupDatasetId} (${result.tablesBackedUp} tables)`);
          if (result.errors && result.errors.length > 0) {
            for (const error of result.errors) {
              logger.error(`  Error: ${error}`);
            }
          }
        }
        totalTables += result.tablesBackedUp;
      }

      logger.info(`\nTotal: ${results.length} dataset(s), ${totalTables} table(s) backed up`);
      if (totalFailed > 0) {
        logger.warn(`${totalFailed} dataset(s) had errors`);
        process.exit(1);
      } else {
        logger.info('All backups completed successfully!');
      }
    } catch (error) {
      logger.error('Backup operation failed:', error);
      process.exit(1);
    }
  });

// List backups command
program
  .command('list-backups')
  .description('List all backup datasets in a project')
  .requiredOption('--project-id <projectId>', 'GCP project ID')
  .option('--log-level <level>', 'Logging level: debug, info, warn, error. Default: info', 'info')
  .action(async (options: { projectId: string; logLevel: string }) => {
    let logLevel: LogLevel;
    try {
      logLevel = parseLogLevel(options.logLevel);
    } catch (error) {
      console.error(`Invalid log level: ${error}`);
      process.exit(1);
    }
    
    const logger = createLogger(logLevel);

    try {
      const listService = new ListBackupsService(options.projectId, logger);
      logger.info(`Listing backups in project: ${options.projectId}...\n`);
      
      const backups = await listService.listBackups();
      listService.displayBackups(backups);
    } catch (error) {
      logger.error('Failed to list backups:', error);
      process.exit(1);
    }
  });

// Delete backups command
program
  .command('delete-backups')
  .description('Delete backups by timestamp - lists backups grouped by timestamp and prompts for selection')
  .requiredOption('--project-id <projectId>', 'GCP project ID')
  .option('--log-level <level>', 'Logging level: debug, info, warn, error. Default: info', 'info')
  .action(async (options: { projectId: string; logLevel: string }) => {
    let logLevel: LogLevel;
    try {
      logLevel = parseLogLevel(options.logLevel);
    } catch (error) {
      console.error(`Invalid log level: ${error}`);
      process.exit(1);
    }
    
    const logger = createLogger(logLevel);

    try {
      const listService = new ListBackupsService(options.projectId, logger);
      const deleteService = new DeleteBackupsService(options.projectId, logger);
      
      logger.info(`Listing backups in project: ${options.projectId}...\n`);
      
      // List all backups
      const backups = await listService.listBackups();
      
      if (backups.length === 0) {
        logger.info('No backup datasets found in this project.');
        process.exit(0);
      }

      // Group backups by timestamp
      const groups = deleteService.groupBackupsByTimestamp(backups);
      
      // Display grouped backups
      deleteService.displayBackupGroups(groups);
      
      // Prompt for selection
      const selectedIndex = await deleteService.promptForSelection(groups.length);
      const selectedGroup = groups[selectedIndex];
      
      logger.info(`\nSelected backup timestamp: ${selectedGroup.timestampStr}`);
      logger.info(`This will delete ${selectedGroup.backups.length} backup dataset(s).`);
      
      // Confirm deletion
      const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
      });

      const confirm = await new Promise<string>((resolve) => {
        rl.question('Are you sure you want to delete these backups? (yes/no): ', (answer: string) => {
          rl.close();
          resolve(answer.toLowerCase());
        });
      });

      if (confirm !== 'yes' && confirm !== 'y') {
        logger.info('Deletion cancelled.');
        process.exit(0);
      }

      // Delete backups
      await deleteService.deleteBackupsForTimestamp(selectedGroup.backups);
      
      logger.info('All selected backups have been deleted successfully.');
    } catch (error) {
      logger.error('Failed to delete backups:', error);
      process.exit(1);
    }
  });

// Restore command
program
  .command('restore')
  .description('Restore datasets from backups')
  .requiredOption('--project-id <projectId>', 'GCP project ID')
  .option('--backup-timestamp <timestamp>', 'ISO 8601 timestamp of the backup to restore. If omitted, lists available backups for selection')
  .option('--overwrite', 'Overwrite existing tables if they exist', false)
  .option('--log-level <level>', 'Logging level: debug, info, warn, error. Default: info', 'info')
  .action(async (options: { projectId: string; backupTimestamp?: string; targetDataset?: string; overwrite: boolean; logLevel: string }) => {
    let logLevel: LogLevel;
    try {
      logLevel = parseLogLevel(options.logLevel);
    } catch (error) {
      console.error(`Invalid log level: ${error}`);
      process.exit(1);
    }
    
    const logger = createLogger(logLevel);

    try {
      const listService = new ListBackupsService(options.projectId, logger);
      const restoreService = new RestoreService(options.projectId, logger);
      const deleteService = new DeleteBackupsService(options.projectId, logger);
      
      let backupTimestamp: Date | undefined;

      if (options.backupTimestamp) {
        // Parse provided timestamp
        try {
          backupTimestamp = parseTimestamp(options.backupTimestamp);
        } catch (error) {
          logger.error(`Invalid timestamp format: ${error}`);
          process.exit(1);
        }
      } else {
        // List backups and let user choose
        logger.info(`Listing backups in project: ${options.projectId}...\n`);
        
        const backups = await listService.listBackups();
        
        if (backups.length === 0) {
          logger.info('No backup datasets found in this project.');
          process.exit(0);
        }

        // Group backups by timestamp
        const groups = deleteService.groupBackupsByTimestamp(backups);
        
        // Display grouped backups
        deleteService.displayBackupGroups(groups);
        
        // Prompt for selection
        const selectedIndex = await deleteService.promptForSelection(groups.length);
        const selectedGroup = groups[selectedIndex];
        
        backupTimestamp = selectedGroup.timestamp;
        logger.info(`\nSelected backup timestamp: ${selectedGroup.timestampStr}`);
      }

      // Perform restore
      logger.info('Starting restore operation...');
      const results = await restoreService.restoreBackups({
        projectId: options.projectId,
        backupTimestamp,
        overwrite: options.overwrite,
      });

      // Display results
      logger.info('\nRestore Summary:');
      let totalSuccess = 0;
      let totalFailed = 0;
      let totalTables = 0;

      for (const result of results) {
        if (result.success) {
          totalSuccess++;
          logger.info(`✓ ${result.sourceBackupDatasetId} -> ${result.targetDatasetId} (${result.tablesRestored} tables, ${result.materializedViewsRecreated} materialized views)`);
        } else {
          totalFailed++;
          logger.error(`✗ ${result.sourceBackupDatasetId} -> ${result.targetDatasetId} (${result.tablesRestored} tables, ${result.materializedViewsRecreated} materialized views)`);
          if (result.errors && result.errors.length > 0) {
            for (const error of result.errors) {
              logger.error(`  Error: ${error}`);
            }
          }
        }
        totalTables += result.tablesRestored;
      }

      logger.info(`\nTotal: ${results.length} backup dataset(s), ${totalTables} table(s) restored`);
      if (totalFailed > 0) {
        logger.warn(`${totalFailed} backup dataset(s) had errors`);
        process.exit(1);
      } else {
        logger.info('All restores completed successfully!');
      }
    } catch (error) {
      logger.error('Restore operation failed:', error);
      process.exit(1);
    }
  });

// Parse command line arguments
program.parse();

