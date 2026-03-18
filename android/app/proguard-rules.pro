# flutter_local_notifications — keep all model classes used by Gson deserialization
# in ScheduledNotificationReceiver (R8 full mode strips these via reflection)
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class com.dexterous.flutterlocalnotifications.models.** { *; }
-keep class com.dexterous.flutterlocalnotifications.models.styles.** { *; }

# Preserve enum methods needed for deserialization
-keepclassmembers enum com.dexterous.flutterlocalnotifications.models.** {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Gson
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken
-keep class com.google.gson.** { *; }
-keep interface com.google.gson.** { *; }
