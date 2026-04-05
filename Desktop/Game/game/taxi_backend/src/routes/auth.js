// Роут авторизации: вход по телефону и паролю
const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const pool = require('../config/database');

const router = express.Router();

/**
 * POST /auth/login
 * Вход пользователя по номеру телефона и паролю.
 * Возвращает JWT токен и данные пользователя.
 *
 * Body: { phone: string, password: string }
 */
router.post('/login', async (req, res) => {
  try {
    const { phone, password } = req.body;

    // Валидация входных данных
    if (!phone || !password) {
      return res.status(400).json({ error: 'Телефон и пароль обязательны' });
    }

    // Ищем пользователя по номеру телефона
    const result = await pool.query(
      'SELECT id, phone, name, password_hash, role, is_active, fcm_token FROM users WHERE phone = $1',
      [phone]
    );

    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'Неверный телефон или пароль' });
    }

    const user = result.rows[0];

    // Проверяем, не заблокирован ли пользователь
    if (!user.is_active) {
      return res.status(403).json({ error: 'Ваш аккаунт заблокирован. Обратитесь к администратору' });
    }

    // Проверяем правильность пароля
    const isPasswordValid = await bcrypt.compare(password, user.password_hash);
    if (!isPasswordValid) {
      return res.status(401).json({ error: 'Неверный телефон или пароль' });
    }

    // Создаём JWT токен
    const token = jwt.sign(
      {
        id: user.id,
        phone: user.phone,
        name: user.name,
        role: user.role,
      },
      process.env.JWT_SECRET,
      { expiresIn: '7d' } // Токен действителен 7 дней
    );

    // Возвращаем токен и данные пользователя (без хэша пароля)
    return res.json({
      token,
      user: {
        id: user.id,
        phone: user.phone,
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
 * Обновляет FCM токен пользователя для push-уведомлений.
 * Вызывается мобильным приложением после входа.
 *
 * Body: { userId: number, fcmToken: string }
 * Headers: Authorization: Bearer <token>
 */
router.post('/update-fcm-token', require('../middleware/auth').authenticateToken, async (req, res) => {
  try {
    const { fcmToken } = req.body;
    const userId = req.user.id;

    if (!fcmToken) {
      return res.status(400).json({ error: 'FCM токен обязателен' });
    }

    // Обновляем FCM токен в базе данных
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
 * Обновляет профиль текущего пользователя (имя, телефон, пароль).
 *
 * Body: { name?, phone?, password? }
 * Headers: Authorization: Bearer <token>
 */
router.put('/profile', require('../middleware/auth').authenticateToken, async (req, res) => {
  try {
    const { name, phone, password } = req.body;
    const userId = req.user.id;

    const updates = [];
    const params = [];

    if (name && name.trim()) {
      updates.push(`name = $${params.length + 1}`);
      params.push(name.trim());
    }

    if (phone && phone.trim()) {
      const phoneCheck = await pool.query(
        'SELECT id FROM users WHERE phone = $1 AND id != $2',
        [phone.trim(), userId]
      );
      if (phoneCheck.rows.length > 0) {
        return res.status(400).json({ error: 'Этот телефон уже используется' });
      }
      updates.push(`phone = $${params.length + 1}`);
      params.push(phone.trim());
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
      `UPDATE users SET ${updates.join(', ')} WHERE id = $${params.length} RETURNING id, phone, name, role`,
      params
    );

    return res.json({ user: result.rows[0] });
  } catch (error) {
    console.error('Ошибка обновления профиля:', error);
    return res.status(500).json({ error: 'Внутренняя ошибка сервера' });
  }
});

module.exports = router;
