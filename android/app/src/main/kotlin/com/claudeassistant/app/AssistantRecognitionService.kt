package com.claudeassistant.app

import android.content.Intent
import android.speech.RecognitionService

class AssistantRecognitionService : RecognitionService() {
    override fun onStartListening(intent: Intent?, callback: Callback?) {
        // Stub — actual speech recognition is handled by Flutter
    }
    override fun onCancel(callback: Callback?) {}
    override fun onStopListening(callback: Callback?) {}
}
