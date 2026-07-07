package com.socketagent.app

import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class AdbBridgeActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AdbBridgeForegroundService.ACTION_PAIRING_INPUT) return
        val input = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(AdbBridgeForegroundService.KEY_PAIRING_INPUT)
            ?.toString()
            ?.trim()
            ?: return
        AdbBridgeForegroundService.appendPairingInput(context, input)
        val serviceIntent = Intent(context, AdbBridgeForegroundService::class.java).apply {
            action = AdbBridgeForegroundService.ACTION_SHOW_PAIRING_INPUT
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }
}
