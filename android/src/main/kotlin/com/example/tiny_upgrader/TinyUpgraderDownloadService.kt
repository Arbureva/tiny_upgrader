package com.example.tiny_upgrader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

internal data class ForegroundDownloadTask(
    val sessionId: Int,
    val url: String,
    val savePath: String,
    val headers: Map<String, String>,
    val expectedSize: Long,
    val expectedHash: String,
    val hashAlgorithm: String,
    val maxNetworkRetryCount: Int,
    val maxValidationRetryCount: Int,
    val minFreeSpaceMarginBytes: Long,
) {
    fun toJson(): String {
        val headersJson = JSONObject()
        headers.forEach { (key, value) -> headersJson.put(key, value) }
        return JSONObject()
            .put("sessionId", sessionId)
            .put("url", url)
            .put("savePath", savePath)
            .put("headers", headersJson)
            .put("expectedSize", expectedSize)
            .put("expectedHash", expectedHash)
            .put("hashAlgorithm", hashAlgorithm)
            .put("maxNetworkRetryCount", maxNetworkRetryCount)
            .put("maxValidationRetryCount", maxValidationRetryCount)
            .put("minFreeSpaceMarginBytes", minFreeSpaceMarginBytes)
            .toString()
    }

    companion object {
        fun fromJson(value: String): ForegroundDownloadTask {
            val json = JSONObject(value)
            val headersJson = json.optJSONObject("headers") ?: JSONObject()
            val headers = mutableMapOf<String, String>()
            headersJson.keys().forEach { key ->
                headers[key] = headersJson.getString(key)
            }
            return ForegroundDownloadTask(
                sessionId = json.getInt("sessionId"),
                url = json.getString("url"),
                savePath = json.getString("savePath"),
                headers = headers,
                expectedSize = json.optLong("expectedSize", 0L),
                expectedHash = json.optString("expectedHash", ""),
                hashAlgorithm = json.optString("hashAlgorithm", "md5"),
                maxNetworkRetryCount = json.optInt("maxNetworkRetryCount", 2),
                maxValidationRetryCount = json.optInt("maxValidationRetryCount", 3),
                minFreeSpaceMarginBytes = json.optLong(
                    "minFreeSpaceMarginBytes",
                    64L * 1024L * 1024L,
                ),
            )
        }

        fun fromArguments(arguments: Map<*, *>): ForegroundDownloadTask {
            val rawHeaders = arguments["headers"] as? Map<*, *> ?: emptyMap<Any, Any>()
            val headers = rawHeaders.entries.associate { (key, value) ->
                key.toString() to value.toString()
            }
            return ForegroundDownloadTask(
                sessionId = (arguments["sessionId"] as Number).toInt(),
                url = arguments["url"] as String,
                savePath = arguments["savePath"] as String,
                headers = headers,
                expectedSize = (arguments["expectedSize"] as? Number)?.toLong() ?: 0L,
                expectedHash = arguments["expectedHash"] as? String ?: "",
                hashAlgorithm = arguments["hashAlgorithm"] as? String ?: "md5",
                maxNetworkRetryCount =
                    (arguments["maxNetworkRetryCount"] as? Number)?.toInt() ?: 2,
                maxValidationRetryCount =
                    (arguments["maxValidationRetryCount"] as? Number)?.toInt() ?: 3,
                minFreeSpaceMarginBytes =
                    (arguments["minFreeSpaceMarginBytes"] as? Number)?.toLong()
                        ?: 64L * 1024L * 1024L,
            )
        }
    }
}

internal object ForegroundDownloadStore {
    private const val PREFS = "tiny_upgrader_foreground_download"
    private const val KEY_TASK = "task"
    private const val KEY_STATE = "state"
    private const val KEY_DOWNLOADED = "downloaded"
    private const val KEY_TOTAL = "total"
    private const val KEY_CODE = "code"
    private const val KEY_MESSAGE = "message"

    fun saveTask(context: Context, task: ForegroundDownloadTask) {
        prefs(context).edit().putString(KEY_TASK, task.toJson()).apply()
    }

    fun loadTask(context: Context): ForegroundDownloadTask? {
        val json = prefs(context).getString(KEY_TASK, null) ?: return null
        return try {
            ForegroundDownloadTask.fromJson(json)
        } catch (_: Exception) {
            null
        }
    }

