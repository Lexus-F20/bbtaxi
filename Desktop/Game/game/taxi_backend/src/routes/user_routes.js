// Роуты для пользовательских маршрутов (линии на карте)
const express = require('express');
const pool = require('../config/database');

const router = express.Router();

/**
 * POST /routes
 * Сохранить нарисованный маршрут.
 * Body: { points: [{lat, lng}, ...], title? }
 */
router.post('/', async (req, res) => {
  try {
    const { points, title, color } = req.body;
    const userId = req.user.id;
    const userName = req.user.name;

    if (!Array.isArray(points) || points.length < 2) {
      return res.status(400).json({ error: 'Маршрут должен содержать минимум 2 точки' });
    }

    const routeColor = color || 'blue';

    const result = await pool.query(
      `INSERT INTO routes (user_id, title, points, color)
       VALUES ($1, $2, $3::jsonb, $4)
       RETURNING id, user_id, title, points, color, created_at`,
      [userId, title || null, JSON.stringify(points), routeColor]
    );

    const route = { ...result.rows[0], user_name: userName };

    const io = req.app.locals.io;
    io.emit('route:new', route);

    return res.status(201).json({ message: 'Маршрут сохранён', route });
  } catch (error) {
    console.error('Ошибка создания маршрута:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * GET /routes
 * Получить все маршруты.
 */
router.get('/', async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT r.id, r.user_id, r.title, r.points, r.color, r.created_at,
              u.name AS user_name
       FROM routes r
       LEFT JOIN users u ON r.user_id = u.id
       ORDER BY r.created_at DESC`
    );
    return res.json({ routes: result.rows });
  } catch (error) {
    console.error('Ошибка получения маршрутов:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * DELETE /routes/:id
 * Удалить маршрут (только свой или admin).
 */
router.delete('/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const userId = req.user.id;
    const userRole = req.user.role;

    const check = await pool.query('SELECT user_id FROM routes WHERE id = $1', [id]);
    if (check.rows.length === 0) {
      return res.status(404).json({ error: 'Маршрут не найден' });
    }

    if (String(check.rows[0].user_id) !== String(userId) && userRole !== 'admin') {
      return res.status(403).json({ error: 'Нельзя удалить чужой маршрут' });
    }

    await pool.query('DELETE FROM routes WHERE id = $1', [id]);

    const io = req.app.locals.io;
    io.emit('route:deleted', { id: parseInt(id) });

    return res.json({ message: 'Маршрут удалён' });
  } catch (error) {
    console.error('Ошибка удаления маршрута:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

module.exports = router;
