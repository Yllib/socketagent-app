package com.socketagent.app

import android.content.Context
import com.google.firebase.FirebaseOptions

data class FirebaseProjectConfiguration(
    val projectId: String,
    val projectNumber: String,
    val appId: String,
    val apiKey: String,
    val packageName: String,
) {
    fun toFirebaseOptions(): FirebaseOptions = FirebaseOptions.Builder()
        .setProjectId(projectId)
        .setGcmSenderId(projectNumber)
        .setApplicationId(appId)
        .setApiKey(apiKey)
        .build()

    fun toMap(): Map<String, String> = mapOf(
        "projectId" to projectId,
        "projectNumber" to projectNumber,
        "appId" to appId,
        "apiKey" to apiKey,
        "packageName" to packageName,
    )
}

object FirebaseProjectConfigurationStore {
    private const val preferencesName = "socketagent_firebase_project"
    private const val projectIdKey = "project_id"
    private const val projectNumberKey = "project_number"
    private const val appIdKey = "app_id"
    private const val apiKeyKey = "api_key"
    private const val packageNameKey = "package_name"

    fun load(context: Context): FirebaseProjectConfiguration? {
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val configuration = FirebaseProjectConfiguration(
            projectId = preferences.getString(projectIdKey, "").orEmpty().trim(),
            projectNumber = preferences.getString(projectNumberKey, "").orEmpty().trim(),
            appId = preferences.getString(appIdKey, "").orEmpty().trim(),
            apiKey = preferences.getString(apiKeyKey, "").orEmpty().trim(),
            packageName = preferences.getString(packageNameKey, "").orEmpty().trim(),
        )
        return configuration.takeIf { value ->
            value.projectId.isNotEmpty()
                && value.projectNumber.isNotEmpty()
                && value.appId.isNotEmpty()
                && value.apiKey.isNotEmpty()
                && value.packageName == context.packageName
        }
    }

    fun save(
        context: Context,
        values: Map<*, *>,
    ): FirebaseProjectConfiguration {
        val configuration = FirebaseProjectConfiguration(
            projectId = values["projectId"] as? String ?: "",
            projectNumber = values["projectNumber"] as? String ?: "",
            appId = values["appId"] as? String ?: "",
            apiKey = values["apiKey"] as? String ?: "",
            packageName = values["packageName"] as? String ?: "",
        )
        require(configuration.projectId.isNotBlank()) { "projectId is required" }
        require(configuration.projectNumber.isNotBlank()) { "projectNumber is required" }
        require(configuration.appId.isNotBlank()) { "appId is required" }
        require(configuration.apiKey.isNotBlank()) { "apiKey is required" }
        require(configuration.packageName == context.packageName) {
            "Firebase package must be ${context.packageName}"
        }

        val saved = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putString(projectIdKey, configuration.projectId.trim())
            .putString(projectNumberKey, configuration.projectNumber.trim())
            .putString(appIdKey, configuration.appId.trim())
            .putString(apiKeyKey, configuration.apiKey.trim())
            .putString(packageNameKey, configuration.packageName.trim())
            .commit()
        check(saved) { "Firebase configuration could not be saved" }
        return configuration
    }

    fun clear(context: Context) {
        val cleared = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        check(cleared) { "Firebase configuration could not be cleared" }
    }

    fun bundledProjectId(context: Context): String? {
        val identifier = context.resources.getIdentifier(
            "project_id",
            "string",
            context.packageName,
        )
        if (identifier == 0) return null
        return context.getString(identifier).trim().ifEmpty { null }
    }
}
