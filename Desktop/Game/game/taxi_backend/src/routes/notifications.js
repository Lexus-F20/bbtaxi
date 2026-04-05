// Роуты для работы с уведомлениями пользователя
const express = require('express');
const pool = require('../config/database');

const router = express.Router();

/**
 * GET /notifications
 * Получить список уведомлений текущего пользователя.
 * Возвращает все уведомления, сначала непрочитанные.
 */
router.get('/', async (req, res) => {
  try {
    const userId = req.user.id;

    const result = await pool.query(
      `SELECT id, title, body, is_read, created_at
       FROM notifications
       WHERE user_id = $1
       ORDER BY is_read ASC, created_at DESC`,
      [userId]
    );

    // Подсчитываем количество непрочитанных уведомлений
    const unreadCount = result.rows.filter(n => !n.is_read).length;

    return res.json({
      notifications: result.rows,
      unreadCount,
    });
  } catch (error) {
    console.error('Ошибка получения уведомлений:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * PUT /notifications/:id/read
 * Пометить уведомление как прочитанное.
 * Пользователь может читать только свои уведомления.
 */
router.put('/:id/read', async (req, res) => {
  try {
    const { id } = req.params;
    const userId = req.user.id;

    // Обновляем только уведомление текущего пользователя
    const result = await pool.query(
      `UPDATE notifications SET is_read = true
       WHERE id = $1 AND user_id = $2
       RETURNING id, title, body, is_read, created_at`,
      [id, userId]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Уведомление не найдено' });
    }

    return res.json({
      message: 'Уведомление прочитано',
      notification: result.rows[0],
    });
  } catch (error) {
    console.error('Ошибка обновления уведомления:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * PUT /notifications/read-all
 * Пометить все уведомления текущего пользователя как прочитанные.
 */
router.put('/read-all', async (req, res) => {
  try {
    const userId = req.user.id;

    await pool.query(
      'UPDATE notifications SET is_read = true WHERE user_id = $1 AND is_read = false',
      [userId]
    );

    return res.json({ message: 'Все уведомления прочитаны' });
  } catch (error) {
    console.error('Ошибка массового чтения уведомлений:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

module.exports = router;