    fun saveState(
        context: Context,
        state: String,
        downloaded: Long,
        total: Long,
        code: String? = null,
        message: String? = null,
    ) {
        prefs(context).edit()
            .putString(KEY_STATE, state)
            .putLong(KEY_DOWNLOADED, downloaded)
            .putLong(KEY_TOTAL, total)
            .putString(KEY_CODE, code)
            .putString(KEY_MESSAGE, message)
            .apply()
    }

    fun stateMap(context: Context): Map<String, Any?> {
        val preferences = prefs(context)
        val task = loadTask(context)
        return mapOf(
            "type" to "state",
            "state" to (preferences.getString(KEY_STATE, "none") ?: "none"),
            "sessionId" to task?.sessionId,
            "savePath" to task?.savePath,
            "downloadedBytes" to preferences.getLong(KEY_DOWNLOADED, 0L),
            "totalBytes" to preferences.getLong(KEY_TOTAL, 0L),
            "code" to preferences.getString(KEY_CODE, null),
            "message" to preferences.getString(KEY_MESSAGE, null),
        )
    }

    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

class TinyUpgraderDownloadService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private val generation = AtomicInteger(0)

    @Volatile
    private var activeConnection: HttpURLConnection? = null

    @Volatile
    private var requestedStop: String? = null

    private var lastNotificationAt = 0L
    private var lastNotificationPercent = -1

    override fun onCreate() {
        super.onCreate()
        activeInstance = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> pauseCurrentTask()
            ACTION_CANCEL -> cancelCurrentTask(
                deleteFile = intent.getBooleanExtra(EXTRA_DELETE_FILE, true),
            )
            ACTION_START -> {
                val taskJson = intent.getStringExtra(EXTRA_TASK)
                if (taskJson == null) {
                    failWithoutTask("INVALID_TASK", "Missing foreground download task.")
                } else {
                    try {
                        startTask(ForegroundDownloadTask.fromJson(taskJson))
                    } catch (error: Exception) {
                        failWithoutTask(
                            "INVALID_TASK",
                            error.message ?: "Invalid foreground download task.",
                        )
                    }
                }
            }
            else -> {
                val task = ForegroundDownloadStore.loadTask(this)
                val state = ForegroundDownloadStore.stateMap(this)["state"]
                if (task != null && state == "downloading") {
                    startTask(task)
                } else {
                    stopSelf()
                }
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        activeConnection?.disconnect()
        executor.shutdownNow()
        if (activeInstance === this) activeInstance = null
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        pauseCurrentTask(
            code = "FOREGROUND_SERVICE_TIMEOUT",
            message = "Android stopped the data sync foreground service.",
        )
    }

    private fun startTask(task: ForegroundDownloadTask) {
        val token = generation.incrementAndGet()
        requestedStop = null
        activeConnection?.disconnect()
        ForegroundDownloadStore.saveTask(this, task)

        val file = File(task.savePath)
        val downloaded = if (file.isFile) file.length() else 0L
        val total = if (task.expectedSize > 0) task.expectedSize else 0L
        startForegroundNotification(task, downloaded, total)
        emit(task, "state", "downloading", downloaded, total)

        executor.execute {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "$packageName:tiny_upgrader_download",
            )
            wakeLock.acquire(MAX_WAKE_LOCK_MILLIS)
            try {
                runTask(task, token)
            } finally {
                if (wakeLock.isHeld) wakeLock.release()
            }
        }
    }

    private fun runTask(task: ForegroundDownloadTask, token: Int) {
        val engine = ForegroundHttpDownloadEngine(
            isActive = { isActive(token) },
            listener = object : ForegroundHttpDownloadEngine.Listener {
                override fun onProgress(
                    downloaded: Long,
                    total: Long,
                    networkRetry: Int,
                    validationRetry: Int,
                ) {
                    emit(
                        task,
                        "progress",
                        "downloading",
                        downloaded,
                        total,
                        networkRetry = networkRetry,
                        validationRetry = validationRetry,
                    )
                }

                override fun onRetry(
                    code: String,
                    message: String?,
                    downloaded: Long,
                    networkRetry: Int,
                    validationRetry: Int,
                ) {
                    emit(
                        task,
                        "retry",
                        "downloading",
                        downloaded,
                        task.expectedSize,
                        code = code,
                        message = message,
                        networkRetry = networkRetry,
                        validationRetry = validationRetry,
                    )
                }

                override fun onRangeReset() {
                    emit(
                        task,
                        "rangeReset",
                        "downloading",
                        0,
                        task.expectedSize,
                        code = "RANGE_IGNORED",
                        message = "Server returned 200; restarting from byte zero.",
                    )
                }

                override fun onValidation(fileSize: Long) {
                    emit(
                        task,
                        "validation",
                        "downloading",
                        fileSize,
                        if (task.expectedSize > 0) task.expectedSize else fileSize,
                    )
                }
            },
            connectionChanged = { activeConnection = it },
        )
        try {
            val size = engine.execute(task)
            if (isActive(token)) finishSuccessfully(task, size)
        } catch (_: EngineCancelled) {
            return
        } catch (error: EngineFinalFailure) {
            if (isActive(token)) {
                finishWithError(task, error.code, error.message ?: error.code)
            }
        }
    }

