// Сервис для отправки push-уведомлений через Firebase Cloud Messaging (FCM)
const pool = require('../config/database');

let admin;
try {
  admin = require('../config/firebase');
} catch (e) {
  console.warn('Firebase недоступен:', e.message);
}

/**
 * Отправляет push-уведомление конкретному пользователю по его FCM токену.
 *
 * @param {string} fcmToken - FCM токен устройства
 * @param {string} title - Заголовок уведомления
 * @param {string} body - Текст уведомления
 * @param {object} data - Дополнительные данные (опционально)
 */
const sendPushNotification = async (fcmToken, title, body, data = {}) => {
  // Если Firebase не инициализирован — пропускаем
  if (!admin || !admin.apps || admin.apps.length === 0) {
    console.warn('FCM недоступен. Уведомление не отправлено:', title);
    return;
  }

  try {
    const message = {
      notification: { title, body },
      data: Object.fromEntries(
        Object.entries(data).map(([k, v]) => [k, String(v)])
      ),
      token: fcmToken,
      android: {
        notification: {
          sound: 'default',
          priority: 'high',
        },
      },
    };

    const response = await admin.messaging().send(message);
    console.log('Push-уведомление отправлено:', response);
    return response;
  } catch (error) {
    console.error('Ошибка отправки push-уведомления:', error.message);
  }
};

/**
 * Отправляет push-уведомление всем активным пользователям с FCM токенами.
 *
 * @param {string} title - Заголовок уведомления
 * @param {string} body - Текст уведомления
 * @param {object} data - Дополнительные данные (опционально)
 * @param {number|null} excludeUserId - ID пользователя, которому НЕ отправлять
 */
const sendPushToAll = async (title, body, data = {}, excludeUserId = null) => {
  try {
    // Получаем все активные FCM токены
    let query = `
      SELECT fcm_token FROM users
      WHERE fcm_token IS NOT NULL AND is_active = true
    `;
    const params = [];

    if (excludeUserId) {
      query += ' AND id != $1';
      params.push(excludeUserId);
    }

    const result = await pool.query(query, params);

    // Отправляем уведомление каждому пользователю
    const promises = result.rows.map(row =>
      sendPushNotification(row.fcm_token, title, body, data)
    );

    await Promise.allSettled(promises);
    console.log(`Push-уведомления отправлены ${result.rows.length} пользователям`);
  } catch (error) {
    console.error('Ошибка массовой отправки push-уведомлений:', error);
  }
};

/**
 * Сохраняет уведомление в базе данных для конкретного пользователя.
 *
 * @param {number} userId - ID пользователя
 * @param {string} title - Заголовок уведомления
 * @param {string} body - Текст уведомления
 */
const saveNotification = async (userId, title, body) => {
  try {
    await pool.query(
      'INSERT INTO notifications (user_id, title, body) VALUES ($1, $2, $3)',
      [userId, title, body]
    );
  } catch (error) {
    console.error('Ошибка сохранения уведомления в БД:', error);
  }
};

/**
 * Сохраняет уведомление для всех активных пользователей в базе данных.
 *
 * @param {string} title - Заголовок
 * @param {string} body - Текст
 * @param {number|null} excludeUserId - Исключить пользователя
 */
const saveNotificationForAll = async (title, body, excludeUserId = null) => {
  try {
    let query = 'SELECT id FROM users WHERE is_active = true';
    const params = [];

    if (excludeUserId) {
      query += ' AND id != $1';
      params.push(excludeUserId);
    }

    const result = await pool.query(query, params);

    const inserts = result.rows.map(row =>
      pool.query(
        'INSERT INTO notifications (user_id, title, body) VALUES ($1, $2, $3)',
        [row.id, title, body]
      )
    );

    await Promise.all(inserts);
  } catch (error) {
    console.error('Ошибка массового сохранения уведомлений:', error);
  }
};

module.exports = {
  sendPushNotification,
  sendPushToAll,
  saveNotification,
  saveNotificationForAll,
};
