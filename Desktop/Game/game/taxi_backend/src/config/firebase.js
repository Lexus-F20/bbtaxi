// Конфигурация Firebase Admin SDK для отправки push-уведомлений
const admin = require('firebase-admin');
const path = require('path');
require('dotenv').config();

// Инициализируем Firebase Admin только один раз
if (!admin.apps.length) {
  try {
    let serviceAccount;

    if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
      // Railway/production: JSON передаётся через переменную окружения
      serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON);
    } else {
      // Локальная разработка: читаем из файла
      const serviceAccountPath = process.env.FIREBASE_SERVICE_ACCOUNT_PATH || './firebase-service-account.json';
      serviceAccount = require(path.resolve(serviceAccountPath));
    }

    const storageBucket = process.env.FIREBASE_STORAGE_BUCKET || 'bbdron-c5dcf.firebasestorage.app';

    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
      storageBucket: storageBucket,
    });

    console.log(`Firebase Admin SDK инициализирован успешно (bucket: ${storageBucket})`);
  } catch (error) {
    console.error('Ошибка инициализации Firebase Admin SDK:', error.message);
    console.warn('Push-уведомления через FCM недоступны. Добавьте файл firebase-service-account.json');
  }
}

module.exports = admin;