    private fun finishSuccessfully(task: ForegroundDownloadTask, size: Long) {
        emit(task, "finished", "finished", size, size)
        showTerminalNotification("更新包下载完成", "返回应用即可安装", success = true)
        detachForegroundAndStop()
    }

    private fun finishWithError(task: ForegroundDownloadTask, code: String, message: String) {
        val file = File(task.savePath)
        emit(
            task,
            "error",
            "error",
            if (file.isFile) file.length() else 0L,
            task.expectedSize,
            code = code,
            message = message,
        )
        showTerminalNotification("更新包下载失败", message, success = false)
        detachForegroundAndStop()
    }

    private fun pauseCurrentTask(code: String? = null, message: String? = null) {
        requestedStop = "paused"
        generation.incrementAndGet()
        activeConnection?.disconnect()
        val task = ForegroundDownloadStore.loadTask(this)
        if (task != null) {
            val file = File(task.savePath)
            emit(
                task,
                "paused",
                "paused",
                if (file.isFile) file.length() else 0L,
                task.expectedSize,
                code = code,
                message = message,
            )
        }
        stopForegroundCompat(remove = true)
        stopSelf()
    }

    private fun cancelCurrentTask(deleteFile: Boolean) {
        requestedStop = "cancelled"
        generation.incrementAndGet()
        activeConnection?.disconnect()
        val task = ForegroundDownloadStore.loadTask(this)
        if (task != null) {
            if (deleteFile) File(task.savePath).delete()
            emit(task, "cancelled", "none", 0, 0)
        }
        ForegroundDownloadStore.clear(this)
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(NOTIFICATION_ID)
        stopForegroundCompat(remove = true)
        stopSelf()
    }

    private fun isActive(token: Int): Boolean =
        generation.get() == token && requestedStop == null

    private fun emit(
        task: ForegroundDownloadTask,
        type: String,
        state: String,
        downloaded: Long,
        total: Long,
        code: String? = null,
        message: String? = null,
        networkRetry: Int = 0,
        validationRetry: Int = 0,
    ) {
        ForegroundDownloadStore.saveState(this, state, downloaded, total, code, message)
        val intent = Intent(ACTION_EVENT)
            .setPackage(packageName)
            .putExtra("type", type)
            .putExtra("state", state)
            .putExtra("sessionId", task.sessionId)
            .putExtra("savePath", task.savePath)
            .putExtra("downloadedBytes", downloaded)
            .putExtra("totalBytes", total)
            .putExtra("networkRetryCount", networkRetry)
            .putExtra("validationRetryCount", validationRetry)
        if (code != null) intent.putExtra("code", code)
        if (message != null) intent.putExtra("message", message)
        sendBroadcast(intent)

        if (state == "downloading") {
            updateNotification(task, downloaded, total)
        }
    }

