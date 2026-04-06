// Маршрут для загрузки файлов в Firebase Storage через Admin SDK
const express = require('express');
const multer = require('multer');
const path = require('path');
const admin = require('../config/firebase');

const router = express.Router();

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 15 * 1024 * 1024 }, // 15 МБ
});

/**
 * POST /upload
 * Загружает файл в Firebase Storage и возвращает URL для скачивания.
 *
 * Multipart-форма:
 *   file   — файл (обязательно)
 *   folder — подпапка в Storage (по умолчанию "uploads")
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

    // Загружаем файл в Storage (без ACL — совместимо с uniform bucket-level access)
    await fileRef.save(req.file.buffer, {
      metadata: { contentType: req.file.mimetype },
    });

    // Получаем подписанный URL на 10 лет
    const [signedUrl] = await fileRef.getSignedUrl({
      action: 'read',
      expires: '01-01-2035',
    });

    return res.json({ url: signedUrl });
  } catch (error) {
    console.error('Ошибка загрузки файла:', error);
    return res.status(500).json({ error: `Ошибка загрузки: ${error.message}` });
  }
});

module.exports = router;
