pluginManagement {
    // 官方 Google Maven 不稳定时，调用方可显式设置 HTTPS 镜像；未设置时仍只使用官方仓库。
    val googleMavenMirror =
        System.getenv("AGENT_SESSIONS_GOOGLE_MAVEN_MIRROR")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
    require(googleMavenMirror == null || googleMavenMirror.startsWith("https://")) {
        "AGENT_SESSIONS_GOOGLE_MAVEN_MIRROR 必须是 HTTPS URL"
    }
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        googleMavenMirror?.let { mirror ->
            maven {
                name = "AgentSessionsGoogleMavenMirror"
                url = uri(mirror)
            }
        }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