    private fun startForegroundNotification(
        task: ForegroundDownloadTask,
        downloaded: Long,
        total: Long,
    ) {
        lastNotificationAt = System.currentTimeMillis()
        lastNotificationPercent = progressPercent(downloaded, total)
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildProgressNotification(task, downloaded, total),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            },
        )
    }

    private fun updateNotification(
        task: ForegroundDownloadTask,
        downloaded: Long,
        total: Long,
    ) {
        val now = System.currentTimeMillis()
        val percent = progressPercent(downloaded, total)
        if (percent < 100 &&
            (now - lastNotificationAt < NOTIFICATION_INTERVAL_MILLIS ||
                percent == lastNotificationPercent)
        ) {
            return
        }
        lastNotificationAt = now
        lastNotificationPercent = percent
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(
            NOTIFICATION_ID,
            buildProgressNotification(task, downloaded, total),
        )
    }

    private fun buildProgressNotification(
        task: ForegroundDownloadTask,
        downloaded: Long,
        total: Long,
    ): Notification {
        val pauseIntent = Intent(this, TinyUpgraderDownloadService::class.java)
            .setAction(ACTION_PAUSE)
        val pausePendingIntent = PendingIntent.getService(
            this,
            2,
            pauseIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val percent = progressPercent(downloaded, total)
        return baseNotificationBuilder()
            .setContentTitle("正在下载应用更新")
            .setContentText(if (total > 0) "$percent%" else "正在下载…")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, percent, total <= 0)
            .addAction(android.R.drawable.ic_media_pause, "暂停", pausePendingIntent)
            .build()
    }

    private fun progressPercent(downloaded: Long, total: Long): Int =
        if (total > 0) {
            ((downloaded * 100) / total).coerceIn(0L, 100L).toInt()
        } else {
            0
        }

    private fun showTerminalNotification(title: String, message: String, success: Boolean) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(
            NOTIFICATION_ID,
            baseNotificationBuilder()
                .setContentTitle(title)
                .setContentText(message)
                .setOngoing(false)
                .setAutoCancel(true)
                .setProgress(0, 0, false)
                .setSmallIcon(
                    if (success) android.R.drawable.stat_sys_download_done
                    else android.R.drawable.stat_notify_error,
                )
                .build(),
        )
    }

    private fun baseNotificationBuilder(): NotificationCompat.Builder {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                1,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, notificationChannelId())
            .setSmallIcon(
                if (applicationInfo.icon != 0) {
                    applicationInfo.icon
                } else {
                    android.R.drawable.stat_sys_download
                },
            )
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(contentIntent)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                notificationChannelId(),
                "应用更新下载",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "显示 TinyUpgrader 更新包下载进度"
                setShowBadge(false)
            },
        )
    }

    private fun notificationChannelId() = "$packageName.tiny_upgrader.download"

    private fun detachForegroundAndStop() {
        stopForegroundCompat(remove = false)
        stopSelf()
    }

    private fun stopForegroundCompat(remove: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(
                if (remove) STOP_FOREGROUND_REMOVE else STOP_FOREGROUND_DETACH,
            )
        } else {
            @Suppress("DEPRECATION")
            stopForeground(remove)
        }
    }

    private fun failWithoutTask(code: String, message: String) {
        ForegroundDownloadStore.saveState(this, "error", 0, 0, code, message)
        stopSelf()
    }

    companion object {
        const val ACTION_EVENT = "com.example.tiny_upgrader.DOWNLOAD_EVENT"
        private const val ACTION_START = "com.example.tiny_upgrader.action.START"
        private const val ACTION_PAUSE = "com.example.tiny_upgrader.action.PAUSE"
        private const val ACTION_CANCEL = "com.example.tiny_upgrader.action.CANCEL"
        private const val EXTRA_TASK = "task"
        private const val EXTRA_DELETE_FILE = "deleteFile"
        private const val NOTIFICATION_ID = 0x7547
        private const val NOTIFICATION_INTERVAL_MILLIS = 1_000L
        private const val MAX_WAKE_LOCK_MILLIS = 6 * 60 * 60 * 1000L

        @Volatile
        private var activeInstance: TinyUpgraderDownloadService? = null

        fun start(context: Context, arguments: Map<*, *>) {
            val task = ForegroundDownloadTask.fromArguments(arguments)
            val intent = Intent(context, TinyUpgraderDownloadService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_TASK, task.toJson())
            ContextCompat.startForegroundService(context, intent)
        }

        fun resumeIfNeeded(context: Context) {
            if (activeInstance != null) return
            val state = ForegroundDownloadStore.stateMap(context)["state"]
            val task = ForegroundDownloadStore.loadTask(context)
            if (state != "downloading" || task == null) return
            val intent = Intent(context, TinyUpgraderDownloadService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_TASK, task.toJson())
            ContextCompat.startForegroundService(context, intent)
        }

        fun pause(context: Context) {
            val service = activeInstance
            if (service != null) {
                service.pauseCurrentTask()
                return
            }
            val task = ForegroundDownloadStore.loadTask(context) ?: return
            val file = File(task.savePath)
            ForegroundDownloadStore.saveState(
                context,
                "paused",
                if (file.isFile) file.length() else 0L,
                task.expectedSize,
            )
        }

        fun cancel(context: Context, deleteFile: Boolean) {
            val service = activeInstance
            if (service != null) {
                service.cancelCurrentTask(deleteFile)
                return
            }
            val task = ForegroundDownloadStore.loadTask(context)
            if (deleteFile && task != null) File(task.savePath).delete()
            ForegroundDownloadStore.clear(context)
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(NOTIFICATION_ID)
        }
    }

}
