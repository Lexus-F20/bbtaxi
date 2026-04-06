// Главный файл сервера такси-приложения
// Node.js + Express + Socket.io + PostgreSQL + FCM

require('dotenv').config();

const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');

// Импортируем роуты
const authRoutes = require('./routes/auth');
const adminRoutes = require('./routes/admin');
const markersRoutes = require('./routes/markers');
const notificationsRoutes = require('./routes/notifications');
const chatRoutes = require('./routes/chat');
const ratingsRoutes = require('./routes/ratings');
const usersRoutes = require('./routes/users');
const userRoutesRoutes = require('./routes/user_routes');
const uploadRoutes = require('./routes/upload');

// Импортируем middleware авторизации
const { authenticateToken } = require('./middleware/auth');

// Авто-инициализация БД
const initDatabase = require('./init_db');

const app = express();
const httpServer = http.createServer(app);

// Настройка Socket.io с поддержкой CORS
const io = new Server(httpServer, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST'],
    credentials: true,
  },
  transports: ['websocket', 'polling'],
  allowEIO3: true,
});

// Делаем io доступным во всех роутах через app.locals
app.locals.io = io;

// Доверяем proxy Railway/Heroku для корректной работы rate-limit
app.set('trust proxy', 1);

// Middleware
app.use(helmet({
  crossOriginResourcePolicy: false, // разрешаем Flutter/мобильным клиентам
}));
app.use(express.json());
app.use(cors({
  origin: '*',
  methods: ['GET', 'POST', 'PUT', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
}));

// Защита от брутфорса: не более 10 попыток входа за 15 минут с одного IP
const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 минут
  max: 10,
  message: { error: 'Слишком много попыток входа. Попробуйте через 15 минут.' },
  standardHeaders: true,
  legacyHeaders: false,
});

// ========== РОУТЫ ==========

app.use('/auth/login', loginLimiter);
app.use('/auth', authRoutes);
app.use('/admin', authenticateToken, adminRoutes);
app.use('/markers', authenticateToken, markersRoutes);
app.use('/notifications', authenticateToken, notificationsRoutes);
app.use('/chat', authenticateToken, chatRoutes);
app.use('/ratings', authenticateToken, ratingsRoutes);
app.use('/users', authenticateToken, usersRoutes);
app.use('/routes', authenticateToken, userRoutesRoutes);
app.use('/upload', authenticateToken, uploadRoutes);

// Проверка работоспособности сервера
app.get('/health', (req, res) => {
  res.json({ status: 'ok', version: '2.0-upload', timestamp: new Date().toISOString() });
});

// ========== SOCKET.IO ==========

// Хранилище соответствий userId -> socketId для адресных уведомлений
const userSockets = new Map();

io.on('connection', (socket) => {
  console.log('Новое Socket.io подключение:', socket.id);

  // Клиент регистрирует свой userId
  socket.on('register', (userId) => {
    userSockets.set(String(userId), socket.id);
    console.log(`Пользователь ${userId} зарегистрирован с socket ${socket.id}`);
  });

  // ========== ЧАТА ЧЕРЕЗ SOCKET ==========

  // Отправка сообщения в общий чат (альтернативный способ — без HTTP)
  socket.on('chat:send_global', async (data) => {
    try {
      const { text, senderId, senderName, senderRole } = data;
      if (!text || !senderId) return;

      const pool = require('./config/database');
      const result = await pool.query(
        `INSERT INTO messages (sender_id, receiver_id, text)
         VALUES ($1, NULL, $2)
         RETURNING id, sender_id, text, is_read, created_at`,
        [senderId, text.trim()]
      );

      const message = {
        ...result.rows[0],
        sender_name: senderName,
        sender_role: senderRole,
      };

      // Рассылаем всем
      io.emit('chat:global', message);
    } catch (error) {
      console.error('Ошибка Socket chat:send_global:', error);
    }
  });

  // При отключении удаляем пользователя из хранилища
  socket.on('disconnect', () => {
    for (const [userId, socketId] of userSockets.entries()) {
      if (socketId === socket.id) {
        userSockets.delete(userId);
        console.log(`Пользователь ${userId} отключился`);
        break;
      }
    }
  });
});

// Делаем хранилище userSockets доступным в роутах
app.locals.userSockets = userSockets;

// ========== ЗАПУСК СЕРВЕРА ==========

const PORT = process.env.PORT || 3000;

httpServer.listen(PORT, () => {
  console.log(`Сервер запущен на порту ${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/health`);
});

module.exports = { app, io };
