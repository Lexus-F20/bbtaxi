// Роут авторизации: вход по логину и паролю
const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const pool = require('../config/database');

const router = express.Router();

/**
 * POST /auth/login
 * Вход пользователя по логину и паролю.
 * Body: { login: string, password: string }
 */
router.post('/login', async (req, res) => {
  try {
    const { login, password } = req.body;

    if (!login || !password) {
      return res.status(400).json({ error: 'Логин и пароль обязательны' });
    }

    const result = await pool.query(
      'SELECT id, login, name, password_hash, role, is_active, fcm_token FROM users WHERE login = $1',
      [login]
    );

    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'Неверный логин или пароль' });
    }

    const user = result.rows[0];

    if (!user.is_active) {
      return res.status(403).json({ error: 'Ваш аккаунт заблокирован. Обратитесь к администратору' });
    }

    const isPasswordValid = await bcrypt.compare(password, user.password_hash);
    if (!isPasswordValid) {
      return res.status(401).json({ error: 'Неверный логин или пароль' });
    }

    const token = jwt.sign(
      {
        id: user.id,
        login: user.login,
        name: user.name,
        role: user.role,
      },
      process.env.JWT_SECRET,
      { expiresIn: '7d' }
    );

    return res.json({
      token,
      user: {
        id: user.id,
        login: user.login,
        name: user.name,
        role: user.role,
        fcmToken: user.fcm_token,
      },
    });
  } catch (error) {
    console.error('Ошибка входа:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * POST /auth/update-fcm-token
 * Body: { fcmToken: string }
 * Headers: Authorization: Bearer <token>
 */
router.post('/update-fcm-token', require('../middleware/auth').authenticateToken, async (req, res) => {
  try {
    const { fcmToken } = req.body;
    const userId = req.user.id;

    if (!fcmToken) {
      return res.status(400).json({ error: 'FCM токен обязателен' });
    }

    await pool.query(
      'UPDATE users SET fcm_token = $1 WHERE id = $2',
      [fcmToken, userId]
    );

    return res.json({ message: 'FCM токен обновлён' });
  } catch (error) {
    console.error('Ошибка обновления FCM токена:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

/**
 * PUT /auth/profile
 * Body: { name?, login?, password? }
 * Headers: Authorization: Bearer <token>
 */
router.put('/profile', require('../middleware/auth').authenticateToken, async (req, res) => {
  try {
    const { name, login, password } = req.body;
    const userId = req.user.id;

    const updates = [];
    const params = [];

    if (name && name.trim()) {
      updates.push(`name = $${params.length + 1}`);
      params.push(name.trim());
    }

    if (login && login.trim()) {
      const loginCheck = await pool.query(
        'SELECT id FROM users WHERE login = $1 AND id != $2',
        [login.trim(), userId]
      );
      if (loginCheck.rows.length > 0) {
        return res.status(400).json({ error: 'Этот логин уже используется' });
      }
      updates.push(`login = $${params.length + 1}`);
      params.push(login.trim());
    }

    if (password && password.trim()) {
      if (password.length < 4) {
        return res.status(400).json({ error: 'Пароль должен быть не менее 4 символов' });
      }
      const hash = await bcrypt.hash(password, 10);
      updates.push(`password_hash = $${params.length + 1}`);
      params.push(hash);
    }

    if (updates.length === 0) {
      return res.status(400).json({ error: 'Нет данных для обновления' });
    }

    params.push(userId);
    const result = await pool.query(
      `UPDATE users SET ${updates.join(', ')} WHERE id = $${params.length} RETURNING id, login, name, role`,
      params
    );

    return res.json({ user: result.rows[0] });
  } catch (error) {
    console.error('Ошибка обновления профиля:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

module.exports = router;
