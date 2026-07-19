package com.socketagent.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.text.InputType
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

object AuthCodeOverlay {
    private var overlayView: View? = null
    private var windowManager: WindowManager? = null
    private var hideRunnable: Runnable? = null
    private val handler = Handler(Looper.getMainLooper())

    fun canDraw(context: Context): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)
    }

    fun show(
        context: Context,
        title: String,
        code: String,
        timeoutMillis: Long
    ): Boolean {
        if (!canDraw(context) || code.isBlank()) return false

        if (Looper.myLooper() == Looper.getMainLooper()) {
            return showOnMain(context, title, code, timeoutMillis)
        }

        val latch = CountDownLatch(1)
        var shown = false
        handler.post {
            shown = showOnMain(context, title, code, timeoutMillis)
            latch.countDown()
        }
        return try {
            latch.await(2, TimeUnit.SECONDS)
            shown
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }

    fun showAdbPairing(
        context: Context,
        initialPort: String,
        initialCode: String,
        timeoutMillis: Long,
        onSubmit: (String, String) -> Unit
    ): Boolean {
        if (!canDraw(context)) return false

        if (Looper.myLooper() == Looper.getMainLooper()) {
            return showAdbPairingOnMain(
                context,
                initialPort,
                initialCode,
                timeoutMillis,
                onSubmit
            )
        }

        val latch = CountDownLatch(1)
        var shown = false
        handler.post {
            shown = showAdbPairingOnMain(
                context,
                initialPort,
                initialCode,
                timeoutMillis,
                onSubmit
            )
            latch.countDown()
        }
        return try {
            latch.await(2, TimeUnit.SECONDS)
            shown
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }

    private fun showAdbPairingOnMain(
        context: Context,
        initialPort: String,
        initialCode: String,
        timeoutMillis: Long,
        onSubmit: (String, String) -> Unit
    ): Boolean {
        return try {
            hideOnMain()
            val appContext = context.applicationContext
            val wm = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            windowManager = wm

            val card = overlayCard(appContext)
            val header = overlayHeader(appContext, "Pair wireless ADB")
            header.addView(actionPill(appContext, "Close") { hide() })
            card.addView(header)

            card.addView(TextView(appContext).apply {
                text = "Enter the values shown under Pair device with pairing code."
                setTextColor(Color.argb(205, 255, 255, 255))
                textSize = 12f
                setPadding(0, dp(appContext, 8), 0, dp(appContext, 8))
            })

            val fields = LinearLayout(appContext).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            val portField = numberField(appContext, "Pairing port", initialPort).apply {
                imeOptions = EditorInfo.IME_ACTION_NEXT
            }
            val codeField = numberField(appContext, "Pairing code", initialCode).apply {
                imeOptions = EditorInfo.IME_ACTION_DONE
            }
            fields.addView(portField, LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f
            ).apply { marginEnd = dp(appContext, 8) })
            fields.addView(codeField, LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f
            ))
            card.addView(fields)

            val actions = LinearLayout(appContext).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(appContext, 10), 0, 0)
            }
            actions.addView(TextView(appContext).apply {
                text = "Drag title to move"
                setTextColor(Color.argb(190, 255, 255, 255))
                textSize = 12f
                layoutParams = LinearLayout.LayoutParams(
                    0,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    1f
                )
            })
            actions.addView(actionPill(appContext, "Pair") {
                val port = portField.text.toString().trim()
                val code = codeField.text.toString().trim()
                val parsedPort = port.toIntOrNull()
                if (parsedPort == null || parsedPort !in 1..65535) {
                    Toast.makeText(appContext, "Enter a valid pairing port", Toast.LENGTH_SHORT).show()
                    portField.requestFocus()
                    return@actionPill
                }
                if (code.length !in 4..12 || code.any { !it.isDigit() }) {
                    Toast.makeText(appContext, "Enter the numeric pairing code", Toast.LENGTH_SHORT).show()
                    codeField.requestFocus()
                    return@actionPill
                }
                onSubmit(port, code)
                Toast.makeText(appContext, "ADB pairing submitted", Toast.LENGTH_SHORT).show()
                hide()
            })
            card.addView(actions)

            val params = overlayParams(appContext, focusable = true)
            attachDrag(header, card, params)
            wm.addView(card, params)
            overlayView = card
            scheduleHide(timeoutMillis)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun showOnMain(
        context: Context,
        title: String,
        code: String,
        timeoutMillis: Long
    ): Boolean {
        return try {
            hideOnMain()
            val appContext = context.applicationContext
            val wm = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            windowManager = wm

            val card = overlayCard(appContext)

            val header = overlayHeader(appContext, title.ifBlank { "Device sign-in" })
            header.addView(actionPill(appContext, "Close") { hide() })
            card.addView(header)

            card.addView(TextView(appContext).apply {
                text = code
                setTextColor(Color.WHITE)
                textSize = 28f
                letterSpacing = 0.08f
                typeface = Typeface.MONOSPACE
                gravity = Gravity.CENTER
                setPadding(0, dp(appContext, 10), 0, dp(appContext, 8))
            })

            val actions = LinearLayout(appContext).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            actions.addView(TextView(appContext).apply {
                text = "Drag to move"
                setTextColor(Color.argb(190, 255, 255, 255))
                textSize = 12f
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            actions.addView(actionPill(appContext, "Copy") {
                val clipboard = appContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("Device code", code))
                Toast.makeText(appContext, "Code copied", Toast.LENGTH_SHORT).show()
            })
            card.addView(actions)

            val params = overlayParams(appContext, focusable = false)
            attachDrag(card, card, params)

            wm.addView(card, params)
            overlayView = card

            scheduleHide(timeoutMillis)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun hide() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            hideOnMain()
        } else {
            handler.post { hideOnMain() }
        }
    }

    private fun hideOnMain() {
        hideRunnable?.let { handler.removeCallbacks(it) }
        hideRunnable = null
        val view = overlayView
        overlayView = null
        if (view != null) {
            runCatching { windowManager?.removeView(view) }
        }
    }

    private fun dp(context: Context, value: Int): Int {
        return (value * context.resources.displayMetrics.density).roundToInt()
    }

    private fun overlayCard(context: Context): LinearLayout {
        return LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(context, 16), dp(context, 14), dp(context, 16), dp(context, 12))
            background = GradientDrawable().apply {
                setColor(Color.rgb(35, 29, 26))
                cornerRadius = dp(context, 16).toFloat()
                setStroke(dp(context, 1), Color.argb(80, 255, 255, 255))
            }
            elevation = dp(context, 12).toFloat()
        }
    }

    private fun overlayHeader(context: Context, title: String): LinearLayout {
        return LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(TextView(context).apply {
                text = title
                setTextColor(Color.WHITE)
                textSize = 15f
                typeface = Typeface.DEFAULT_BOLD
                layoutParams = LinearLayout.LayoutParams(
                    0,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    1f
                )
            })
        }
    }

    private fun numberField(context: Context, hint: String, value: String): EditText {
        return EditText(context).apply {
            setText(value)
            this.hint = hint
            setTextColor(Color.WHITE)
            setHintTextColor(Color.argb(155, 255, 255, 255))
            textSize = 15f
            inputType = InputType.TYPE_CLASS_NUMBER
            isSingleLine = true
            setSelectAllOnFocus(true)
            backgroundTintList = ColorStateList.valueOf(Color.argb(150, 255, 255, 255))
        }
    }

    private fun overlayParams(
        context: Context,
        focusable: Boolean
    ): WindowManager.LayoutParams {
        val flags = WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            (if (focusable) 0 else WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        return WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            flags,
            android.graphics.PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = dp(context, 72)
            width = (context.resources.displayMetrics.widthPixels * 0.88f).roundToInt()
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        }
    }

    private fun attachDrag(
        dragView: View,
        card: View,
        params: WindowManager.LayoutParams
    ) {
        dragView.setOnTouchListener(object : View.OnTouchListener {
            private var initialX = 0
            private var initialY = 0
            private var initialTouchX = 0f
            private var initialTouchY = 0f

            override fun onTouch(v: View, event: MotionEvent): Boolean {
                when (event.action) {
                    MotionEvent.ACTION_DOWN -> {
                        initialX = params.x
                        initialY = params.y
                        initialTouchX = event.rawX
                        initialTouchY = event.rawY
                        return true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        params.x = initialX + (event.rawX - initialTouchX).roundToInt()
                        params.y = initialY + (event.rawY - initialTouchY).roundToInt()
                        windowManager?.updateViewLayout(card, params)
                        return true
                    }
                }
                return false
            }
        })
    }

    private fun scheduleHide(timeoutMillis: Long) {
        val delay = timeoutMillis.coerceIn(30_000L, 15 * 60_000L)
        hideRunnable = Runnable { hide() }
        handler.postDelayed(hideRunnable!!, delay)
    }

    private fun actionPill(context: Context, label: String, onClick: () -> Unit): TextView {
        return TextView(context).apply {
            text = label
            setTextColor(Color.WHITE)
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            isClickable = true
            isFocusable = true
            minHeight = dp(context, 34)
            setPadding(dp(context, 14), dp(context, 7), dp(context, 14), dp(context, 7))
            background = GradientDrawable().apply {
                setColor(Color.argb(42, 255, 255, 255))
                cornerRadius = dp(context, 18).toFloat()
                setStroke(dp(context, 1), Color.argb(82, 255, 255, 255))
            }
            setOnClickListener { onClick() }
        }
    }
}
