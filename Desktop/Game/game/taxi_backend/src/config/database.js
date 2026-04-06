// Конфигурация подключения к базе данных PostgreSQL
const { Pool } = require('pg');
require('dotenv').config();

const privateUrl = process.env.DATABASE_URL;
const publicUrl  = process.env.DATABASE_PUBLIC_URL;
const dbUrl      = privateUrl || publicUrl;

// Логируем какой URL используется (без пароля)
if (dbUrl) {
  const safe = dbUrl.replace(/:([^:@]+)@/, ':***@');
  const isInternal = dbUrl.includes('.railway.internal');
  console.log(`DB URL: ${safe}`);
  console.log(`DB internal: ${isInternal}`);
} else {
  console.log('DB URL не найден — используем PG* переменные');
}

// Определяем SSL:
//   .railway.internal — приватная сеть, SSL не нужен
//   всё остальное    — SSL с отключённой проверкой сертификата
function getSsl(url) {
  if (!url) return false;
  if (url.includes('.railway.internal')) return false;
  return { rejectUnauthorized: false };
}

const poolConfig = dbUrl
  ? {
      connectionString: dbUrl,
      ssl: getSsl(dbUrl),
      max: 20,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    }
  : {
      host:     process.env.PGHOST     || process.env.DB_HOST     || 'localhost',
      port:     parseInt(process.env.PGPORT     || process.env.DB_PORT)  || 5432,
      database: process.env.PGDATABASE || process.env.DB_NAME     || 'taxi_db',
      user:     process.env.PGUSER     || process.env.DB_USER     || 'postgres',
      password: process.env.PGPASSWORD || process.env.DB_PASSWORD || '',
      ssl: getSsl(process.env.PGHOST),
      max: 20,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    };

console.log('DB ssl config:', JSON.stringify(poolConfig.ssl));

const pool = new Pool(poolConfig);

pool.connect((err, client, release) => {
  if (err) {
    console.error('Ошибка подключения к PostgreSQL:', err.message);
    return;
  }
  console.log('Успешное подключение к PostgreSQL');
  release();
});

module.exports = pool;
