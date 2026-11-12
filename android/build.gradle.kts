group = "ru.corlex.flutter"
version = "0.1.0"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "ru.corlex.flutter"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

dependencies {
    // The Android runtime's org.json is a stub in JVM unit tests.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("org.json:json:20260719") // GHSA-ghc9-756g-vrcv; JVM tests only.
    constraints {
        testImplementation("com.google.guava:guava:33.7.2-jre") {
            because("GHSA-xxph-c9ww-hj94; Robolectric test graph only")
        }
        testImplementation("org.bouncycastle:bcprov-jdk18on:1.85") {
            because("Patched Bouncy Castle security advisories through 1.85; tests only")
        }
    }
}
