plugins {
    id("com.android.application")
}

android {
    namespace = "com.pippinvr.questclient"
    compileSdk = 34
    ndkVersion = "27.0.12077973"

    defaultConfig {
        applicationId = "com.pippinvr.questclient"
        minSdk = 29
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"

        ndk {
            // Quest is arm64 only; building other ABIs just slows the loop down.
            abiFilters += "arm64-v8a"
        }

        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_shared")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildFeatures {
        // The OpenXR loader AAR ships its headers and .so as a prefab package.
        prefab = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        debug {
            isJniDebuggable = true
        }
        release {
            isMinifyEnabled = false
        }
    }

    sourceSets {
        getByName("main") {
            java.setSrcDirs(emptyList<String>())
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("org.khronos.openxr:openxr_loader_for_android:1.1.63")
}
