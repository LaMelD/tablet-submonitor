// AGP 9는 Kotlin을 내장한다(별도 kotlin-android 플러그인 불필요).
plugins {
    id("com.android.application")
}

android {
    namespace = "dev.submonitor"
    compileSdk = 36
    defaultConfig {
        applicationId = "dev.submonitor"
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
