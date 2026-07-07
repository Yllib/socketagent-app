package com.socketagent.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.app.RemoteInput

class AdbBridgeForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "adb_bridge"
        const val NOTIFICATION_ID = 7301
        const val ACTION_SHOW_PAIRING_INPUT = "com.socketagent.app.adb.SHOW_PAIRING_INPUT"
        const val ACTION_PAIRING_INPUT = "com.socketagent.app.adb.PAIRING_INPUT"
        const val KEY_PAIRING_INPUT = "adb_pairing_input"
        private const val PREFS = "adb_bridge"
        private const val PREF_PENDING_INPUTS = "pending_pairing_inputs"

        fun appendPairingInput(context: Context, value: String) {
            val cleaned = value.trim()
            if (cleaned.isEmpty()) return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val current = prefs.getString(PREF_PENDING_INPUTS, "") ?: ""
            val next = if (current.isBlank()) cleaned else "$current\n$cleaned"
            prefs.edit().putString(PREF_PENDING_INPUTS, next).apply()
        }

        fun takePairingInputs(context: Context): List<String> {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val current = prefs.getString(PREF_PENDING_INPUTS, "") ?: ""
            prefs.edit().remove(PREF_PENDING_INPUTS).apply()
            return current
                .lineSequence()
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .toList()
        }
    }

    private var waitingForPairingInput = false

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_SHOW_PAIRING_INPUT) {
            waitingForPairingInput = true
        }
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "ADB Bridge",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps the SocketAgent ADB bridge running"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val inputIntent = Intent(this, AdbBridgeActionReceiver::class.java).apply {
            action = ACTION_PAIRING_INPUT
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_MUTABLE else 0
        val inputPendingIntent = PendingIntent.getBroadcast(this, 7302, inputIntent, flags)
        val remoteInput = RemoteInput.Builder(KEY_PAIRING_INPUT)
            .setLabel("pairPort code or host:pairPort code")
            .build()
        val inputAction = Notification.Action.Builder(
            android.R.drawable.ic_menu_send,
            "Enter pairing code",
            inputPendingIntent
        ).addRemoteInput(remoteInput).build()

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("SocketAgent ADB bridge")
            .setContentText(
                if (waitingForPairingInput) {
                    "Open Wireless Debugging, then enter pairPort code here"
                } else {
                    "Debug bridge is active"
                }
            )
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .addAction(inputAction)
            .build()
    }
}
