-- Миграция: добавление новых таблиц и полей
-- Выполните в pgAdmin → taxi_db → Query Tool → F5

-- Новые поля в таблице markers
ALTER TABLE markers
  ADD COLUMN IF NOT EXISTS color VARCHAR(20) DEFAULT 'orange',
  ADD COLUMN IF NOT EXISTS accepted_by INTEGER REFERENCES users(id),
  ADD COLUMN IF NOT EXISTS report TEXT,
  ADD COLUMN IF NOT EXISTS done_at TIMESTAMP;

-- Новый индекс
CREATE INDEX IF NOT EXISTS idx_markers_accepted_by ON markers(accepted_by);

-- Таблица истории действий с маркерами
CREATE TABLE IF NOT EXISTS marker_history (
  id SERIAL PRIMARY KEY,
  marker_id INTEGER REFERENCES markers(id),
  user_id INTEGER REFERENCES users(id),
  action VARCHAR(50) NOT NULL,
  note TEXT,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_marker_history_marker ON marker_history(marker_id);
CREATE INDEX IF NOT EXISTS idx_marker_history_user ON marker_history(user_id);

-- Таблица сообщений чата
-- receiver_id IS NULL = общий чат
CREATE TABLE IF NOT EXISTS messages (
  id SERIAL PRIMARY KEY,
  sender_id INTEGER REFERENCES users(id),
  receiver_id INTEGER REFERENCES users(id),
  text TEXT NOT NULL,
  is_read BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_receiver ON messages(receiver_id);

-- Рейтинг пользователей
ALTER TABLE users ADD COLUMN IF NOT EXISTS rating INTEGER DEFAULT 0;

-- Таблица истории изменений рейтинга
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

-- Таблица маршрутов (линии на карте, рисуемые пользователями)
CREATE TABLE IF NOT EXISTS routes (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
  title VARCHAR(255),
  points JSONB NOT NULL,          -- [{lat, lng}, ...]
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_routes_user_id ON routes(user_id);

-- Медиафайлы маркеров и сообщений
ALTER TABLE markers ADD COLUMN IF NOT EXISTS media_urls JSONB DEFAULT '[]';
ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_url TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS fcm_token TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS rating INTEGER DEFAULT 0;
