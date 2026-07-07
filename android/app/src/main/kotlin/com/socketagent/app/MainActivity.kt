package com.socketagent.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.webkit.CookieManager
import android.content.ComponentName
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.socketagent.app/intent"
    private var wasAssistIntent = false
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        wasAssistIntent = intent?.action == Intent.ACTION_ASSIST ||
                          intent?.action == Intent.ACTION_VOICE_COMMAND

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAssistIntent" -> result.success(wasAssistIntent)
                "startAdbBridgeForeground" -> {
                    try {
                        val serviceIntent = Intent(this, AdbBridgeForegroundService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ADB_BRIDGE_START_ERROR", e.message, null)
                    }
                }
                "showAdbPairingInputNotification" -> {
                    try {
                        val serviceIntent = Intent(this, AdbBridgeForegroundService::class.java).apply {
                            action = AdbBridgeForegroundService.ACTION_SHOW_PAIRING_INPUT
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ADB_BRIDGE_PAIRING_INPUT_ERROR", e.message, null)
                    }
                }
                "takeAdbPairingInputs" -> {
                    try {
                        result.success(AdbBridgeForegroundService.takePairingInputs(this))
                    } catch (e: Exception) {
                        result.error("ADB_BRIDGE_PAIRING_INPUT_READ_ERROR", e.message, null)
                    }
                }
                "localAdbPair" -> {
                    val port = call.argument<String>("port") ?: ""
                    val code = call.argument<String>("code") ?: ""
                    if (port.isBlank() || code.isBlank()) {
                        result.error("LOCAL_ADB_PAIR_ARG_ERROR", "port and code are required", null)
                    } else {
                        LocalAdb.pair(this, port, code) { result.success(it) }
                    }
                }
                "localAdbConnect" -> {
                    val port = call.argument<String>("port") ?: ""
                    if (port.isBlank()) {
                        result.error("LOCAL_ADB_CONNECT_ARG_ERROR", "port is required", null)
                    } else {
                        LocalAdb.connect(this, port) { result.success(it) }
                    }
                }
                "localAdbShell" -> {
                    val command = call.argument<String>("command") ?: ""
                    if (command.isBlank()) {
                        result.error("LOCAL_ADB_SHELL_ARG_ERROR", "command is required", null)
                    } else {
                        LocalAdb.shell(this, command) { result.success(it) }
                    }
                }
                "localAdbCommand" -> {
                    val args = stringListArgument(call.argument<List<*>>("args"))
                    val timeoutSeconds = (call.argument<Int>("timeoutSeconds") ?: 30).toLong()
                    if (args.isEmpty()) {
                        result.error("LOCAL_ADB_COMMAND_ARG_ERROR", "args are required", null)
                    } else {
                        LocalAdb.command(this, args, timeoutSeconds) { result.success(it) }
                    }
                }
                "localAdbInstall" -> {
                    val apkPath = call.argument<String>("apkPath") ?: ""
                    val args = stringListArgument(call.argument<List<*>>("args"))
                    if (apkPath.isBlank()) {
                        result.error("LOCAL_ADB_INSTALL_ARG_ERROR", "apkPath is required", null)
                    } else {
                        LocalAdb.install(this, apkPath, args) { result.success(it) }
                    }
                }
                "localAdbStartStream" -> {
                    val streamId = call.argument<String>("streamId") ?: ""
                    val args = stringListArgument(call.argument<List<*>>("args"))
                    val timeoutSeconds = (call.argument<Int>("timeoutSeconds") ?: 30).toLong()
                    val maxBytes = (call.argument<Int>("maxBytes") ?: 1048576).toLong()
                    if (streamId.isBlank() || args.isEmpty()) {
                        result.error("LOCAL_ADB_STREAM_ARG_ERROR", "streamId and args are required", null)
                    } else {
                        val channel = methodChannel
                        LocalAdb.startStream(this, streamId, args, timeoutSeconds, maxBytes) { event ->
                            runOnUiThread {
                                channel?.invokeMethod("localAdbStreamEvent", event)
                            }
                        }
                        result.success(mapOf("ok" to true, "streamId" to streamId))
                    }
                }
                "localAdbStopStream" -> {
                    val streamId = call.argument<String>("streamId") ?: ""
                    result.success(LocalAdb.stopStream(streamId))
                }
                "localAdbDevices" -> {
                    LocalAdb.devices(this) { result.success(it) }
                }
                "stopAdbBridgeForeground" -> {
                    try {
                        stopService(Intent(this, AdbBridgeForegroundService::class.java))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ADB_BRIDGE_STOP_ERROR", e.message, null)
                    }
                }
                "openDeveloperSettings" -> {
                    try {
                        openWirelessDebuggingSettings()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_ERROR", e.message, null)
                    }
                }
                "canDrawOverlays" -> {
                    result.success(AuthCodeOverlay.canDraw(this))
                }
                "requestOverlayPermission" -> {
                    try {
                        openOverlayPermissionSettings()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_OVERLAY_SETTINGS_ERROR", e.message, null)
                    }
                }
                "showAuthCodeOverlay" -> {
                    try {
                        val code = call.argument<String>("code") ?: ""
                        val title = call.argument<String>("title") ?: "Device sign-in"
                        val timeoutSeconds = (call.argument<Int>("timeoutSeconds") ?: 900)
                            .coerceIn(30, 900)
                        result.success(
                            AuthCodeOverlay.show(
                                this,
                                title,
                                code,
                                timeoutSeconds * 1000L
                            )
                        )
                    } catch (e: Exception) {
                        result.error("AUTH_CODE_OVERLAY_ERROR", e.message, null)
                    }
                }
                "hideAuthCodeOverlay" -> {
                    AuthCodeOverlay.hide()
                    result.success(true)
                }
                "getCookies" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        try {
                            val cookieManager = CookieManager.getInstance()
                            val cookieString = cookieManager.getCookie(url)
                            result.success(cookieString) // "name1=val1; name2=val2; ..." or null
                        } catch (e: Exception) {
                            result.error("COOKIE_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARG", "url is required", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun stringListArgument(raw: List<*>?): List<String> {
        return raw
            ?.mapNotNull { it?.toString() }
            ?.filter { it.isNotBlank() }
            ?: emptyList()
    }

    private fun openWirelessDebuggingSettings() {
        val intents = listOf(
            Intent("com.android.settings.WIRELESS_DEBUGGING_SETTINGS"),
            Intent().apply {
                component = ComponentName("com.android.settings", "com.android.settings.SubSettings")
                putExtra(":settings:show_fragment", "com.android.settings.development.WirelessDebuggingFragment")
                putExtra(":android:show_fragment", "com.android.settings.development.WirelessDebuggingFragment")
            },
            Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS),
        )

        var lastError: Exception? = null
        for (intent in intents) {
            try {
                startActivity(intent)
                return
            } catch (e: Exception) {
                lastError = e
            }
        }
        throw lastError ?: IllegalStateException("Unable to open Wireless Debugging settings.")
    }

    private fun openOverlayPermissionSettings() {
        val intents = listOf(
            Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            ),
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION),
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            )
        )

        var lastError: Exception? = null
        for (intent in intents) {
            try {
                startActivity(intent)
                return
            } catch (e: Exception) {
                lastError = e
            }
        }
        throw lastError ?: IllegalStateException("Unable to open overlay permission settings.")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val isAssist = intent.action == Intent.ACTION_ASSIST ||
                       intent.action == Intent.ACTION_VOICE_COMMAND
        wasAssistIntent = isAssist
        if (isAssist) {
            methodChannel?.invokeMethod("onAssistIntent", null)
        }
    }
}
