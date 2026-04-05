// Роуты чата: общий чат и личные сообщения
const express = require('express');
const pool = require('../config/database');

const router = express.Router();

// ========== ОБЩИЙ ЧАТ ==========

/**
 * GET /chat/global
 * Получить сообщения общего чата (receiver_id IS NULL).
 * Поддерживает пагинацию: ?limit=50&offset=0
 */
router.get('/global', async (req, res) => {
  try {
    const limit = Math.min(parseInt(req.query.limit) || 50, 100);
    const offset = parseInt(req.query.offset) || 0;

    const result = await pool.query(
      `SELECT m.id, m.text, m.created_at, m.is_read,
              u.id AS sender_id, u.name AS sender_name, u.role AS sender_role
       FROM messages m
       LEFT JOIN users u ON m.sender_id = u.id
       WHERE m.receiver_id IS NULL
       ORDER BY m.created_at DESC
       LIMIT $1 OFFSET $2`,
      [limit, offset]
    );

    // Возвращаем в хронологическом порядке (старые сверху)
    const messages = result.rows.reverse();

    return res.json({ messages });
  } catch (error) {
    console.error('Ошибка получения общего чата:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * POST /chat/global
 * Отправить сообщение в общий чат.
 *
 * Body: { text: string }
 */
router.post('/global', async (req, res) => {
  try {
    const { text } = req.body;
    const senderId = req.user.id;

    if (!text || text.trim() === '') {
      return res.status(400).json({ error: 'Текст сообщения обязателен' });
    }

    const result = await pool.query(
      `INSERT INTO messages (sender_id, receiver_id, text)
       VALUES ($1, NULL, $2)
       RETURNING id, sender_id, text, is_read, created_at`,
      [senderId, text.trim()]
    );

    const message = result.rows[0];

    // Получаем имя отправителя
    const userResult = await pool.query(
      'SELECT name, role FROM users WHERE id = $1',
      [senderId]
    );
    const sender = userResult.rows[0];

    const fullMessage = {
      ...message,
      sender_name: sender?.name,
      sender_role: sender?.role,
    };

    // Рассылаем всем подключённым через Socket.io
    const io = req.app.locals.io;
    io.emit('chat:global', fullMessage);

    return res.status(201).json({ message: fullMessage });
  } catch (error) {
    console.error('Ошибка отправки в общий чат:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

// ========== ЛИЧНЫЕ СООБЩЕНИЯ ==========

/**
 * GET /chat/direct/:userId
 * Получить переписку с конкретным пользователем.
 * Возвращает сообщения в обе стороны между текущим и userId.
 */
router.get('/direct/:userId', async (req, res) => {
  try {
    const currentUserId = req.user.id;
    const targetUserId = parseInt(req.params.userId);
    const limit = Math.min(parseInt(req.query.limit) || 50, 100);
    const offset = parseInt(req.query.offset) || 0;

    const result = await pool.query(
      `SELECT m.id, m.text, m.created_at, m.is_read,
              u.id AS sender_id, u.name AS sender_name, u.role AS sender_role,
              r.id AS receiver_id, r.name AS receiver_name
       FROM messages m
       LEFT JOIN users u ON m.sender_id = u.id
       LEFT JOIN users r ON m.receiver_id = r.id
       WHERE (m.sender_id = $1 AND m.receiver_id = $2)
          OR (m.sender_id = $2 AND m.receiver_id = $1)
       ORDER BY m.created_at DESC
       LIMIT $3 OFFSET $4`,
      [currentUserId, targetUserId, limit, offset]
    );

    const messages = result.rows.reverse();

    // Помечаем входящие сообщения как прочитанные
    await pool.query(
      `UPDATE messages SET is_read = true
       WHERE sender_id = $1 AND receiver_id = $2 AND is_read = false`,
      [targetUserId, currentUserId]
    );

    return res.json({ messages });
  } catch (error) {
    console.error('Ошибка получения личных сообщений:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * POST /chat/direct/:userId
 * Отправить личное сообщение пользователю.
 *
 * Body: { text: string }
 */
router.post('/direct/:userId', async (req, res) => {
  try {
    const { text } = req.body;
    const senderId = req.user.id;
    const receiverId = parseInt(req.params.userId);

    if (!text || text.trim() === '') {
      return res.status(400).json({ error: 'Текст сообщения обязателен' });
    }

    // Проверяем существование получателя
    const receiverResult = await pool.query(
      'SELECT id, name, role FROM users WHERE id = $1 AND is_active = true',
      [receiverId]
    );

    if (receiverResult.rows.length === 0) {
      return res.status(404).json({ error: 'Получатель не найден' });
    }

    const receiver = receiverResult.rows[0];

    const result = await pool.query(
      `INSERT INTO messages (sender_id, receiver_id, text)
       VALUES ($1, $2, $3)
       RETURNING id, sender_id, receiver_id, text, is_read, created_at`,
      [senderId, receiverId, text.trim()]
    );

    const message = result.rows[0];

    // Получаем имя отправителя
    const senderResult = await pool.query(
      'SELECT name, role FROM users WHERE id = $1',
      [senderId]
    );
    const sender = senderResult.rows[0];

    const fullMessage = {
      ...message,
      sender_name: sender?.name,
      sender_role: sender?.role,
      receiver_name: receiver.name,
    };

    // Отправляем получателю через Socket.io
    const io = req.app.locals.io;
    const userSockets = req.app.locals.userSockets;

    const receiverSocketId = userSockets.get(String(receiverId));
    if (receiverSocketId) {
      io.to(receiverSocketId).emit('chat:direct', fullMessage);
    }

    // Отправляем отправителю (для синхронизации других устройств)
    const senderSocketId = userSockets.get(String(senderId));
    if (senderSocketId) {
      io.to(senderSocketId).emit('chat:direct', fullMessage);
    }

    return res.status(201).json({ message: fullMessage });
  } catch (error) {
    console.error('Ошибка отправки личного сообщения:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * GET /chat/users
 * Получить список пользователей с которыми можно писать.
 * Для admin: все пользователи.
 * Для остальных: все пользователи кроме себя.
 */
router.get('/users', async (req, res) => {
  try {
    const currentUserId = req.user.id;

    const result = await pool.query(
      `SELECT u.id, u.name, u.role, u.is_active,
              COUNT(m.id) FILTER (WHERE m.is_read = false AND m.receiver_id = $1) AS unread_count
       FROM users u
       LEFT JOIN messages m ON m.sender_id = u.id AND m.receiver_id = $1
       WHERE u.id != $1 AND u.is_active = true
       GROUP BY u.id, u.name, u.role, u.is_active
       ORDER BY unread_count DESC, u.name ASC`,
      [currentUserId]
    );

    return res.json({ users: result.rows });
  } catch (error) {
    console.error('Ошибка получения пользователей чата:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * GET /chat/unread
 * Количество непрочитанных личных сообщений текущего пользователя.
 */
router.get('/unread', async (req, res) => {
  try {
    const userId = req.user.id;

    const result = await pool.query(
      `SELECT COUNT(*) AS count FROM messages
       WHERE receiver_id = $1 AND is_read = false`,
      [userId]
    );

    return res.json({ count: parseInt(result.rows[0].count) });
  } catch (error) {
    console.error('Ошибка получения непрочитанных сообщений:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * GET /chat/conversations
 * Список переписок текущего пользователя (только личные).
 * Возвращает собеседников с последним сообщением и кол-вом непрочитанных.
 */
router.get('/conversations', async (req, res) => {
  try {
    const userId = req.user.id;

    const result = await pool.query(
      `WITH convs AS (
         SELECT
           CASE WHEN sender_id = $1 THEN receiver_id ELSE sender_id END AS partner_id,
           MAX(id) AS last_msg_id
         FROM messages
         WHERE (sender_id = $1 OR receiver_id = $1)
           AND receiver_id IS NOT NULL
         GROUP BY CASE WHEN sender_id = $1 THEN receiver_id ELSE sender_id END
       )
       SELECT
         u.id AS user_id, u.name AS user_name, u.role AS user_role,
         m.text AS last_message,
         m.created_at AS last_message_time,
         (SELECT COUNT(*) FROM messages
          WHERE sender_id = u.id AND receiver_id = $1 AND is_read = false) AS unread_count
       FROM convs c
       JOIN users u ON u.id = c.partner_id
       JOIN messages m ON m.id = c.last_msg_id
       WHERE u.is_active = true
       ORDER BY m.created_at DESC`,
      [userId]
    );

    return res.json({ conversations: result.rows });
  } catch (error) {
    console.error('Ошибка получения переписок:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

module.exports = router;
