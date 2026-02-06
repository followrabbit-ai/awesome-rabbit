import winston from 'winston';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

/**
 * Creates a Winston logger instance with the specified log level
 */
export function createLogger(level: LogLevel = 'info'): winston.Logger {
  return winston.createLogger({
    level,
    format: winston.format.combine(
      winston.format.timestamp(),
      winston.format.errors({ stack: true }),
      winston.format.printf((info: winston.Logform.TransformableInfo) => {
        const { timestamp, level, message, ...meta } = info;
        const metaStr = Object.keys(meta).length ? JSON.stringify(meta) : '';
        return `${timestamp} [${level.toUpperCase()}] ${message} ${metaStr}`.trim();
      })
    ),
    transports: [
      new winston.transports.Console({
        format: winston.format.combine(
          winston.format.colorize(),
          winston.format.printf((info: winston.Logform.TransformableInfo) => {
            const { timestamp, level, message, ...meta } = info;
            const metaStr = Object.keys(meta).length ? JSON.stringify(meta) : '';
            // For console, use simpler format without timestamp for better readability
            return `[${level}] ${message} ${metaStr}`.trim();
          })
        ),
      }),
    ],
  });
}

/**
 * Parse and validate log level string
 */
export function parseLogLevel(levelStr: string): LogLevel {
  const normalized = levelStr.toLowerCase().trim();
  const validLevels: LogLevel[] = ['debug', 'info', 'warn', 'error'];
  
  if (validLevels.includes(normalized as LogLevel)) {
    return normalized as LogLevel;
  }
  
  throw new Error(
    `Invalid log level: ${levelStr}. Must be one of: ${validLevels.join(', ')}`
  );
}
