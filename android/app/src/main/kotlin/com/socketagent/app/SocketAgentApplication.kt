package com.socketagent.app

import android.app.Application
import android.util.Log
import com.google.firebase.FirebaseApp

class SocketAgentApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (FirebaseApp.getApps(this).isNotEmpty()) return

        val custom = FirebaseProjectConfigurationStore.load(this)
        val initialized = if (custom == null) {
            FirebaseApp.initializeApp(this)
        } else {
            FirebaseApp.initializeApp(this, custom.toFirebaseOptions())
        }
        if (initialized == null) {
            Log.e("SocketAgent", "Firebase could not be initialized")
        }
    }
}
