import java.util.Properties
import java.io.File
plugins { id("com.android.application"); id("org.jetbrains.kotlin.android"); id("org.jetbrains.kotlin.plugin.compose") }
val signingInput = providers.gradleProperty("filmboxSigningProperties").orNull
val signing = Properties().apply { if(signingInput != null) File(signingInput).inputStream().use { load(it) } }
android {
    namespace = "com.filmbox.app"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.filmbox.app"
        minSdk = 30
        targetSdk = 35
        versionCode = 7
        versionName = "0.4.1"
        testInstrumentationRunner = providers.gradleProperty("filmboxRunner").orElse("androidx.test.runner.AndroidJUnitRunner").get()
        testProguardFiles("test-proguard-rules.pro")
        ndk { abiFilters += "arm64-v8a" }
    }
    testBuildType = providers.gradleProperty("filmboxTestBuildType").orElse("debug").get()
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    packaging { jniLibs.useLegacyPackaging = true; resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    signingConfigs { if(signingInput != null) create("filmbox") {
        storeFile = file(signing.getProperty("storeFile")); storePassword = signing.getProperty("storePassword")
        keyAlias = signing.getProperty("keyAlias"); keyPassword = signing.getProperty("keyPassword")
    } }
    buildTypes { release {
        isMinifyEnabled = true; isShrinkResources = true
        proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        if(signingInput != null) signingConfig = signingConfigs.getByName("filmbox")
    } }
}
dependencies {
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation(platform("androidx.compose:compose-bom:2025.04.00"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.exifinterface:exifinterface:1.4.1")
    implementation("androidx.media3:media3-exoplayer:1.6.1")
    implementation("androidx.media3:media3-ui:1.6.1")
    implementation("androidx.media3:media3-datasource-okhttp:1.6.1")
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("io.coil-kt:coil-video:2.7.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("com.google.errorprone:error_prone_annotations:2.36.0")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.04.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

val prepareLegalResources by tasks.registering(Exec::class) {
    val repository = rootProject.projectDir.parentFile
    workingDir(repository)
    commandLine("python3", "scripts/prepare-legal.py", "--android", "--output", "Android/app/src/main/assets")
}
tasks.named("preBuild") { dependsOn(prepareLegalResources) }
