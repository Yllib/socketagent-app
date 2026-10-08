package com.socketagent.app

import android.content.Intent
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.os.Build
import android.net.Uri
import android.provider.Settings
import android.view.WindowInsets
import android.webkit.CookieManager
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    private var moonshine: MoonshineRecognition? = null
    private val CHANNEL = "com.socketagent.app/intent"
    private var wasAssistIntent = false
    private var methodChannel: MethodChannel? = null
    private var pendingDeepLink: String? = null

    override fun onResume() {
        super.onResume()
        refreshKeyboardInsets()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) refreshKeyboardInsets()
    }

    private fun refreshKeyboardInsets() {
        val flutterView = findViewById<FlutterView>(FLUTTER_VIEW_ID) ?: return
        flutterView.requestApplyInsets()
        flutterView.postOnAnimation {
            if (!flutterView.isAttachedToWindow || !flutterView.hasWindowFocus()) {
                return@postOnAnimation
            }
            // An interrupted IME animation can leave Flutter's inset listener
            // deferring the keyboard-hidden update. Read the current window state
            // after regaining focus and deliver it directly to Flutter's viewport.
            // Leave visible-keyboard animation updates to the normal listener.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val insets = flutterView.rootWindowInsets ?: return@postOnAnimation
                if (!insets.isVisible(WindowInsets.Type.ime())) {
                    flutterView.onApplyWindowInsets(insets)
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        moonshine?.close()
        moonshine = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        moonshine = MoonshineRecognition(flutterEngine.dartExecutor.binaryMessenger, applicationContext)

        wasAssistIntent = intent?.action == Intent.ACTION_ASSIST ||
                          intent?.action == Intent.ACTION_VOICE_COMMAND
        pendingDeepLink = appDeepLink(intent)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAssistIntent" -> result.success(wasAssistIntent)
                "takeDeepLink" -> {
                    result.success(pendingDeepLink)
                    pendingDeepLink = null
                }
                "getDistribution" -> result.success(BuildConfig.DISTRIBUTION)
                "openDownloadedFile" -> {
                    try {
                        val file = File(call.argument<String>("path") ?: "").canonicalFile
                        if (!file.isFile) {
                            result.error("FILE_NOT_FOUND", "The downloaded file is no longer available.", null)
                        } else if (!file.canRead()) {
                            result.error("FILE_ACCESS_DENIED", "Android denied access to this file.", null)
                        } else {
                            // FileProvider limits the accessible roots. Grant only this URI,
                            // never broad access to the user's photo or video library.
                            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                            val mime = call.argument<String>("type")
                                ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
                                ?: "application/octet-stream"
                            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, mime)
                                clipData = ClipData.newRawUri(file.name, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(viewIntent)
                            result.success(true)
                        }
                    } catch (e: ActivityNotFoundException) {
                        result.error("NO_FILE_VIEWER", "No installed app can open this file type.", null)
                    } catch (e: Exception) {
                        result.error("OPEN_FILE_ERROR", e.message, null)
                    }
                }
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
        val deepLink = appDeepLink(intent)
        if (deepLink != null) {
            pendingDeepLink = null
            methodChannel?.invokeMethod("onDeepLink", deepLink)
        }
        if (isAssist) {
            methodChannel?.invokeMethod("onAssistIntent", null)
        }
    }

    private fun appDeepLink(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        if (uri.scheme != "socketagent") return null
        if (uri.host != "session" && !(uri.host == "auth" && uri.path == "/return")) return null
        return uri.toString()
    }
}
