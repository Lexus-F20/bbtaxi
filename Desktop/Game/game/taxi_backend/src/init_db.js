// Автоматическая инициализация базы данных при первом запуске
const pool = require('./config/database');

async function initDatabase() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS users (
        id SERIAL PRIMARY KEY,
        phone VARCHAR(20) UNIQUE NOT NULL,
        name VARCHAR(100) NOT NULL,
        password_hash TEXT NOT NULL,
        role VARCHAR(20) DEFAULT 'driver',
        is_active BOOLEAN DEFAULT true,
        fcm_token TEXT,
        rating INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS markers (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES users(id),
        accepted_by INTEGER REFERENCES users(id),
        latitude DOUBLE PRECISION NOT NULL,
        longitude DOUBLE PRECISION NOT NULL,
        title VARCHAR(255),
        description TEXT,
        color VARCHAR(20) DEFAULT 'orange',
        status VARCHAR(20) DEFAULT 'pending',
        reject_reason TEXT,
        report TEXT,
        done_at TIMESTAMP,
        media_urls JSONB DEFAULT '[]',
        created_at TIMESTAMP DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS marker_history (
        id SERIAL PRIMARY KEY,
        marker_id INTEGER REFERENCES markers(id),
        user_id INTEGER REFERENCES users(id),
        action VARCHAR(50) NOT NULL,
        note TEXT,
        created_at TIMESTAMP DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS notifications (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES users(id),
        title VARCHAR(255),
        body TEXT,
        is_read BOOLEAN DEFAULT false,
        created_at TIMESTAMP DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS messages (
        id SERIAL PRIMARY KEY,
        sender_id INTEGER REFERENCES users(id),
        receiver_id INTEGER REFERENCES users(id),
        text TEXT NOT NULL,
        media_url TEXT,
        is_read BOOLEAN DEFAULT false,
        created_at TIMESTAMP DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS orders (
        id SERIAL PRIMARY KEY,
        passenger_id INTEGER REFERENCES users(id),
        driver_id INTEGER REFERENCES users(id),
        marker_id INTEGER REFERENCES markers(id),
        status VARCHAR(20) DEFAULT 'pending',
        reject_reason TEXT,
        pickup_lat DOUBLE PRECISION,
        pickup_lng DOUBLE PRECISION,
        dropoff_lat DOUBLE PRECISION,
        dropoff_lng DOUBLE PRECISION,
        price DECIMAL(10,2),
        created_at TIMESTAMP DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS rating_history (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES users(id),
        changed_by INTEGER REFERENCES users(id),
        delta INTEGER NOT NULL,
        reason TEXT,
        created_at TIMESTAMP DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS routes (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
        title VARCHAR(255),
        points JSONB NOT NULL,
        color VARCHAR(20) DEFAULT 'blue',
        created_at TIMESTAMP DEFAULT NOW()
      );
    `);

    // Добавить новые колонки если их нет (миграция для существующих БД)
    await pool.query(`
      ALTER TABLE markers ADD COLUMN IF NOT EXISTS media_urls JSONB DEFAULT '[]';
      ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_url TEXT;
      ALTER TABLE users ADD COLUMN IF NOT EXISTS fcm_token TEXT;
      ALTER TABLE users ADD COLUMN IF NOT EXISTS rating INTEGER DEFAULT 0;
    `);

    // Создать администратора по умолчанию если нет пользователей
    const count = await pool.query('SELECT COUNT(*) FROM users');
    if (parseInt(count.rows[0].count) === 0) {
      // Пароль: admin123
      await pool.query(`
        INSERT INTO users (phone, name, password_hash, role)
        VALUES ('+70000000000', 'Администратор', '$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy', 'admin')
        ON CONFLICT DO NOTHING
      `);
      // Пароль: admin
      await pool.query(`
        INSERT INTO users (phone, name, password_hash, role)
        VALUES ('admin', 'Администратор', '$2a$10$s5dIVrEu41L//163RXsIvO6eICQpV0zfHhR5rmcSNU4OVz6JHoCVm', 'admin')
        ON CONFLICT DO NOTHING
      `);
      console.log('Создан администратор по умолчанию (телефон: admin, пароль: admin)');
    }

    console.log('База данных инициализирована');
  } catch (err) {
    console.error('Ошибка инициализации БД:', err.message);
  }
}

module.exports = initDatabase;
