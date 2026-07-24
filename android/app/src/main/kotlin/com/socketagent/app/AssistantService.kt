package com.socketagent.app

import android.content.ComponentName
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.voice.VoiceInteractionService

class AssistantService : VoiceInteractionService() {
    private val handler = Handler(Looper.getMainLooper())

    override fun onReady() {
        super.onReady()
        activeService = this
        if (pendingAdbPairingSession) {
            pendingAdbPairingSession = false
            showAdbPairingSession(DEFAULT_PAIRING_DELAY_MILLIS)
        }
    }

    override fun onShutdown() {
        if (activeService === this) {
            activeService = null
        }
        super.onShutdown()
    }

    override fun onDestroy() {
        if (activeService === this) {
            activeService = null
        }
        super.onDestroy()
    }

    private fun showAdbPairingSession(delayMillis: Long) {
        handler.postDelayed({
            if (activeService !== this) return@postDelayed
            showSession(
                Bundle().apply {
                    putString(AssistantSession.ARG_MODE, AssistantSession.MODE_ADB_PAIRING)
                },
                0
            )
        }, delayMillis)
    }

    companion object {
        @Volatile
        private var activeService: AssistantService? = null

        @Volatile
        private var pendingAdbPairingSession = false

        private const val DEFAULT_PAIRING_DELAY_MILLIS = 650L

        fun isActive(context: Context): Boolean {
            return isActiveService(
                context,
                ComponentName(context, AssistantService::class.java)
            )
        }

        fun requestAdbPairingSession(
            delayMillis: Long = DEFAULT_PAIRING_DELAY_MILLIS
        ): Boolean {
            val service = activeService
            if (service == null) {
                pendingAdbPairingSession = true
                return true
            }
            service.showAdbPairingSession(delayMillis)
            return true
        }
    }
}
