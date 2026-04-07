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

// Версия приложения для автообновления
app.get('/version', (req, res) => {
  const storagePath = process.env.APK_STORAGE_PATH;
  let apkUrl = process.env.APK_URL || null;
  if (storagePath) {
    // Используем наш прокси — он стримит файл напрямую через Admin SDK
    const host = process.env.RAILWAY_PUBLIC_DOMAIN
      ? `https://${process.env.RAILWAY_PUBLIC_DOMAIN}`
      : `${req.protocol}://${req.get('host')}`;
    apkUrl = `${host}/apk`;
  }
  res.json({
    version: process.env.APP_VERSION || '1.0.0',
    apk_url: apkUrl,
  });
});

app.get('/media/*', async (req, res) => {

  const storagePath = req.params[0];

  console.log(`[media] Запрос: ${storagePath}`);



  try {

    const admin = require('./config/firebase');

    const bucket = admin.storage().bucket();

    const file = bucket.file(storagePath);



    const [exists] = await file.exists();

    if (!exists) {

      return res.status(404).json({ error: 'Файл не найден' });

    }



    const [metadata] = await file.getMetadata();



    res.setHeader('Content-Type', metadata.contentType || 'application/octet-stream');

    res.setHeader('Cache-Control', 'no-store');



    file.createReadStream()

      .on('error', (err) => {

        console.error('Ошибка стрима:', err);

        if (!res.headersSent) {

          res.status(500).json({ error: 'Ошибка загрузки файла' });

        }

      })

      .pipe(res);



  } catch (e) {

    console.error('Ошибка /media:', e.message);

    if (!res.headersSent) res.status(500).json({ error: e.message });

  }

});

// Скачать APK — стримит файл из Firebase Storage через Admin SDK.
// Обходит правила безопасности Storage и не требует IAM signed URL.
// Установите в Railway: APK_STORAGE_PATH=apk/app-release.apk
app.get('/apk', async (req, res) => {
  const storagePath = process.env.APK_STORAGE_PATH || 'apk/app-release.apk';
  try {
    const admin = require('./config/firebase');
    const bucket = admin.storage().bucket();
    const file = bucket.file(storagePath);

    const [exists] = await file.exists();
    if (!exists) {
      return res.status(404).json({ error: 'APK не найден в Storage' });
    }

    const [metadata] = await file.getMetadata();
    res.setHeader('Content-Type', 'application/vnd.android.package-archive');
    res.setHeader('Content-Disposition', 'attachment; filename="app-release.apk"');
    if (metadata.size) res.setHeader('Content-Length', metadata.size);

    file.createReadStream()
      .on('error', (err) => {
        console.error('Ошибка стриминга APK:', err.message);
        if (!res.headersSent) res.status(500).json({ error: 'Ошибка загрузки' });
      })
      .pipe(res);
  } catch (e) {
    console.error('Ошибка /apk:', e.message);
    if (!res.headersSent) res.status(500).json({ error: e.message });
  }
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

httpServer.listen(PORT, async () => {
  console.log(`Сервер запущен на порту ${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/health`);
  await initDatabase();
});

module.exports = { app, io };
