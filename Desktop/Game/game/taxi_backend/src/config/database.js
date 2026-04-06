// Конфигурация подключения к базе данных PostgreSQL
const { Pool } = require('pg');
require('dotenv').config();

// Поддержка DATABASE_URL, DATABASE_PUBLIC_URL, PGDATABASE и отдельных переменных
const dbUrl =
  process.env.DATABASE_URL ||
  process.env.DATABASE_PUBLIC_URL ||
  process.env.RAILWAY_DATABASE_URL;

// SSL нужен всегда на Railway (для любого способа подключения)
const sslConfig = { rejectUnauthorized: false };

const poolConfig = dbUrl
  ? {
      connectionString: dbUrl,
      ssl: sslConfig,
      max: 20,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    }
  : {
      host: process.env.PGHOST || process.env.DB_HOST || 'localhost',
      port: parseInt(process.env.PGPORT || process.env.DB_PORT) || 5432,
      database: process.env.PGDATABASE || process.env.DB_NAME || 'taxi_db',
      user: process.env.PGUSER || process.env.DB_USER || 'postgres',
      password: process.env.PGPASSWORD || process.env.DB_PASSWORD || '',
      ssl: process.env.PGHOST ? sslConfig : false,
      max: 20,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    };

const pool = new Pool(poolConfig);

// Проверяем подключение при старте
pool.connect((err, client, release) => {
  if (err) {
    console.error('Ошибка подключения к PostgreSQL:', err.message);
    return;
  }
  console.log('Успешное подключение к PostgreSQL');
  release();
});

module.exports = pool;
