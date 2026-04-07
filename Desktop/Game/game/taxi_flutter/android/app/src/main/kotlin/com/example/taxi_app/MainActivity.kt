package com.example.taxi_app

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Environment
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private var downloadId: Long = -1L
    private var downloadReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app_updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "downloadAndInstall" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("INVALID_URL", "URL не указан", null)
                            return@setMethodCallHandler
                        }
                        downloadAndInstall(url)
                        result.success(null)
                    }
                    "installApk" -> {
                        val filePath = call.arguments as? String
                        if (filePath == null) {
                            result.error("INVALID_PATH", "Путь к файлу не указан", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(filePath)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun downloadAndInstall(url: String) {
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

        // Отменяем предыдущую загрузку если есть
        if (downloadId != -1L) dm.remove(downloadId)

        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle("BBDron — обновление")
            setDescription("Загрузка новой версии приложения...")
            // Уведомление видно во время загрузки и после завершения
            setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
            )
            // Сохраняем в папку Downloads приложения (не нужны доп. разрешения)
            setDestinationInExternalFilesDir(
                this@MainActivity,
                Environment.DIRECTORY_DOWNLOADS,
                "bbdron_update.apk"
            )
            setMimeType("application/vnd.android.package-archive")
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
        }

        downloadId = dm.enqueue(request)

        // Отписываемся от старого receiver если есть
        downloadReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }

        // Слушаем завершение загрузки → автоматически запускаем установщик
        downloadReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
                if (id != downloadId) return

                val cursor = dm.query(DownloadManager.Query().setFilterById(downloadId))
                if (cursor.moveToFirst()) {
                    val statusIdx = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
                    if (cursor.getInt(statusIdx) == DownloadManager.STATUS_SUCCESSFUL) {
                        val uriIdx = cursor.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI)
                        val localUri = cursor.getString(uriIdx)
                        val path = Uri.parse(localUri).path
                        if (path != null) {
                            try { installApk(path) } catch (e: Exception) { e.printStackTrace() }
                        }
                    }
                }
                cursor.close()
            }
        }

        ContextCompat.registerReceiver(
            this,
            downloadReceiver!!,
            IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    private fun installApk(filePath: String) {
        val file = File(filePath)
        val uri = FileProvider.getUriForFile(
            this,
            "${packageName}.provider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        downloadReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
    }
}
