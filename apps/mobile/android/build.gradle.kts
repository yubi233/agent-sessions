// 仅在环境显式授权时使用镜像；官方 Google Maven 仍是默认和回退来源。
val googleMavenMirror =
    System.getenv("AGENT_SESSIONS_GOOGLE_MAVEN_MIRROR")
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
require(googleMavenMirror == null || googleMavenMirror.startsWith("https://")) {
    "AGENT_SESSIONS_GOOGLE_MAVEN_MIRROR 必须是 HTTPS URL"
}

allprojects {
    repositories {
        googleMavenMirror?.let { mirror ->
            maven {
                name = "AgentSessionsGoogleMavenMirror"
                url = uri(mirror)
            }
        }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 旧 Flutter plugin 可能在自己的 build.gradle 中固定 compileSdk 33；当前 AndroidX
// runtime metadata 已要求 34+。统一到本机已安装的 API 36，不改变 targetSdk/minSdk。
subprojects {
    if (path != ":app") {
        afterEvaluate {
            plugins.withId("com.android.library") {
                val androidExtension = extensions.findByName("android") ?: return@withId
                val compileSdkSetter =
                    androidExtension.javaClass.methods.firstOrNull { method ->
                        method.name == "setCompileSdk" && method.parameterCount == 1
                    } ?: error("Android library ${project.path} 不支持设置 compileSdk")
                compileSdkSetter.invoke(androidExtension, 36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
