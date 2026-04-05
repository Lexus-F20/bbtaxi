// Роут таблицы рейтинга — публичная (но с авторизацией)
const express = require('express');
const pool = require('../config/database');

const router = express.Router();

/**
 * GET /ratings
 * Публичная таблица рейтинга всех активных пользователей.
 */
router.get('/', async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT u.id, u.name, u.role, u.rating,
             COUNT(m.id) FILTER (WHERE m.status = 'done') AS completed_orders
      FROM users u
      LEFT JOIN markers m ON m.accepted_by = u.id
      WHERE u.is_active = true
      GROUP BY u.id, u.name, u.role, u.rating
      ORDER BY u.rating DESC, completed_orders DESC
    `);
    return res.json({ ratings: result.rows });
  } catch (error) {
    console.error('Ошибка получения рейтинга:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

module.exports = router;
