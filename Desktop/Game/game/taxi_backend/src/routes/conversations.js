// Роуты групповых бесед
const express = require('express');
const pool = require('../config/database');
const { sendPushToUser, saveNotification } = require('../services/fcm');

const router = express.Router();

// ─────────────────────────────────────────────────────────────────────────────
// GET /conversations
// Список бесед текущего пользователя с превью последнего сообщения
// ─────────────────────────────────────────────────────────────────────────────
router.get('/', async (req, res) => {
  const userId = req.user.id;
  try {
    const result = await pool.query(
      `SELECT
         c.id, c.name, c.created_by, c.created_at,
         last_msg.text    AS last_message,
         last_msg.created_at AS last_message_time,
         (SELECT COUNT(*) FROM messages msg
          WHERE msg.conversation_id = c.id
            AND msg.is_read = false
            AND msg.sender_id != $1) AS unread_count,
         (SELECT COUNT(*) FROM conversation_members
          WHERE conversation_id = c.id) AS member_count
       FROM conversations c
       JOIN conversation_members cm ON cm.conversation_id = c.id AND cm.user_id = $1
       LEFT JOIN LATERAL (
         SELECT text, created_at FROM messages
         WHERE conversation_id = c.id
         ORDER BY created_at DESC LIMIT 1
       ) last_msg ON true
       ORDER BY COALESCE(last_msg.created_at, c.created_at) DESC`,
      [userId]
    );
    return res.json({ conversations: result.rows });
  } catch (err) {
    console.error('Ошибка получения бесед:', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /conversations
// Создать новую беседу
// Body: { name: string, member_ids: number[] }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/', async (req, res) => {
  const userId = req.user.id;
  const { name, member_ids } = req.body;

  if (!name || String(name).trim() === '') {
    return res.status(400).json({ error: 'Название беседы обязательно' });
  }

  const memberIds = Array.isArray(member_ids) ? [...new Set([...member_ids, userId])] : [userId];

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const convResult = await client.query(
      `INSERT INTO conversations (name, created_by) VALUES ($1, $2) RETURNING *`,
      [String(name).trim(), userId]
    );
    const conv = convResult.rows[0];

    for (const memberId of memberIds) {
      const role = memberId === userId ? 'admin' : 'member';
      await client.query(
        `INSERT INTO conversation_members (conversation_id, user_id, role)
         VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
        [conv.id, memberId, role]
      );
    }

    await client.query('COMMIT');

    return res.status(201).json({
      conversation: { ...conv, member_count: memberIds.length, unread_count: 0 },
    });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('Ошибка создания беседы:', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  } finally {
    client.release();
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /conversations/:id/messages
// История сообщений беседы
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id/messages', async (req, res) => {
  const userId = req.user.id;
  const convId = parseInt(req.params.id);
  const limit = Math.min(parseInt(req.query.limit) || 50, 100);
  const offset = parseInt(req.query.offset) || 0;

  const memberCheck = await pool.query(
    `SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
    [convId, userId]
  );
  if (memberCheck.rows.length === 0) {
    return res.status(403).json({ error: 'Нет доступа к этой беседе' });
  }

  const mediaOnly = req.query.media_only === 'true' || req.query.media_only === '1';

  try {
    const result = await pool.query(
      `SELECT m.id, m.text, m.media_url, m.created_at, m.is_read,
              m.edited_at, m.is_deleted, m.forwarded_from_id, m.conversation_id,
              u.id AS sender_id, u.name AS sender_name, u.role AS sender_role
       FROM messages m
       LEFT JOIN users u ON m.sender_id = u.id
       WHERE m.conversation_id = $1
         ${mediaOnly ? 'AND m.media_url IS NOT NULL' : ''}
       ORDER BY m.created_at DESC
       LIMIT $2 OFFSET $3`,
      [convId, limit, offset]
    );

    const messages = result.rows.reverse();

    await pool.query(
      `UPDATE messages SET is_read = true
       WHERE conversation_id = $1 AND sender_id != $2 AND is_read = false`,
      [convId, userId]
    );

    return res.json({ messages });
  } catch (err) {
    console.error('Ошибка получения сообщений беседы:', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /conversations/:id/messages
// Отправить сообщение в беседу
// Body: { text?: string, media_url?: string }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/:id/messages', async (req, res) => {
  const userId = req.user.id;
  const convId = parseInt(req.params.id);
  const { text, media_url } = req.body;

  if ((!text || String(text).trim() === '') && !media_url) {
    return res.status(400).json({ error: 'Текст или медиафайл обязательны' });
  }

  const memberCheck = await pool.query(
    `SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
    [convId, userId]
  );
  if (memberCheck.rows.length === 0) {
    return res.status(403).json({ error: 'Нет доступа к этой беседе' });
  }

  try {
    const msgResult = await pool.query(
      `INSERT INTO messages (sender_id, conversation_id, text, media_url)
       VALUES ($1, $2, $3, $4)
       RETURNING id, sender_id, conversation_id, text, media_url, is_read, created_at`,
      [userId, convId, (text || '').trim(), media_url || null]
    );
    const message = msgResult.rows[0];

    const senderResult = await pool.query(
      'SELECT name, role FROM users WHERE id = $1', [userId]
    );
    const sender = senderResult.rows[0];

    const fullMessage = { ...message, sender_name: sender?.name, sender_role: sender?.role };

    // Рассылаем всем участникам беседы
    const io = req.app.locals.io;
    const userSockets = req.app.locals.userSockets;

    const membersResult = await pool.query(
      `SELECT user_id FROM conversation_members WHERE conversation_id = $1`, [convId]
    );

    const convNameResult = await pool.query(
      'SELECT name FROM conversations WHERE id = $1', [convId]
    );
    const convName = convNameResult.rows[0]?.name || 'Беседа';
    const pushText = (message.text || '').trim() || '📎 Медиафайл';
    const truncated = pushText.length > 100 ? pushText.substring(0, 97) + '...' : pushText;

    for (const member of membersResult.rows) {
      const socketId = userSockets.get(String(member.user_id));
      if (socketId) {
        io.to(socketId).emit('chat:conversation', { conversation_id: convId, message: fullMessage });
      } else if (member.user_id !== userId) {
        // Push оффлайн участникам
        await saveNotification(member.user_id, convName, `${sender?.name}: ${truncated}`);
        await sendPushToUser(
          member.user_id,
          `💬 ${convName}`,
          `${sender?.name}: ${truncated}`,
          { type: 'chat_conversation', conversationId: String(convId) }
        );
      }
    }

    return res.status(201).json({ message: fullMessage });
  } catch (err) {
    console.error('Ошибка отправки в беседу:', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /conversations/:id/members
// Список участников беседы
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id/members', async (req, res) => {
  const userId = req.user.id;
  const convId = parseInt(req.params.id);

  const memberCheck = await pool.query(
    `SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
    [convId, userId]
  );
  if (memberCheck.rows.length === 0) {
    return res.status(403).json({ error: 'Нет доступа' });
  }

  try {
    const result = await pool.query(
      `SELECT u.id, u.name, u.role, cm.role AS member_role, cm.joined_at
       FROM conversation_members cm
       JOIN users u ON u.id = cm.user_id
       WHERE cm.conversation_id = $1
       ORDER BY cm.joined_at ASC`,
      [convId]
    );
    return res.json({ members: result.rows });
  } catch (err) {
    console.error('Ошибка получения участников:', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /conversations/:id/members
// Добавить участника (только admin беседы)
// Body: { user_id: number }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/:id/members', async (req, res) => {
  const userId = req.user.id;
  const convId = parseInt(req.params.id);
  const { user_id } = req.body;

  const roleCheck = await pool.query(
    `SELECT role FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
    [convId, userId]
  );
  if (roleCheck.rows.length === 0 || roleCheck.rows[0].role !== 'admin') {
    return res.status(403).json({ error: 'Только администратор беседы может добавлять участников' });
  }

  try {
    await pool.query(
      `INSERT INTO conversation_members (conversation_id, user_id, role)
       VALUES ($1, $2, 'member') ON CONFLICT DO NOTHING`,
      [convId, user_id]
    );
    return res.json({ ok: true });
  } catch (err) {
    console.error('Ошибка добавления участника:', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// DELETE /conversations/:id/members/:userId
// Удалить участника или покинуть беседу
// ─────────────────────────────────────────────────────────────────────────────
router.delete('/:id/members/:userId', async (req, res) => {
  const currentUserId = req.user.id;
  const convId = parseInt(req.params.id);
  const targetUserId = parseInt(req.params.userId);

  if (currentUserId !== targetUserId) {
    const roleCheck = await pool.query(
      `SELECT role FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
      [convId, currentUserId]
    );
    if (roleCheck.rows.length === 0 || roleCheck.rows[0].role !== 'admin') {
      return res.status(403).json({ error: 'Только администратор может удалять участников' });
    }
  }

  try {
    await pool.query(
      `DELETE FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
      [convId, targetUserId]
    );
    return res.json({ ok: true });
  } catch (err) {
    console.error('Ошибка удаления участника:', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// PATCH /conversations/:id/members/:userId
// Изменить роль участника (только admin беседы)
// Body: { role: 'admin' | 'member' }
// ─────────────────────────────────────────────────────────────────────────────
router.patch('/:id/members/:userId', async (req, res) => {
  const currentUserId = req.user.id;
  const convId = parseInt(req.params.id);
  const targetUserId = parseInt(req.params.userId);
  const { role } = req.body;

  if (!['admin', 'member'].includes(role)) {
    return res.status(400).json({ error: 'Роль должна быть admin или member' });
  }

  const roleCheck = await pool.query(
    `SELECT role FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
    [convId, currentUserId]
  );
  if (roleCheck.rows.length === 0 || roleCheck.rows[0].role !== 'admin') {
    return res.status(403).json({ error: 'Только администратор беседы может менять роли' });
  }

  try {
    await pool.query(
      `UPDATE conversation_members SET role = $1 WHERE conversation_id = $2 AND user_id = $3`,
      [role, convId, targetUserId]
    );
    return res.json({ ok: true });
  } catch (err) {
    console.error('Ошибка смены роли:', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// PUT /conversations/:id
// Изменить название беседы (только admin)
// Body: { name: string }
// ─────────────────────────────────────────────────────────────────────────────
router.put('/:id', async (req, res) => {
  const userId = req.user.id;
  const convId = parseInt(req.params.id);
  const { name } = req.body;

  if (!name || String(name).trim() === '') {
    return res.status(400).json({ error: 'Название не может быть пустым' });
  }

  const roleCheck = await pool.query(
    `SELECT role FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
    [convId, userId]
  );
  if (roleCheck.rows.length === 0 || roleCheck.rows[0].role !== 'admin') {
    return res.status(403).json({ error: 'Только администратор может изменять название' });
  }

  try {
    const result = await pool.query(
      `UPDATE conversations SET name = $1 WHERE id = $2 RETURNING *`,
      [String(name).trim(), convId]
    );
    return res.json({ conversation: result.rows[0] });
  } catch (err) {
    console.error('Ошибка обновления беседы:', err);
    return res.status(500).json({ error: 'Ошибка сервера' });
  }
});

module.exports = router;
