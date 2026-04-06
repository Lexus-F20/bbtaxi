// Конфигурация подключения к базе данных PostgreSQL
const { Pool } = require('pg');
require('dotenv').config();

// Railway даёт два URL:
//   DATABASE_URL        — приватный (.railway.internal), SSL НЕ нужен
//   DATABASE_PUBLIC_URL — публичный (*.railway.app),     SSL нужен
const privateUrl = process.env.DATABASE_URL;
const publicUrl  = process.env.DATABASE_PUBLIC_URL;

// Выбираем URL и настройку SSL
let dbUrl, sslConfig;
if (privateUrl && privateUrl.includes('.railway.internal')) {
  // Приватная сеть Railway — без SSL
  dbUrl = privateUrl;
  sslConfig = false;
} else if (privateUrl) {
  // DATABASE_URL есть, но не internal — SSL с мягкой проверкой
  dbUrl = privateUrl;
  sslConfig = { rejectUnauthorized: false };
} else if (publicUrl) {
  // Публичный URL — SSL обязателен
  dbUrl = publicUrl;
  sslConfig = { rejectUnauthorized: false };
} else {
  dbUrl = null;
  sslConfig = false;
}

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
      ssl: false,
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
