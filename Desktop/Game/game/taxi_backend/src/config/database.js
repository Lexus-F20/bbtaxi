// Конфигурация подключения к базе данных PostgreSQL
const { Pool } = require('pg');
require('dotenv').config();

// Поддержка как DATABASE_URL (Railway/Render), так и отдельных переменных
const poolConfig = process.env.DATABASE_URL
  ? {
      connectionString: process.env.DATABASE_URL,
      ssl: { rejectUnauthorized: false },
      max: 20,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    }
  : {
      host: process.env.DB_HOST || 'localhost',
      port: parseInt(process.env.DB_PORT) || 5432,
      database: process.env.DB_NAME || 'taxi_db',
      user: process.env.DB_USER || 'postgres',
      password: process.env.DB_PASSWORD || '',
      max: 20,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 2000,
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
