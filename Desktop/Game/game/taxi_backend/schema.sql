-- SQL-схема базы данных приложения такси
-- PostgreSQL
-- Выполните этот файл в pgAdmin: taxi_db → Query Tool → F5

-- ========== ПОЛЬЗОВАТЕЛИ ==========
CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  phone VARCHAR(20) UNIQUE NOT NULL,           -- Уникальный номер телефона для входа
  name VARCHAR(100) NOT NULL,                   -- Имя пользователя
  password_hash TEXT NOT NULL,                  -- Хэш пароля (bcrypt)
  role VARCHAR(20) DEFAULT 'user',              -- Роль: 'admin', 'driver', 'user'
  is_active BOOLEAN DEFAULT true,               -- false = заблокирован
  fcm_token TEXT,                               -- FCM токен для push-уведомлений
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_phone ON users(phone);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);

-- ========== МАРКЕРЫ ==========
CREATE TABLE IF NOT EXISTS markers (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES users(id),         -- Кто поставил маркер
  accepted_by INTEGER REFERENCES users(id),     -- Кто взял маркер (driver/admin)
  latitude DOUBLE PRECISION NOT NULL,
  longitude DOUBLE PRECISION NOT NULL,
  title VARCHAR(255),
  description TEXT,
  color VARCHAR(20) DEFAULT 'orange',           -- Цвет маркера: red, orange, yellow, green, blue, purple
  status VARCHAR(20) DEFAULT 'pending',         -- pending, accepted, rejected, done, abandoned
  reject_reason TEXT,                           -- Причина отказа
  report TEXT,                                  -- Отчёт исполнителя после завершения
  done_at TIMESTAMP,                            -- Время завершения
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_markers_status ON markers(status);
CREATE INDEX IF NOT EXISTS idx_markers_user_id ON markers(user_id);
CREATE INDEX IF NOT EXISTS idx_markers_accepted_by ON markers(accepted_by);

-- ========== ИСТОРИЯ ДЕЙСТВИЙ С МАРКЕРАМИ ==========
-- Все действия: создан, взят, отклонён, выполнен, заброшен
CREATE TABLE IF NOT EXISTS marker_history (
  id SERIAL PRIMARY KEY,
  marker_id INTEGER REFERENCES markers(id),
  user_id INTEGER REFERENCES users(id),         -- Кто совершил действие
  action VARCHAR(50) NOT NULL,                  -- created, accepted, rejected, done, abandoned
  note TEXT,                                    -- Доп. информация (причина, отчёт)
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_marker_history_marker ON marker_history(marker_id);
CREATE INDEX IF NOT EXISTS idx_marker_history_user ON marker_history(user_id);

-- ========== УВЕДОМЛЕНИЯ ==========
CREATE TABLE IF NOT EXISTS notifications (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES users(id),
  title VARCHAR(255),
  body TEXT,
  is_read BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_is_read ON notifications(is_read);

-- ========== СООБЩЕНИЯ ЧАТА ==========
-- receiver_id = NULL → общий чат (виден всем)
-- receiver_id = userId → личное сообщение конкретному пользователю
CREATE TABLE IF NOT EXISTS messages (
  id SERIAL PRIMARY KEY,
  sender_id INTEGER REFERENCES users(id),
  receiver_id INTEGER REFERENCES users(id),     -- NULL = общий чат
  text TEXT NOT NULL,
  media_url TEXT,
  edited_at TIMESTAMP,
  is_deleted BOOLEAN DEFAULT false,
  forwarded_from_id INTEGER REFERENCES messages(id),
  is_read BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_receiver ON messages(receiver_id);
CREATE INDEX IF NOT EXISTS idx_messages_global ON messages(receiver_id) WHERE receiver_id IS NULL;

-- ========== ЗАКАЗЫ ==========
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

-- ========== ТЕСТОВЫЙ АДМИНИСТРАТОР ==========
-- Телефон: +70000000000, Пароль: admin123
INSERT INTO users (phone, name, password_hash, role)
VALUES ('+70000000000', 'Администратор', '$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy', 'admin')
ON CONFLICT (phone) DO NOTHING;

-- Тестовый пользователь admin/admin
INSERT INTO users (phone, name, password_hash, role)
VALUES ('admin', 'Администратор', '$2a$10$s5dIVrEu41L//163RXsIvO6eICQpV0zfHhR5rmcSNU4OVz6JHoCVm', 'admin')
ON CONFLICT (phone) DO NOTHING;

-- ========== РЕЙТИНГ ==========
-- Добавить столбец рейтинга к пользователям (выполнить если ещё нет)
ALTER TABLE users ADD COLUMN IF NOT EXISTS rating INTEGER DEFAULT 0;

-- История изменений рейтинга
CREATE TABLE IF NOT EXISTS rating_history (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES users(id),
  changed_by INTEGER REFERENCES users(id),
  delta INTEGER NOT NULL,
  reason TEXT,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rating_history_user ON rating_history(user_id);

-- Обновить роль 'user' → 'viewer' для существующих пользователей
UPDATE users SET role = 'viewer' WHERE role = 'user';
