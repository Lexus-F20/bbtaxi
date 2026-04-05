// Роуты панели администратора: управление пользователями
const express = require('express');
const bcrypt = require('bcryptjs');
const pool = require('../config/database');
const { requireAdmin } = require('../middleware/auth');

const router = express.Router();

// Все роуты в этом файле требуют роли администратора
router.use(requireAdmin);

/**
 * POST /admin/users
 * Создать нового пользователя (только администратор).
 * Самостоятельная регистрация отключена — только через админ-панель.
 *
 * Body: { name, phone, password, role }
 */
router.post('/users', async (req, res) => {
  try {
    const { name, phone, password, role } = req.body;

    // Валидация обязательных полей
    if (!name || !phone || !password || !role) {
      return res.status(400).json({ error: 'Имя, телефон, пароль и роль обязательны' });
    }

    // Проверяем допустимые роли
    const allowedRoles = ['admin', 'driver', 'viewer'];
    if (!allowedRoles.includes(role)) {
      return res.status(400).json({ error: 'Роль должна быть: admin, driver или user' });
    }

    // Проверяем, не существует ли уже пользователь с таким телефоном
    const existingUser = await pool.query(
      'SELECT id FROM users WHERE phone = $1',
      [phone]
    );

    if (existingUser.rows.length > 0) {
      return res.status(409).json({ error: 'Пользователь с таким номером телефона уже существует' });
    }

    // Хэшируем пароль (соль 10 раундов)
    const passwordHash = await bcrypt.hash(password, 10);

    // Создаём пользователя в базе данных
    const result = await pool.query(
      `INSERT INTO users (name, phone, password_hash, role, is_active)
       VALUES ($1, $2, $3, $4, true)
       RETURNING id, name, phone, role, is_active, created_at`,
      [name, phone, passwordHash, role]
    );

    return res.status(201).json({
      message: 'Пользователь создан успешно',
      user: result.rows[0],
    });
  } catch (error) {
    console.error('Ошибка создания пользователя:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * GET /admin/users
 * Получить список всех пользователей.
 * Поддерживает фильтрацию по роли: ?role=driver
 */
router.get('/users', async (req, res) => {
  try {
    const { role } = req.query;

    let query = `
      SELECT id, name, phone, role, is_active, fcm_token, created_at
      FROM users
    `;
    const params = [];

    // Если передана роль — фильтруем
    if (role) {
      query += ' WHERE role = $1';
      params.push(role);
    }

    query += ' ORDER BY created_at DESC';

    const result = await pool.query(query, params);

    return res.json({ users: result.rows });
  } catch (error) {
    console.error('Ошибка получения пользователей:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * PUT /admin/users/:id
 * Редактировать пользователя (имя, телефон, роль, пароль, статус).
 *
 * Body: { name?, phone?, password?, role?, is_active? }
 */
router.put('/users/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const { name, phone, password, role, is_active } = req.body;

    // Проверяем существование пользователя
    const existingResult = await pool.query(
      'SELECT id FROM users WHERE id = $1',
      [id]
    );

    if (existingResult.rows.length === 0) {
      return res.status(404).json({ error: 'Пользователь не найден' });
    }

    // Формируем список полей для обновления
    const updateFields = [];
    const params = [];
    let paramIndex = 1;

    if (name !== undefined) {
      updateFields.push(`name = $${paramIndex++}`);
      params.push(name);
    }

    if (phone !== undefined) {
      // Проверяем, не занят ли телефон другим пользователем
      const phoneCheck = await pool.query(
        'SELECT id FROM users WHERE phone = $1 AND id != $2',
        [phone, id]
      );
      if (phoneCheck.rows.length > 0) {
        return res.status(409).json({ error: 'Этот номер телефона уже используется' });
      }
      updateFields.push(`phone = $${paramIndex++}`);
      params.push(phone);
    }

    if (password !== undefined) {
      const passwordHash = await bcrypt.hash(password, 10);
      updateFields.push(`password_hash = $${paramIndex++}`);
      params.push(passwordHash);
    }

    if (role !== undefined) {
      const allowedRoles = ['admin', 'driver', 'viewer'];
      if (!allowedRoles.includes(role)) {
        return res.status(400).json({ error: 'Недопустимая роль' });
      }
      updateFields.push(`role = $${paramIndex++}`);
      params.push(role);
    }

    if (is_active !== undefined) {
      updateFields.push(`is_active = $${paramIndex++}`);
      params.push(is_active);
    }

    if (updateFields.length === 0) {
      return res.status(400).json({ error: 'Нет полей для обновления' });
    }

    params.push(id);
    const result = await pool.query(
      `UPDATE users SET ${updateFields.join(', ')} WHERE id = $${paramIndex}
       RETURNING id, name, phone, role, is_active, created_at`,
      params
    );

    return res.json({
      message: 'Пользователь обновлён',
      user: result.rows[0],
    });
  } catch (error) {
    console.error('Ошибка обновления пользователя:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * DELETE /admin/users/:id
 * Заблокировать пользователя (устанавливает is_active = false).
 * Физическое удаление не применяется для сохранения истории.
 */
router.delete('/users/:id', async (req, res) => {
  try {
    const { id } = req.params;

    // Нельзя заблокировать самого себя
    if (String(req.user.id) === String(id)) {
      return res.status(400).json({ error: 'Нельзя заблокировать собственный аккаунт' });
    }

    const result = await pool.query(
      `UPDATE users SET is_active = false WHERE id = $1
       RETURNING id, name, phone, role, is_active`,
      [id]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Пользователь не найден' });
    }

    return res.json({
      message: 'Пользователь заблокирован',
      user: result.rows[0],
    });
  } catch (error) {
    console.error('Ошибка блокировки пользователя:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * GET /admin/markers
 * Получить все маркеры для панели администратора (с данными пользователей).
 */
router.get('/markers', async (req, res) => {
  try {
    const { status } = req.query;

    let query = `
      SELECT m.id, m.user_id, m.accepted_by, m.latitude, m.longitude, m.title, m.description,
             m.color, m.status, m.reject_reason, m.report, m.done_at, m.created_at,
             u.name AS user_name, u.phone AS user_phone,
             a.name AS accepted_by_name
      FROM markers m
      LEFT JOIN users u ON m.user_id = u.id
      LEFT JOIN users a ON m.accepted_by = a.id
    `;
    const params = [];

    if (status) {
      if (status.includes(',')) {
        query += ' WHERE m.status = ANY($1::text[])';
        params.push(status.split(','));
      } else {
        query += ' WHERE m.status = $1';
        params.push(status);
      }
    }

    query += ' ORDER BY m.created_at DESC';

    const result = await pool.query(query, params);

    return res.json({ markers: result.rows });
  } catch (error) {
    console.error('Ошибка получения маркеров (admin):', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * PUT /admin/users/:id/rating
 * Изменить рейтинг пользователя (только администратор).
 * Body: { delta: number, reason?: string }
 */
router.put('/users/:id/rating', async (req, res) => {
  try {
    const { id } = req.params;
    const { delta, reason } = req.body;

    if (delta === undefined || typeof delta !== 'number' || delta === 0) {
      return res.status(400).json({ error: 'delta обязателен (число, не ноль)' });
    }

    const result = await pool.query(
      'UPDATE users SET rating = rating + $1 WHERE id = $2 RETURNING id, name, role, rating',
      [delta, id]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Пользователь не найден' });
    }

    try {
      await pool.query(
        'INSERT INTO rating_history (user_id, changed_by, delta, reason) VALUES ($1, $2, $3, $4)',
        [id, req.user.id, delta, reason || null]
      );
    } catch (histErr) {
      console.warn('rating_history недоступна:', histErr.message);
    }

    return res.json({ message: 'Рейтинг обновлён', user: result.rows[0] });
  } catch (error) {
    console.error('Ошибка обновления рейтинга:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

module.exports = router;
