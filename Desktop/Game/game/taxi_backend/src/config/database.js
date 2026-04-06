// Конфигурация подключения к базе данных PostgreSQL
const { Pool } = require('pg');
require('dotenv').config();

// Берём URL, обрезаем пробелы/переносы строк которые могут попасть через env
const rawUrl = (process.env.DATABASE_PUBLIC_URL || process.env.DATABASE_URL || '').trim();

let poolConfig;

if (rawUrl) {
  poolConfig = {
    connectionString: rawUrl,
    ssl: false,
    max: 10,
    idleTimeoutMillis: 10000,
    connectionTimeoutMillis: 15000,
    keepAlive: true,
  };
  const hostMatch = rawUrl.match(/@([^/]+)/);
  console.log('DB host:', hostMatch ? hostMatch[1] : 'unknown');
  console.log('DB ssl: disabled');
}

if (!poolConfig) {
  poolConfig = {
    host:     process.env.PGHOST     || process.env.DB_HOST     || 'localhost',
    port:     parseInt(process.env.PGPORT  || process.env.DB_PORT)  || 5432,
    database: process.env.PGDATABASE || process.env.DB_NAME     || 'taxi_db',
    user:     process.env.PGUSER     || process.env.DB_USER     || 'postgres',
    password: process.env.PGPASSWORD || process.env.DB_PASSWORD || '',
    ssl: false,
    max: 20,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 5000,
  };
  console.log('DB: using PGHOST/PGPORT vars, ssl: disabled');
}

const pool = new Pool(poolConfig);

const testConnection = (retries = 5, delay = 3000) => {
  pool.connect((err, client, release) => {
    if (err) {
      if (retries > 0) {
        console.warn(`Ошибка подключения к PostgreSQL (попыток осталось: ${retries}): ${err.message}`);
        setTimeout(() => testConnection(retries - 1, delay), delay);
      } else {
        console.error('Не удалось подключиться к PostgreSQL после всех попыток:', err.message);
      }
      return;
    }
    console.log('Успешное подключение к PostgreSQL');
    release();
  });
};
testConnection();

module.exports = pool;
