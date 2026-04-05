// Роут профиля пользователя — статистика и история заказов
const express = require('express');
const pool = require('../config/database');

const router = express.Router();

/**
 * GET /users/:id/profile
 * Профиль пользователя: имя, роль, рейтинг, статистика, история заказов.
 */
router.get('/:id/profile', async (req, res) => {
  try {
    const { id } = req.params;

    const userResult = await pool.query(
      'SELECT id, name, role, rating, created_at FROM users WHERE id = $1 AND is_active = true',
      [id]
    );

    if (userResult.rows.length === 0) {
      return res.status(404).json({ error: 'Пользователь не найден' });
    }

    const user = userResult.rows[0];

    // Статистика по заказам
    const statsResult = await pool.query(`
      SELECT
        COUNT(CASE WHEN accepted_by = $1 AND status = 'done' THEN 1 END)      AS completed,
        COUNT(CASE WHEN accepted_by = $1 AND status = 'abandoned' THEN 1 END) AS abandoned,
        COUNT(CASE WHEN user_id    = $1 THEN 1 END)                           AS created
      FROM markers
      WHERE accepted_by = $1 OR user_id = $1
    `, [id]);

    // История выполненных/отказных заказов как исполнитель (последние 30)
    const historyResult = await pool.query(`
      SELECT m.id, m.user_id, m.accepted_by, m.latitude, m.longitude,
             m.title, m.description, m.color, m.status,
             m.report, m.reject_reason, m.done_at, m.created_at,
             u.name AS user_name, ab.name AS accepted_by_name
      FROM markers m
      LEFT JOIN users u  ON m.user_id    = u.id
      LEFT JOIN users ab ON m.accepted_by = ab.id
      WHERE m.accepted_by = $1 AND m.status IN ('done', 'abandoned')
      ORDER BY m.created_at DESC
      LIMIT 30
    `, [id]);

    return res.json({
      user,
      stats: statsResult.rows[0],
      history: historyResult.rows,
    });
  } catch (error) {
    console.error('Ошибка получения профиля:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

module.exports = router;
