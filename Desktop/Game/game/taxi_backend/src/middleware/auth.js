// Middleware для проверки JWT токена
const jwt = require('jsonwebtoken');

/**
 * Проверяет наличие и валидность JWT токена в заголовке Authorization.
 * При успехе добавляет данные пользователя в req.user.
 */
const authenticateToken = (req, res, next) => {
  // Получаем заголовок Authorization
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1]; // Формат: "Bearer <token>"

  if (!token) {
    return res.status(401).json({ error: 'Токен авторизации отсутствует' });
  }

  try {
    // Верифицируем токен
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    // Добавляем данные пользователя в запрос
    req.user = decoded;
    next();
  } catch (error) {
    if (error.name === 'TokenExpiredError') {
      return res.status(401).json({ error: 'Токен устарел, войдите снова' });
    }
    return res.status(403).json({ error: 'Недействительный токен' });
  }
};

/**
 * Проверяет, что текущий пользователь является администратором.
 * Используется после authenticateToken.
 */
const requireAdmin = (req, res, next) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ error: 'Доступ запрещён. Требуется роль администратора' });
  }
  next();
};

/**
 * Проверяет, что текущий пользователь является администратором или водителем.
 * Используется после authenticateToken.
 */
const requireAdminOrDriver = (req, res, next) => {
  if (req.user.role !== 'admin' && req.user.role !== 'driver') {
    return res.status(403).json({ error: 'Доступ запрещён. Требуется роль администратора или водителя' });
  }
  next();
};

module.exports = { authenticateToken, requireAdmin, requireAdminOrDriver };
