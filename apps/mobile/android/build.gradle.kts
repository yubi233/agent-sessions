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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
