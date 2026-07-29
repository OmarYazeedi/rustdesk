package com.carriez.flutter_hbb

/**
 * Keeps the app process alive while an *outgoing* (controller) session is open.
 *
 * Without this the app has no foreground component once it leaves the screen —
 * the app switcher, a quick reply in another app, an incoming call — so Android
 * moves the process to the cached bucket and the cached-app freezer SIGSTOPs
 * every thread in it, including the Rust tokio runtime driving the connection.
 * Nothing is read or written on the socket for as long as that lasts, so the
 * peer tears the connection down, and the client's own no-data check trips the
 * moment the process thaws.
 *
 * This is unrelated to [MainService], which is the mediaProjection foreground
 * service used only when *this* device is the one being shared.
 */

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PendingIntent.FLAG_IMMUTABLE
import android.app.PendingIntent.FLAG_UPDATE_CURRENT
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

const val KEEP_ALIVE_NOTIFY_ID = 991001
private const val KEEP_ALIVE_CHANNEL_ID = "RustDeskSession"

class SessionKeepAliveService : Service() {
    companion object {
        private const val logTag = "mSessionKeepAlive"

        @Volatile
        var isRunning = false
            private set

        // Start/stop are deliberately idempotent rather than reference counted:
        // mobile runs a single session at a time, and the page's dispose() can be
        // cut short if the process is backgrounded mid-teardown. A counter that
        // missed a decrement would strand the notification forever.
        @Synchronized
        fun start(context: Context) {
            if (isRunning) return
            try {
                val intent = Intent(context, SessionKeepAliveService::class.java)
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                // Starting a foreground service throws if we somehow got here from
                // the background. Losing the keep-alive is bad but not fatal, so
                // don't take the session down with it.
                Log.e(logTag, "Failed to start keep-alive service", e)
            }
        }

        @Synchronized
        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, SessionKeepAliveService::class.java))
            } catch (e: Exception) {
                Log.e(logTag, "Failed to stop keep-alive service", e)
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startForegroundNotification()
        acquireLocks()
        isRunning = true
        Log.d(logTag, "Session keep-alive started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The session this exists for is gone if the process dies, so there is
        // nothing to restore on restart.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        releaseLocks()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: Exception) {
            Log.e(logTag, "stopForeground failed", e)
        }
        Log.d(logTag, "Session keep-alive stopped")
        super.onDestroy()
    }

    /**
     * The foreground notification is what actually keeps the process out of the
     * cached bucket; the locks below only cover screen-off and Doze on top of it.
     */
    private fun startForegroundNotification() {
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                KEEP_ALIVE_CHANNEL_ID,
                "RustDesk Remote Session",
                // Low keeps it silent and unobtrusive; it is a status row, not an alert.
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shown while a remote session is connected"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                lightColor = Color.BLUE
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
            KEEP_ALIVE_CHANNEL_ID
        } else {
            ""
        }

        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val pendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.getActivity(this, 0, intent, FLAG_UPDATE_CURRENT or FLAG_IMMUTABLE)
        } else {
            @Suppress("UnspecifiedImmutableFlag")
            PendingIntent.getActivity(this, 0, intent, FLAG_UPDATE_CURRENT)
        }

        val notification = NotificationCompat.Builder(this, channelId)
            .setOngoing(true)
            .setSmallIcon(R.mipmap.ic_stat_logo)
            .setContentTitle(DEFAULT_NOTIFY_TITLE)
            .setContentText("Remote session active - tap to return")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(pendingIntent)
            .setColor(ContextCompat.getColor(this, R.color.primary))
            .build()

        startForeground(KEEP_ALIVE_NOTIFY_ID, notification)
    }

    private fun acquireLocks() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "rustdesk:session_keep_alive"
            ).apply {
                setReferenceCounted(false)
                // Released in onDestroy; the service's lifetime is the session's.
                acquire()
            }
        } catch (e: Exception) {
            Log.e(logTag, "Failed to acquire wake lock", e)
        }

        try {
            val wifiManager =
                applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifiManager.createWifiLock(mode, "rustdesk:session_keep_alive").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.e(logTag, "Failed to acquire wifi lock", e)
        }
    }

    private fun releaseLocks() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            Log.e(logTag, "Failed to release wake lock", e)
        }
        wakeLock = null

        try {
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            Log.e(logTag, "Failed to release wifi lock", e)
        }
        wifiLock = null
    }
}
