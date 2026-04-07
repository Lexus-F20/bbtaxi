// Маршрут для загрузки файлов в Firebase Storage через Admin SDK
const express = require('express');
const multer = require('multer');
const path = require('path');
const { randomUUID } = require('crypto');
const admin = require('../config/firebase');

const router = express.Router();

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 150 * 1024 * 1024 }, // 150 МБ (для видео)
});

// Сохранение в Firebase Storage с таймаутом 30 секунд
function saveWithTimeout(fileRef, buffer, options, timeoutMs = 30000) {
  return Promise.race([
    fileRef.save(buffer, options),
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('Firebase Storage timeout (30s)')), timeoutMs)
    ),
  ]);
}

/**
 * POST /upload
 * Загружает файл в Firebase Storage.
 * Возвращает прямой URL Firebase Storage с download-токеном —
 * не требует IAM signBlob, не зависит от Railway прокси.
 */
router.post('/', upload.single('file'), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'Файл не передан' });
    }

    const folder = (req.body.folder || 'uploads').replace(/[^a-zA-Z0-9_\-/]/g, '');
    const ext = path.extname(req.file.originalname).toLowerCase() || '.jpg';
    const fileName = `${folder}/${Date.now()}${ext}`;
    const downloadToken = randomUUID();

    console.log(`[upload] Сохранение: ${fileName} (${req.file.size} байт)`);

    const bucket = admin.storage().bucket();
    const fileRef = bucket.file(fileName);

    await saveWithTimeout(fileRef, req.file.buffer, {
      metadata: {
        contentType: req.file.mimetype,
        metadata: {
          firebaseStorageDownloadTokens: downloadToken,
        },
      },
    });

    console.log(`[upload] Сохранено в Storage: ${fileName}`);

    // Отдаём URL через наш прокси /media/* — он стримит файл через Admin SDK,
    // обходит Firebase Security Rules и App Check без каких-либо IAM-разрешений.
    const host = process.env.RAILWAY_PUBLIC_DOMAIN
      ? `https://${process.env.RAILWAY_PUBLIC_DOMAIN}`
      : `${req.protocol}://${req.get('host')}`;
    const mediaUrl = `${host}/media/${fileName}`;

    console.log(`[upload] URL: ${mediaUrl}`);

    return res.json({ url: mediaUrl });
  } catch (error) {
    console.error('[upload] Ошибка:', error.message);
    return res.status(500).json({ error: `Ошибка загрузки: ${error.message}` });
  }
});

module.exports = router;
