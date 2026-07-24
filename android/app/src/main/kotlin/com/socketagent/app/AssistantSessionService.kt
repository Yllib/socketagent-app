package com.socketagent.app

import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import kotlin.math.roundToInt

class AssistantSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession {
        return AssistantSession(this)
    }
}

class AssistantSession(context: Context) : VoiceInteractionSession(context) {
    private var pairingCard: View? = null

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        if (args?.getString(ARG_MODE) == MODE_ADB_PAIRING) {
            showAdbPairing()
            return
        }

        pairingCard = null
        // Launch the main Flutter activity
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_ASSIST
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        finish()
    }

    private fun showAdbPairing() {
        val appContext = context.applicationContext
        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(16), dp(18), dp(14))
            background = GradientDrawable().apply {
                setColor(Color.rgb(35, 29, 26))
                cornerRadius = dp(20).toFloat()
                setStroke(dp(1), Color.argb(80, 255, 255, 255))
            }
            elevation = dp(12).toFloat()
        }

        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(TextView(context).apply {
            text = "Pair wireless ADB"
            setTextColor(Color.WHITE)
            textSize = 17f
            typeface = Typeface.DEFAULT_BOLD
            layoutParams = LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f
            )
        })
        header.addView(actionPill("Close") { finish() })
        card.addView(header)

        card.addView(TextView(context).apply {
            text = "Keep the pairing dialog open. Enter its port and code here."
            setTextColor(Color.argb(205, 255, 255, 255))
            textSize = 13f
            setPadding(0, dp(8), 0, dp(10))
        })

        val fields = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val portField = numberField("Pairing port").apply {
            imeOptions = EditorInfo.IME_ACTION_NEXT
        }
        val codeField = numberField("Pairing code").apply {
            imeOptions = EditorInfo.IME_ACTION_DONE
        }
        fields.addView(
            portField,
            LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f
            ).apply { marginEnd = dp(10) }
        )
        fields.addView(
            codeField,
            LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f
            )
        )
        card.addView(fields)

        val actions = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            setPadding(0, dp(12), 0, 0)
        }
        val status = TextView(context).apply {
            setTextColor(Color.argb(220, 255, 255, 255))
            textSize = 13f
            visibility = View.GONE
            setPadding(0, dp(10), 0, 0)
        }
        lateinit var pairButton: TextView
        pairButton = actionPill("Pair") {
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
            portField.isEnabled = false
            codeField.isEnabled = false
            pairButton.isEnabled = false
            pairButton.alpha = 0.55f
            pairButton.text = "Pairing…"
            status.visibility = View.VISIBLE
            status.text = "Running adb pair on this phone…"

            LocalAdb.pair(appContext, port, code) { result ->
                val succeeded = result["ok"] == true
                status.text = adbResultMessage(result)
                pairButton.text = if (succeeded) "Paired" else "Try Again"
                pairButton.alpha = if (succeeded) 0.7f else 1f
                pairButton.isEnabled = !succeeded
                portField.isEnabled = !succeeded
                codeField.isEnabled = !succeeded
                Toast.makeText(
                    appContext,
                    if (succeeded) "Wireless ADB paired" else "ADB pairing failed",
                    Toast.LENGTH_LONG
                ).show()
            }
        }
        actions.addView(pairButton)
        card.addView(actions)
        card.addView(status)
        pairingCard = card

        setContentView(
            LinearLayout(context).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                setPadding(dp(16), dp(72), dp(16), 0)
                addView(
                    card,
                    LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    )
                )
            }
        )
        window.window?.setSoftInputMode(
            WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        )
        window.window?.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
    }

    override fun onComputeInsets(outInsets: Insets) {
        super.onComputeInsets(outInsets)
        val card = pairingCard ?: return
        val location = IntArray(2)
        card.getLocationInWindow(location)
        outInsets.touchableInsets = Insets.TOUCHABLE_INSETS_REGION
        outInsets.touchableRegion.set(
            location[0],
            location[1],
            location[0] + card.width,
            location[1] + card.height
        )
    }

    private fun numberField(hint: String): EditText {
        return EditText(context).apply {
            this.hint = hint
            setTextColor(Color.WHITE)
            setHintTextColor(Color.argb(155, 255, 255, 255))
            textSize = 15f
            inputType = InputType.TYPE_CLASS_NUMBER
            isSingleLine = true
            setSelectAllOnFocus(true)
            backgroundTintList = ColorStateList.valueOf(
                Color.argb(150, 255, 255, 255)
            )
        }
    }

    private fun adbResultMessage(result: Map<String, Any?>): String {
        val succeeded = result["ok"] == true
        val details = listOf("stdout", "stderr", "message")
            .mapNotNull { key -> result[key]?.toString()?.trim() }
            .filter { it.isNotEmpty() }
        val headline = if (succeeded) {
            "Paired successfully. Use the connect port from the main Wireless Debugging screen next."
        } else {
            "Pairing failed."
        }
        return if (details.isEmpty()) headline else "$headline\n${details.joinToString("\n")}"
    }

    private fun actionPill(label: String, onClick: () -> Unit): TextView {
        return TextView(context).apply {
            text = label
            setTextColor(Color.WHITE)
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            isClickable = true
            isFocusable = true
            minHeight = dp(36)
            setPadding(dp(15), dp(7), dp(15), dp(7))
            background = GradientDrawable().apply {
                setColor(Color.argb(42, 255, 255, 255))
                cornerRadius = dp(18).toFloat()
                setStroke(dp(1), Color.argb(82, 255, 255, 255))
            }
            setOnClickListener { onClick() }
        }
    }

    private fun dp(value: Int): Int {
        return (value * context.resources.displayMetrics.density).roundToInt()
    }

    companion object {
        const val ARG_MODE = "socketagent_mode"
        const val MODE_ADB_PAIRING = "adb_pairing"
    }
}
