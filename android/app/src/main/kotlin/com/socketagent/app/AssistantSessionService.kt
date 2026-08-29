package com.socketagent.app

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

class AssistantSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession {
        return AssistantSession(this)
    }
}

class AssistantSession(context: Context) : VoiceInteractionSession(context) {
    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_ASSIST
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        finish()
    }
}
