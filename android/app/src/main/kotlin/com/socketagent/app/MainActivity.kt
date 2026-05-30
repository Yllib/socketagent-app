package com.socketagent.app

import android.content.Intent
import android.webkit.CookieManager
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
