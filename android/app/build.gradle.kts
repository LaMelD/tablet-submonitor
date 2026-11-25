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
        // 36으로 올리면 Android 16 대화면에서 screenOrientation이 무시돼 세로일 때 영상이 찌그러진다(실기 확인)
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
