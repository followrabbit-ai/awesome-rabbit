import winston from 'winston';
import { BACKUP_DATASET_PREFIX } from './constants';

/**
 * Formats a date to the backup dataset naming pattern: yyyyMMdd_hhmmss
 */
export function formatBackupTimestamp(date: Date): string {
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, '0');
  const day = String(date.getUTCDate()).padStart(2, '0');
  const hours = String(date.getUTCHours()).padStart(2, '0');
  const minutes = String(date.getUTCMinutes()).padStart(2, '0');
  const seconds = String(date.getUTCSeconds()).padStart(2, '0');

  return `${year}${month}${day}_${hours}${minutes}${seconds}`;
}

/**
 * Generates backup dataset name: zzz_backup_yyyyMMdd_hhmmss_{{source_dataset}}
 */
export function generateBackupDatasetName(sourceDatasetId: string, timestamp: Date): string {
  const timestampStr = formatBackupTimestamp(timestamp);
  return `${BACKUP_DATASET_PREFIX}${timestampStr}_${sourceDatasetId}`;
}

/**
 * Validates that a timestamp is within the last 7 days (BigQuery time travel limit)
 */
export function validateTimeTravelTimestamp(timestamp: Date, logger: winston.Logger): boolean {
  const now = new Date();
  const sevenDaysAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);

  if (timestamp < sevenDaysAgo) {
    logger.error(
      `Timestamp ${timestamp.toISOString()} is outside the 7-day time travel retention period. ` +
        `Earliest allowed: ${sevenDaysAgo.toISOString()}`
    );
    return false;
  }

  if (timestamp > now) {
    logger.error(`Timestamp ${timestamp.toISOString()} is in the future.`);
    return false;
  }

  return true;
}

/**
 * Calculates expiration timestamp from backup timestamp and expiration days
 */
export function calculateExpirationTimestamp(
  backupTimestamp: Date,
  expirationDays: number | undefined
): Date | undefined {
  if (expirationDays === undefined || expirationDays === 0) {
    return undefined; // Indefinite retention
  }

  const expiration = new Date(backupTimestamp);
  expiration.setUTCDate(expiration.getUTCDate() + expirationDays);
  return expiration;
}

/**
 * Parses ISO 8601 timestamp string to Date
 */
export function parseTimestamp(timestampStr: string): Date {
  const date = new Date(timestampStr);
  if (isNaN(date.getTime())) {
    throw new Error(`Invalid timestamp format: ${timestampStr}. Expected ISO 8601 format.`);
  }
  return date;
}

