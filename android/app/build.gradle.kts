import java.util.Properties

// The App Check debug secret comes from local.properties (git-ignored), never from the repository.
val localProps = Properties().apply { rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) } }

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.kronagent.plainly"
    compileSdk {
        version = release(37) { minorApiLevel = 2 }
    }
    defaultConfig {
        applicationId = "com.kronagent.plainly"
        minSdk = 26 // firebase-ai-ondevice (ML Kit Prompt API) needs API 26+
        targetSdk = 36
        versionCode = 5
        versionName = "0.1.4"
        buildConfigField("String", "APPCHECK_DEBUG_SECRET", "\"${localProps.getProperty("appcheck.debug", "")}\"")
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            // Signed with the debug key so judges can sideload it; App Check uses the debug provider in this build.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    implementation(platform("androidx.compose:compose-bom:2026.11.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.11.0")

    implementation("com.google.firebase:firebase-ai:18.2.0")
    implementation("com.google.firebase:firebase-ai-ondevice:16.0.0-beta08")
    implementation("com.google.firebase:firebase-appcheck-debug:20.1.0")
    implementation("com.google.firebase:firebase-appcheck-playintegrity:20.1.0")
    // On-device OCR (bundled Latin model): Google's own advice is to OCR first, then give Gemini Nano the text.
    implementation("com.google.mlkit:text-recognition:16.0.1")
}
