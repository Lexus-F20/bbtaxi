// Конфигурация подключения к базе данных PostgreSQL
const { Pool } = require('pg');
require('dotenv').config();

// Предпочитаем DATABASE_PUBLIC_URL (публичный proxy, всегда SSL)
// Если нет — используем DATABASE_URL (внутренний, без SSL на Railway)
const publicUrl  = process.env.DATABASE_PUBLIC_URL;
const privateUrl = process.env.DATABASE_URL;
const dbUrl = publicUrl || privateUrl;

// Railway требует SSL для всех подключений (и публичных, и приватных)
const ssl = dbUrl ? { rejectUnauthorized: false } : false;

console.log('DB host:', dbUrl ? dbUrl.replace(/:([^:@]+)@/, ':***@').split('@')[1] : 'PG vars');
console.log('DB ssl:', JSON.stringify(ssl));

const poolConfig = dbUrl
  ? { connectionString: dbUrl, ssl, max: 10, idleTimeoutMillis: 10000, connectionTimeoutMillis: 10000, keepAlive: true }
  : {
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
