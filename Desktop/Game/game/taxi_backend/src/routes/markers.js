// Роуты для работы с маркерами на карте
const express = require('express');
const pool = require('../config/database');
const { requireAdminOrDriver } = require('../middleware/auth');
const {
  sendPushToAll,
  sendPushNotification,
  saveNotification,
  saveNotificationForAll,
} = require('../services/fcm');

const router = express.Router();

// ========== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ==========

/**
 * Записывает действие в историю маркера
 */
async function recordHistory(markerId, userId, action, note = null) {
  try {
    await pool.query(
      `INSERT INTO marker_history (marker_id, user_id, action, note)
       VALUES ($1, $2, $3, $4)`,
      [markerId, userId, action, note]
    );
  } catch (err) {
    console.warn(`recordHistory failed (marker ${markerId}, action ${action}):`, err.message);
  }
}

// ========== СОЗДАТЬ МАРКЕР ==========

/**
 * POST /markers
 * Создать новый маркер на карте.
 * После создания уведомляет всех через FCM + Socket.io.
 *
 * Body: { latitude, longitude, title, description, color? }
 */
router.post('/', async (req, res) => {
  try {
    const { latitude, longitude, title, description, color } = req.body;
    const userId = req.user.id;
    const userName = req.user.name;

    if (latitude === undefined || longitude === undefined) {
      return res.status(400).json({ error: 'Координаты обязательны' });
    }

    if (!title) {
      return res.status(400).json({ error: 'Название маркера обязательно' });
    }

    // Допустимые цвета маркеров
    const allowedColors = ['red', 'orange', 'yellow', 'green', 'blue', 'purple', 'pink'];
    const markerColor = allowedColors.includes(color) ? color : 'orange';

    // Сохраняем маркер в БД
    const result = await pool.query(
      `INSERT INTO markers (user_id, latitude, longitude, title, description, color, status)
       VALUES ($1, $2, $3, $4, $5, $6, 'pending')
       RETURNING id, user_id, latitude, longitude, title, description, color, status, created_at`,
      [userId, latitude, longitude, title, description || '', markerColor]
    );

    const newMarker = result.rows[0];

    // Записываем в историю: "создан"
    await recordHistory(newMarker.id, userId, 'created', title);

    const io = req.app.locals.io;
    const markerData = { ...newMarker, user_name: userName };

    // Рассылаем всем через Socket.io
    io.emit('marker:new', markerData);

    // Push-уведомление и запись в БД для всех кроме автора
    const pushTitle = 'Новый маркер';
    const pushBody = `${userName}: ${title}`;
    await saveNotificationForAll(pushTitle, pushBody, userId);
    await sendPushToAll(pushTitle, pushBody, { markerId: String(newMarker.id) }, userId);

    return res.status(201).json({ message: 'Маркер создан', marker: markerData });
  } catch (error) {
    console.error('Ошибка создания маркера:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

// ========== ПОЛУЧИТЬ ВСЕ МАРКЕРЫ ==========

/**
 * GET /markers
 * Получить маркеры.
 * По умолчанию возвращает только 'pending' (не взятые).
 * Для Admin/Driver: ?all=true — возвращает все статусы.
 */
router.get('/', async (req, res) => {
  try {
    const { status, all } = req.query;
    const userRole = req.user.role;

    let query = `
      SELECT m.id, m.latitude, m.longitude, m.title, m.description,
             m.color, m.status, m.reject_reason, m.report, m.done_at, m.created_at,
             u.id AS user_id, u.name AS user_name,
             a.id AS accepted_by, a.name AS accepted_by_name
      FROM markers m
      LEFT JOIN users u ON m.user_id = u.id
      LEFT JOIN users a ON m.accepted_by = a.id
    `;
    const params = [];
    const conditions = [];

    if (status) {
      // Конкретный статус из запроса
      conditions.push(`m.status = $${params.length + 1}`);
      params.push(status);
    } else {
      // Pending — видят все; accepted — только исполнитель видит свой взятый маркер на карте
      conditions.push(`(m.status = 'pending' OR (m.status = 'accepted' AND m.accepted_by = $${params.length + 1}))`);
      params.push(req.user.id);
    }

    if (conditions.length > 0) {
      query += ' WHERE ' + conditions.join(' AND ');
    }

    query += ' ORDER BY m.created_at DESC';

    const result = await pool.query(query, params);
    return res.json({ markers: result.rows });
  } catch (error) {
    console.error('Ошибка получения маркеров:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

// ========== МОИ МАРКЕРЫ ==========

/**
 * GET /markers/my
 * Маркеры текущего пользователя (история).
 */
router.get('/my', async (req, res) => {
  try {
    const userId = req.user.id;

    const result = await pool.query(
      `SELECT m.id, m.user_id, m.latitude, m.longitude, m.title, m.description,
              m.color, m.status, m.reject_reason, m.report, m.done_at, m.created_at,
              u.name AS user_name,
              a.id AS accepted_by, a.name AS accepted_by_name
       FROM markers m
       LEFT JOIN users u ON m.user_id = u.id
       LEFT JOIN users a ON m.accepted_by = a.id
       WHERE m.user_id = $1
       ORDER BY m.created_at DESC`,
      [userId]
    );

    return res.json({ markers: result.rows });
  } catch (error) {
    console.error('Ошибка получения маркеров пользователя:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

// ========== ВЗЯТЫЕ МНОЙ МАРКЕРЫ ==========

/**
 * GET /markers/taken
 * Маркеры которые текущий пользователь взял на исполнение.
 * ?status=accepted            — только в работе
 * ?status=done,abandoned      — история (выполненные + отказался)
 */
router.get('/taken', async (req, res) => {
  try {
    const userId = req.user.id;
    const { status } = req.query;

    let statusClause;
    const params = [userId];

    if (status) {
      const statuses = status.split(',');
      statusClause = `m.status = ANY($2::text[])`;
      params.push(statuses);
    } else {
      statusClause = `m.status IN ('accepted', 'done', 'abandoned')`;
    }

    const result = await pool.query(
      `SELECT m.id, m.user_id, m.accepted_by, m.latitude, m.longitude, m.title, m.description,
              m.color, m.status, m.reject_reason, m.report, m.done_at, m.created_at,
              u.name AS user_name, a.name AS accepted_by_name
       FROM markers m
       LEFT JOIN users u ON m.user_id = u.id
       LEFT JOIN users a ON m.accepted_by = a.id
       WHERE m.accepted_by = $1 AND ${statusClause}
       ORDER BY m.created_at DESC`,
      params
    );

    return res.json({ markers: result.rows });
  } catch (error) {
    console.error('Ошибка получения взятых маркеров:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

// ========== ИСТОРИЯ МАРКЕРА ==========

/**
 * GET /markers/:id/history
 * История действий по конкретному маркеру.
 */
router.get('/:id/history', async (req, res) => {
  try {
    const { id } = req.params;

    const result = await pool.query(
      `SELECT mh.id, mh.action, mh.note, mh.created_at,
              u.name AS user_name, u.role AS user_role
       FROM marker_history mh
       LEFT JOIN users u ON mh.user_id = u.id
       WHERE mh.marker_id = $1
       ORDER BY mh.created_at ASC`,
      [id]
    );

    return res.json({ history: result.rows });
  } catch (error) {
    console.error('Ошибка получения истории маркера:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

// ========== ПРИНЯТЬ МАРКЕР ==========

/**
 * PUT /markers/:id/accept
 * Взять маркер на исполнение (доступно всем пользователям).
 * Маркер исчезает с общей карты — статус меняется на 'accepted'.
 */
router.put('/:id/accept', async (req, res) => {
  try {
    const { id } = req.params;
    const acceptorId = req.user.id;
    const acceptorName = req.user.name;

    const markerResult = await pool.query(
      `SELECT m.*, u.name AS user_name, u.fcm_token
       FROM markers m
       LEFT JOIN users u ON m.user_id = u.id
       WHERE m.id = $1`,
      [id]
    );

    if (markerResult.rows.length === 0) {
      return res.status(404).json({ error: 'Маркер не найден' });
    }

    const marker = markerResult.rows[0];

    if (marker.status !== 'pending') {
      return res.status(400).json({ error: 'Маркер уже взят или обработан' });
    }

    // Обновляем статус и записываем кто взял
    const updateResult = await pool.query(
      `UPDATE markers
       SET status = 'accepted', accepted_by = $2
       WHERE id = $1
       RETURNING id, latitude, longitude, title, description, color, status,
                 reject_reason, report, done_at, created_at, user_id, accepted_by`,
      [id, acceptorId]
    );

    const updatedMarker = {
      ...updateResult.rows[0],
      user_name: marker.user_name,
      accepted_by_name: acceptorName,
    };

    // Записываем в историю
    await recordHistory(id, acceptorId, 'accepted', `Взят исполнителем: ${acceptorName}`);

    const io = req.app.locals.io;
    const userSockets = req.app.locals.userSockets;

    // Уведомляем всех — маркер исчезает с карты
    io.emit('marker:accepted', updatedMarker);

    // Уведомляем автора маркера
    const notifTitle = 'Маркер взят';
    const notifBody = `Ваш маркер "${marker.title}" взял ${acceptorName}`;
    await saveNotification(marker.user_id, notifTitle, notifBody);

    if (marker.fcm_token) {
      await sendPushNotification(marker.fcm_token, notifTitle, notifBody, {
        markerId: String(id),
        type: 'marker_accepted',
      });
    }

    const authorSocketId = userSockets.get(String(marker.user_id));
    if (authorSocketId) {
      io.to(authorSocketId).emit('notification:new', { title: notifTitle, body: notifBody });
    }

    return res.json({ message: 'Маркер взят', marker: updatedMarker });
  } catch (error) {
    console.error('Ошибка принятия маркера:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

// ========== ОТКЛОНИТЬ МАРКЕР ==========

/**
 * PUT /markers/:id/reject
 * Отклонить маркер с обязательной причиной (только admin/driver).
 *
 * Body: { reason: string }
 */
router.put('/:id/reject', requireAdminOrDriver, async (req, res) => {
  try {
    const { id } = req.params;
    const { reason } = req.body;

    if (!reason || reason.trim() === '') {
      return res.status(400).json({ error: 'Причина отказа обязательна' });
    }

    const markerResult = await pool.query(
      `SELECT m.*, u.name AS user_name, u.fcm_token
       FROM markers m
       LEFT JOIN users u ON m.user_id = u.id
       WHERE m.id = $1`,
      [id]
    );

    if (markerResult.rows.length === 0) {
      return res.status(404).json({ error: 'Маркер не найден' });
    }

    const marker = markerResult.rows[0];

    if (marker.status !== 'pending') {
      return res.status(400).json({ error: 'Маркер уже обработан' });
    }

    const updateResult = await pool.query(
      `UPDATE markers SET status = 'rejected', reject_reason = $2 WHERE id = $1
       RETURNING id, latitude, longitude, title, description, color, status, reject_reason, created_at`,
      [id, reason]
    );

    const updatedMarker = { ...updateResult.rows[0], user_name: marker.user_name };

    // История
    await recordHistory(id, req.user.id, 'rejected', reason);

    const io = req.app.locals.io;
    const userSockets = req.app.locals.userSockets;

    io.emit('marker:rejected', { ...updatedMarker, user_id: marker.user_id, user_name: marker.user_name });

    const notifTitle = 'Маркер отклонён';
    const notifBody = `Маркер "${marker.title}" отклонён. Причина: ${reason}`;
    await saveNotification(marker.user_id, notifTitle, notifBody);

    if (marker.fcm_token) {
      await sendPushNotification(marker.fcm_token, notifTitle, notifBody, {
        markerId: String(id),
        type: 'marker_rejected',
        reason,
      });
    }

    const authorSocketId = userSockets.get(String(marker.user_id));
    if (authorSocketId) {
      io.to(authorSocketId).emit('notification:new', {
        title: notifTitle,
        body: notifBody,
        markerId: id,
        reason,
      });
    }

    return res.json({ message: 'Маркер отклонён', marker: updatedMarker });
  } catch (error) {
    console.error('Ошибка отклонения маркера:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

// ========== ВЫПОЛНИТЬ МАРКЕР ==========

/**
 * PUT /markers/:id/complete
 * Отметить маркер как выполненный.
 * Только тот, кто взял маркер (accepted_by).
 *
 * Body: { report: string }
 */
router.put('/:id/complete', async (req, res) => {
  try {
    const { id } = req.params;
    const { report } = req.body;
    const userId = req.user.id;
    const userName = req.user.name;

    if (!report || report.trim() === '') {
      return res.status(400).json({ error: 'Отчёт о выполнении обязателен' });
    }

    const markerResult = await pool.query(
      `SELECT m.*, u.name AS user_name, u.fcm_token
       FROM markers m
       LEFT JOIN users u ON m.user_id = u.id
       WHERE m.id = $1`,
      [id]
    );

    if (markerResult.rows.length === 0) {
      return res.status(404).json({ error: 'Маркер не найден' });
    }

    const marker = markerResult.rows[0];

    // Только тот кто взял маркер может его завершить (или admin)
    if (String(marker.accepted_by) !== String(userId) && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Только исполнитель или администратор может завершить маркер' });
    }

    if (marker.status !== 'accepted') {
      return res.status(400).json({ error: 'Можно завершить только взятый маркер' });
    }

    const updateResult = await pool.query(
      `UPDATE markers
       SET status = 'done', report = $2, done_at = NOW()
       WHERE id = $1
       RETURNING id, latitude, longitude, title, description, color, status,
                 report, done_at, created_at, user_id, accepted_by`,
      [id, report]
    );

    const updatedMarker = {
      ...updateResult.rows[0],
      user_name: marker.user_name,
      accepted_by_name: userName,
    };

    // История
    await recordHistory(id, userId, 'done', report);

    // Увеличиваем рейтинг исполнителя за выполненный заказ
    try {
      await pool.query('UPDATE users SET rating = rating + 1 WHERE id = $1', [userId]);
      await pool.query(
        'INSERT INTO rating_history (user_id, changed_by, delta, reason) VALUES ($1, $1, 1, $2)',
        [userId, `Выполнен заказ #${id}: ${marker.title}`]
      );
    } catch (ratingErr) {
      console.warn('Не удалось обновить рейтинг (таблица не создана?):', ratingErr.message);
    }

    const io = req.app.locals.io;
    const userSockets = req.app.locals.userSockets;

    // Уведомляем всех о завершении
    io.emit('marker:done', updatedMarker);

    // Уведомляем автора маркера
    const notifTitle = 'Маркер выполнен';
    const notifBody = `Маркер "${marker.title}" выполнен. Отчёт: ${report}`;
    await saveNotification(marker.user_id, notifTitle, notifBody);

    if (marker.fcm_token) {
      await sendPushNotification(marker.fcm_token, notifTitle, notifBody, {
        markerId: String(id),
        type: 'marker_done',
      });
    }

    const authorSocketId = userSockets.get(String(marker.user_id));
    if (authorSocketId) {
      io.to(authorSocketId).emit('notification:new', { title: notifTitle, body: notifBody });
    }

    // Уведомляем всех администраторов
    const adminsResult = await pool.query(
      `SELECT id FROM users WHERE role = 'admin' AND id != $1`,
      [userId]
    );
    for (const admin of adminsResult.rows) {
      const adminSocketId = userSockets.get(String(admin.id));
      if (adminSocketId) {
        io.to(adminSocketId).emit('marker:done', updatedMarker);
      }
    }

    return res.json({ message: 'Маркер выполнен', marker: updatedMarker });
  } catch (error) {
    console.error('Ошибка завершения маркера:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

// ========== ОТКАЗАТЬСЯ ОТ МАРКЕРА ==========

/**
 * PUT /markers/:id/abandon
 * Отказаться от взятого маркера (вернуть в статус pending).
 * Только тот, кто взял маркер (или admin).
 *
 * Body: { reason: string }
 */
router.put('/:id/abandon', async (req, res) => {
  try {
    const { id } = req.params;
    const { reason } = req.body;
    const userId = req.user.id;
    const userName = req.user.name;

    if (!reason || reason.trim() === '') {
      return res.status(400).json({ error: 'Причина отказа обязательна' });
    }

    const markerResult = await pool.query(
      `SELECT m.*, u.name AS user_name, u.fcm_token
       FROM markers m
       LEFT JOIN users u ON m.user_id = u.id
       WHERE m.id = $1`,
      [id]
    );

    if (markerResult.rows.length === 0) {
      return res.status(404).json({ error: 'Маркер не найден' });
    }

    const marker = markerResult.rows[0];

    if (String(marker.accepted_by) !== String(userId) && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Только исполнитель или администратор может отказаться от маркера' });
    }

    if (marker.status !== 'accepted') {
      return res.status(400).json({ error: 'Можно отказаться только от взятого маркера' });
    }

    // Возвращаем маркер в pending, убираем accepted_by
    const updateResult = await pool.query(
      `UPDATE markers
       SET status = 'pending', accepted_by = NULL, reject_reason = $2
       WHERE id = $1
       RETURNING id, latitude, longitude, title, description, color, status,
                 reject_reason, created_at, user_id`,
      [id, reason]
    );

    const updatedMarker = {
      ...updateResult.rows[0],
      user_name: marker.user_name,
    };

    // История
    await recordHistory(id, userId, 'abandoned', `${userName} отказался: ${reason}`);

    const io = req.app.locals.io;
    const userSockets = req.app.locals.userSockets;

    // Маркер возвращается на карту всем
    io.emit('marker:abandoned', updatedMarker);

    // Уведомляем автора
    const notifTitle = 'Маркер вернулся в ожидание';
    const notifBody = `Исполнитель отказался от маркера "${marker.title}". Причина: ${reason}`;
    await saveNotification(marker.user_id, notifTitle, notifBody);

    if (marker.fcm_token) {
      await sendPushNotification(marker.fcm_token, notifTitle, notifBody, {
        markerId: String(id),
        type: 'marker_abandoned',
      });
    }

    const authorSocketId = userSockets.get(String(marker.user_id));
    if (authorSocketId) {
      io.to(authorSocketId).emit('notification:new', { title: notifTitle, body: notifBody });
    }

    return res.json({ message: 'Маркер возвращён в ожидание', marker: updatedMarker });
  } catch (error) {
    console.error('Ошибка отказа от маркера:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

// ========== УДАЛИТЬ МАРКЕР ==========

/**
 * DELETE /markers/:id
 * Удалить маркер полностью (только admin).
 * Удаляет историю действий и сам маркер, уведомляет всех через socket.
 */
router.delete('/:id', async (req, res) => {
  try {
    if (req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Только администратор может удалять маркеры' });
    }

    const { id } = req.params;

    const markerResult = await pool.query('SELECT id, title FROM markers WHERE id = $1', [id]);
    if (markerResult.rows.length === 0) {
      return res.status(404).json({ error: 'Маркер не найден' });
    }

    // Удаляем историю (FK), затем маркер
    await pool.query('DELETE FROM marker_history WHERE marker_id = $1', [id]);
    await pool.query('DELETE FROM markers WHERE id = $1', [id]);

    const io = req.app.locals.io;
    io.emit('marker:deleted', { id: parseInt(id) });

    return res.json({ message: 'Маркер удалён' });
  } catch (error) {
    console.error('Ошибка удаления маркера:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

module.exports = router;
