// Автоматическая инициализация базы данных при первом запуске
const pool = require('./config/database');

async function initDatabase() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS users (
        id SERIAL PRIMARY KEY,
        login VARCHAR(100) UNIQUE NOT NULL,
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
        edited_at TIMESTAMP,
        is_deleted BOOLEAN DEFAULT false,
        forwarded_from_id INTEGER REFERENCES messages(id),
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

      CREATE TABLE IF NOT EXISTS conversations (
        id SERIAL PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        created_by INTEGER REFERENCES users(id),
        created_at TIMESTAMP DEFAULT NOW()
      );

      CREATE TABLE IF NOT EXISTS conversation_members (
        id SERIAL PRIMARY KEY,
        conversation_id INTEGER REFERENCES conversations(id) ON DELETE CASCADE,
        user_id INTEGER REFERENCES users(id),
        role VARCHAR(20) DEFAULT 'member',
        joined_at TIMESTAMP DEFAULT NOW(),
        UNIQUE(conversation_id, user_id)
      );
    `);

    // Добавить новые колонки если их нет (миграция для существующих БД)
    await pool.query(`
      ALTER TABLE markers ADD COLUMN IF NOT EXISTS media_urls JSONB DEFAULT '[]';
      ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_url TEXT;
      ALTER TABLE messages ADD COLUMN IF NOT EXISTS edited_at TIMESTAMP;
      ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT false;
      ALTER TABLE messages ADD COLUMN IF NOT EXISTS forwarded_from_id INTEGER REFERENCES messages(id);
      ALTER TABLE users ADD COLUMN IF NOT EXISTS fcm_token TEXT;
      ALTER TABLE users ADD COLUMN IF NOT EXISTS rating INTEGER DEFAULT 0;
      ALTER TABLE messages ADD COLUMN IF NOT EXISTS conversation_id INTEGER REFERENCES conversations(id);
      ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT;
      ALTER TABLE conversations ADD COLUMN IF NOT EXISTS avatar_url TEXT;
      ALTER TABLE markers ADD COLUMN IF NOT EXISTS confirmed_at TIMESTAMP;
      ALTER TABLE messages ADD COLUMN IF NOT EXISTS attached_marker_id INTEGER REFERENCES markers(id);
    `);

    // Создать администратора по умолчанию если нет пользователей
    const count = await pool.query('SELECT COUNT(*) FROM users');
    if (parseInt(count.rows[0].count) === 0) {
      // Пароль: admin123
      await pool.query(`
        INSERT INTO users (login, name, password_hash, role)
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
