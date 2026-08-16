package dev.zhaoyilun.dsh_mobile

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

/**
 * DSH 原生壳:
 *  - 允许系统截图与录屏(不再设置 FLAG_SECURE)。
 *  - 提供通知 MethodChannel,让 Web 端的审批/提问/任务完成事件
 *    进入 Android 系统通知栏;点击通知回到 App。
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "dev.zhaoyilun.dsh_mobile/notifications"
        private const val NOTIFICATION_CHANNEL_ID = "dsh_events"
        private const val NOTIFICATION_CHANNEL_NAME = "DSH 通知"
        private const val PERMISSION_REQUEST_CODE = 4101
        private const val EXTRA_SESSION_ID = "dsh_session_id"
        private const val PREFS_NAME = "dsh_notifications"
        private const val PREF_PERMISSION_ASKED = "permission_asked"
        private val notificationSeq = AtomicInteger(0)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> requestNotificationPermission(result)
                "show" -> showNotification(call.argument("title"), call.argument("body"), call.argument("sessionId"), result)
                else -> result.notImplemented()
            }
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        // Android 13+ 才需要运行时通知权限;低版本默认允许。只在首次启动时
        // 询问一次,用户拒绝后不再反复弹窗(可到系统设置里手动打开)。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            if (!prefs.getBoolean(PREF_PERMISSION_ASKED, false)) {
                prefs.edit().putBoolean(PREF_PERMISSION_ASKED, true).apply()
                requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    PERMISSION_REQUEST_CODE,
                )
            }
        }
        result.success(true)
    }

    private fun showNotification(
        title: String?,
        body: String?,
        sessionId: String?,
        result: MethodChannel.Result,
    ) {
        if (title.isNullOrBlank() || body.isNullOrBlank()) {
            result.success(false)
            return
        }

        // Android 13+ 未授权时保持静默失败;权限询问只在 App 启动时发生一次,
        // 这里不再重复弹窗,避免每次任务完成都打断用户。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            result.success(false)
            return
        }

        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    NOTIFICATION_CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setPriority(Notification.PRIORITY_DEFAULT)
        }

        val sessionKey = sessionId ?: "general"
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_SESSION_ID, sessionId)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            sessionKey.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        builder.setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)

        manager.notify(notificationSeq.incrementAndGet(), builder.build())
        result.success(true)
    }
}
