// Маршрут для загрузки файлов в Firebase Storage через Admin SDK
const express = require('express');
const multer = require('multer');
const path = require('path');
const crypto = require('crypto');
const admin = require('../config/firebase');

const router = express.Router();

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 150 * 1024 * 1024 }, // 150 МБ (для видео)
});

/**
 * POST /upload
 * Загружает файл в Firebase Storage и возвращает URL для скачивания.
 *
 * Multipart-форма:
 *   file   — файл (обязательно)
 *   folder — подпапка в Storage (по умолчанию "uploads")
 *
 * Использует Firebase download token вместо getSignedUrl — не требует
 * разрешения iam.serviceAccounts.signBlob (которого нет на Railway).
 * URL формируется так же как Firebase Client SDK.
 */
router.post('/', upload.single('file'), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'Файл не передан' });
    }

    const folder = (req.body.folder || 'uploads').replace(/[^a-zA-Z0-9_\-/]/g, '');
    const ext = path.extname(req.file.originalname).toLowerCase() || '.jpg';
    const fileName = `${folder}/${Date.now()}${ext}`;

    const bucket = admin.storage().bucket();
    const fileRef = bucket.file(fileName);

    // Генерируем download token — как делает Firebase Client SDK
    const downloadToken = crypto.randomUUID();

    // Загружаем файл с токеном в metadata
    await fileRef.save(req.file.buffer, {
      metadata: {
        contentType: req.file.mimetype,
        metadata: {
          firebaseStorageDownloadTokens: downloadToken,
        },
      },
    });

    // Формируем публичный URL с токеном (не требует signBlob)
    const bucketName = bucket.name;
    const encodedPath = encodeURIComponent(fileName);
    const downloadUrl = `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/${encodedPath}?alt=media&token=${downloadToken}`;

    return res.json({ url: downloadUrl });
  } catch (error) {
    console.error('Ошибка загрузки файла:', error);
    return res.status(500).json({ error: `Ошибка загрузки: ${error.message}` });
  }
});

module.exports = router;
