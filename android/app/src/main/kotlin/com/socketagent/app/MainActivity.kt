package com.socketagent.app

import android.content.Intent
import android.content.ClipData
import android.os.Build
import android.net.Uri
import android.provider.Settings
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.socketagent.app/intent"
    private var wasAssistIntent = false
    private var methodChannel: MethodChannel? = null
    private var pendingDeepLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        wasAssistIntent = intent?.action == Intent.ACTION_ASSIST ||
                          intent?.action == Intent.ACTION_VOICE_COMMAND
        pendingDeepLink = sessionDeepLink(intent)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAssistIntent" -> result.success(wasAssistIntent)
                "takeDeepLink" -> {
                    result.success(pendingDeepLink)
                    pendingDeepLink = null
                }
                "getDistribution" -> result.success(BuildConfig.DISTRIBUTION)
                "canRequestPackageInstalls" -> {
                    result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            packageManager.canRequestPackageInstalls()
                    )
                }
                "openPackageInstallSettings" -> {
                    try {
                        openPackageInstallSettings()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_PACKAGE_INSTALL_SETTINGS_ERROR", e.message, null)
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
                "openNotificationSettings" -> {
                    try {
                        openNotificationSettings()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_NOTIFICATION_SETTINGS_ERROR", e.message, null)
                    }
                }
                "getFirebaseProjectConfiguration" -> {
                    result.success(
                        mapOf(
                            "custom" to FirebaseProjectConfigurationStore.load(this)?.toMap(),
                            "bundledProjectId" to FirebaseProjectConfigurationStore.bundledProjectId(this),
                        )
                    )
                }
                "setFirebaseProjectConfiguration" -> {
                    try {
                        val values = call.arguments as? Map<*, *>
                            ?: throw IllegalArgumentException("Firebase configuration is required")
                        result.success(
                            FirebaseProjectConfigurationStore.save(this, values).toMap()
                        )
                    } catch (e: Exception) {
                        result.error("FIREBASE_CONFIG_ERROR", e.message, null)
                    }
                }
                "clearFirebaseProjectConfiguration" -> {
                    FirebaseProjectConfigurationStore.clear(this)
                    result.success(true)
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
                "shareHtmlFile" -> {
                    val requestedPath = call.argument<String>("path") ?: ""
                    val title = call.argument<String>("title") ?: "HTML plan"
                    try {
                        val file = File(requestedPath).canonicalFile
                        val cacheRoot = cacheDir.canonicalFile
                        if (!file.exists() || !file.isFile || !file.path.startsWith(cacheRoot.path + File.separator)) {
                            result.error("SHARE_HTML_INVALID_FILE", "The exported plan is not in the app cache", null)
                        } else {
                            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/html"
                                putExtra(Intent.EXTRA_SUBJECT, title)
                                putExtra(Intent.EXTRA_STREAM, uri)
                                clipData = ClipData.newRawUri(file.name, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(Intent.createChooser(sendIntent, "Share HTML plan"))
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        result.error("SHARE_HTML_ERROR", e.message, null)
                    }
                }
                "shareText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val subject = call.argument<String>("subject") ?: "SocketAgent message"
                    val chooserTitle = call.argument<String>("chooserTitle") ?: "Share message"
                    if (text.isBlank()) {
                        result.error("SHARE_TEXT_INVALID", "The message is empty", null)
                    } else {
                        try {
                            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_SUBJECT, subject)
                                putExtra(Intent.EXTRA_TEXT, text)
                            }
                            startActivity(Intent.createChooser(sendIntent, chooserTitle))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SHARE_TEXT_ERROR", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
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

    private fun openNotificationSettings() {
        val intents = listOf(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            },
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
        throw lastError ?: IllegalStateException("Unable to open notification settings.")
    }

    private fun openPackageInstallSettings() {
        val intents = listOf(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            ),
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
        throw lastError ?: IllegalStateException("Unable to open APK install settings.")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val isAssist = intent.action == Intent.ACTION_ASSIST ||
                       intent.action == Intent.ACTION_VOICE_COMMAND
        wasAssistIntent = isAssist
        val deepLink = sessionDeepLink(intent)
        if (deepLink != null) {
            pendingDeepLink = null
            methodChannel?.invokeMethod("onDeepLink", deepLink)
        }
        if (isAssist) {
            methodChannel?.invokeMethod("onAssistIntent", null)
        }
    }

    private fun sessionDeepLink(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        if (uri.scheme != "socketagent" || uri.host != "session") return null
        return uri.toString()
    }
}
