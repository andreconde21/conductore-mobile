import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use(keystoreProperties::load)
}

android {
    namespace = "com.gwitko.conduit"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "com.outsmartis.conductore"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "distribution"
    productFlavors {
        create("play") {
            dimension = "distribution"
            buildConfigField("boolean", "FULL_STORAGE_ACCESS", "false")
        }
        create("full") {
            dimension = "distribution"
            versionNameSuffix = "-full"
            buildConfigField("boolean", "FULL_STORAGE_ACCESS", "true")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let(::file)
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }
}

val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abi = output.filters.find { it.filterType == "ABI" }?.identifier
        val abiVersionCode = abiCodes[abi]
        val apkOutput = output as ApkVariantOutputImpl
        if (abiVersionCode != null) {
            apkOutput.versionCodeOverride = variant.versionCode * 10 + abiVersionCode
        }
        if (variant.flavorName == "full" && variant.buildType.name == "release") {
            apkOutput.outputFileName = if (abi == null) {
                "app-release.apk"
            } else {
                "app-$abi-release.apk"
            }
        }
    }
}

val copyFullReleaseFlutterApksToLegacyNames by tasks.registering {
    doLast {
        val flutterApkDir = layout.buildDirectory.dir("outputs/flutter-apk").get().asFile
        flutterApkDir
            .listFiles { file -> file.isFile && file.name.endsWith("-full-release.apk") }
            ?.forEach { apk ->
                val legacyName = apk.name.replace("-full-release.apk", "-release.apk")
                apk.copyTo(File(flutterApkDir, legacyName), overwrite = true)
            }
    }
}

tasks.matching { it.name == "assembleRelease" || it.name == "assembleFullRelease" }.configureEach {
    finalizedBy(copyFullReleaseFlutterApksToLegacyNames)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // JVM unit tests of the plain-Kotlin rules (src/test).
    testImplementation("junit:junit:4.13.2")
    // The real org.json for the widget payload parsing tests (android.jar
    // only has stubs on the JVM).
    testImplementation("org.json:json:20240303")
}
