package dev.zhaoyilun.dsh_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 前台保活服务:App 进入后台后仍持有前台服务,Android 不会把进程当作
 * 普通缓存进程随手回收;WebView 里的 WebSocket 与 DshNotify 通知桥
 * 因此可以继续工作,审批/任务完成能及时进入系统通知栏。
 *
 * 服务本身不持有业务连接;连接仍由 HomePage 的 WebView 维护。用户从
 * 最近任务划掉 Activity 后服务会随 Activity onDestroy 停止,避免留下
 * 一个没有连接的僵尸前台通知。
 */
class DshKeepAliveService : Service() {
    companion object {
        const val ACTION_START = "dev.zhaoyilun.dsh_mobile.action.KEEP_ALIVE_START"
        const val CHANNEL_ID = "dsh_keepalive"
        const val CHANNEL_NAME = "DSH 连接保持"
        const val NOTIFICATION_ID = 1001
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }

        val openApp = Intent(this, MainActivity::class.java)
        openApp.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(
            this,
            0,
            openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setPriority(Notification.PRIORITY_LOW)
        }

        val notification = builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("DSH 保持连接中")
            .setContentText("审批与任务完成通知不会错过;点按回到 DSH")
            .setOngoing(true)
            .setContentIntent(pending)
            .build()

        startForeground(NOTIFICATION_ID, notification)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}
