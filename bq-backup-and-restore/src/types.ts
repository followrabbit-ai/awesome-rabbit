export interface BackupOptions {
  projectId: string;
  datasets?: string[];
  timestamp?: Date;
  expirationDays?: number;
}

export interface BackupResult {
  backupDatasetId: string;
  sourceDatasetId: string;
  timestamp: Date;
  tablesBackedUp: number;
  success: boolean;
  errors?: string[];
}

export interface TableInfo {
  tableId: string;
  type: string;
  location?: string;
}

export interface DatasetInfo {
  datasetId: string;
  location?: string;
  tables: TableInfo[];
}

