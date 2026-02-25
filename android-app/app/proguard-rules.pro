# AVA Doorbell — ProGuard rules

# Paho MQTT
-keep class org.eclipse.paho.** { *; }
-keepnames class * implements org.eclipse.paho.client.mqttv3.MqttCallback
-keepnames class * implements org.eclipse.paho.client.mqttv3.MqttCallbackExtended
-dontwarn org.eclipse.paho.client.mqttv3.**

# OkHttp (used by NativeTalkManager WebSocket)
-dontwarn okhttp3.internal.platform.**
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }
-keep class okio.** { *; }

# Media3 / ExoPlayer
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# AndroidX Security (EncryptedSharedPreferences)
-keep class androidx.security.crypto.** { *; }
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**
