import java.util.Properties
import java.io.ByteArrayOutputStream
import javax.xml.XMLConstants
import javax.xml.parsers.DocumentBuilderFactory
import mobilka.gradle.UpdaterProviderVerifier

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use(keystoreProperties::load)
}

fun readSigningValue(propertyName: String, environmentName: String): String? {
    val propertyValue = keystoreProperties
        .getProperty(propertyName)
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
    val environmentValue = providers.environmentVariable(environmentName)
        .orNull
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
    return propertyValue ?: environmentValue
}

val releaseStoreFilePath = readSigningValue("storeFile", "ANDROID_KEYSTORE_PATH")
val releaseStorePassword = readSigningValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = readSigningValue("keyAlias", "ANDROID_KEY_ALIAS")
val releaseKeyPassword = readSigningValue("keyPassword", "ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStoreFilePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }
val requestedTaskNames = gradle.startParameter.taskNames.map { it.lowercase() }
val requiresReleaseSigning = requestedTaskNames.any { it.contains("release") }

android {
    namespace = "com.rslnmzhn.mobilka"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.rslnmzhn.mobilka"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 10 keeps scoped-storage behavior predictable for the MVP.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFilePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

if (requiresReleaseSigning && !hasReleaseSigning) {
    throw GradleException(
        "Release signing is required. Configure android/key.properties or " +
            "ANDROID_KEYSTORE_* environment variables.",
    )
}

flutter {
    source = "../.."
}

val verifyUpdaterProviderConfiguration by tasks.registering {
    group = "verification"
    description = "Verifies the exact packaged Android updater FileProvider scope."
    val manifest = file("src/main/AndroidManifest.xml")
    val paths = file("src/main/res/xml/file_paths.xml")
    inputs.files(manifest, paths)
    doLast {
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
            setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true)
            setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
            setFeature("http://xml.org/sax/features/external-general-entities", false)
            setFeature("http://xml.org/sax/features/external-parameter-entities", false)
            setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)
            isXIncludeAware = false
            isExpandEntityReferences = false
            setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "")
            setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "")
        }
        val manifestDocument = factory.newDocumentBuilder().parse(manifest)
        val providers = manifestDocument.getElementsByTagName("provider")
        val allProviders = (0 until providers.length)
            .map { providers.item(it) as org.w3c.dom.Element }
        val matching = allProviders
            .filter {
                it.getAttributeNS("http://schemas.android.com/apk/res/android", "name") ==
                    "androidx.core.content.FileProvider"
            }
        val matchingAuthority = allProviders.filter {
            it.getAttributeNS("http://schemas.android.com/apk/res/android", "authorities") ==
                "\${applicationId}.updater.files"
        }
        if (matching.size != 1 || matchingAuthority.size != 1 ||
            matching.single() !== matchingAuthority.single()) {
            throw GradleException("Expected one unambiguous updater FileProvider")
        }
        val provider = matching.single()
        fun androidAttribute(name: String) =
            provider.getAttributeNS("http://schemas.android.com/apk/res/android", name)
        if (androidAttribute("authorities") != "\${applicationId}.updater.files" ||
            androidAttribute("exported") != "false" ||
            androidAttribute("grantUriPermissions") != "true") {
            throw GradleException("Updater FileProvider declaration is not exact")
        }
        val metaData = (0 until provider.childNodes.length)
            .map { provider.childNodes.item(it) }
            .filterIsInstance<org.w3c.dom.Element>()
            .filter { it.tagName == "meta-data" }
        if (metaData.size != 1 ||
            metaData.single()
                .getAttributeNS("http://schemas.android.com/apk/res/android", "name") !=
                "android.support.FILE_PROVIDER_PATHS" ||
            metaData.single()
                .getAttributeNS("http://schemas.android.com/apk/res/android", "resource") !=
                "@xml/file_paths") {
            throw GradleException("Updater FileProvider paths resource is missing")
        }

        val pathsDocument = factory.newDocumentBuilder().parse(paths)
        val pathsRoot = pathsDocument.documentElement
        val pathChildren = (0 until pathsRoot.childNodes.length)
            .map { pathsRoot.childNodes.item(it) }
            .filterIsInstance<org.w3c.dom.Element>()
        if (pathsRoot.tagName != "paths" || pathChildren.size != 1 ||
            pathChildren.single().tagName != "cache-path") {
            throw GradleException("Expected exactly one updater cache-path entry")
        }
        val cachePath = pathChildren.single()
        if (cachePath.attributes.length != 2 || cachePath.getAttribute("name") != "updates" ||
            cachePath.getAttribute("path") != "updates/") {
            throw GradleException("Updater cache-path must remain scoped to updates/")
        }
    }
}

tasks.named("preBuild").configure { dependsOn(verifyUpdaterProviderConfiguration) }

val verifyUpdaterProviderPackageParser by tasks.registering {
    group = "verification"
    description = "Self-tests the structural aapt2 updater package verifier."
    doLast {
        UpdaterProviderVerifier.selfTest()
    }
}

androidComponents.onVariants { variant ->
    val variantName = variant.name.replaceFirstChar { it.uppercase() }
    val verifyPackagedScope = tasks.register("verify${variantName}UpdaterProviderPackage") {
        group = "verification"
        description = "Verifies the merged updater provider and packaged paths for ${variant.name}."
        dependsOn(verifyUpdaterProviderPackageParser)
        doLast {
            val updaterAuthority = "${variant.applicationId.get()}.updater.files"
            val apkDirectory = layout.buildDirectory.dir("outputs/apk/${variant.name}").get().asFile
            val variantApks = if (apkDirectory.isDirectory) {
                apkDirectory.walkTopDown()
                    .filter { file ->
                        file.isFile &&
                            file.extension.equals("apk", ignoreCase = true) &&
                            file.nameWithoutExtension.endsWith("-${variant.name}")
                    }
                    .sortedBy { it.absolutePath }
                    .toList()
            } else {
                emptyList()
            }
            if (variantApks.isEmpty()) {
                throw GradleException(
                    "No ${variant.name} APK outputs were found under $apkDirectory",
                )
            }
            val sdkDirectory = android.sdkDirectory
            val buildTools = sdkDirectory.resolve("build-tools/${android.buildToolsVersion}")
            if (!buildTools.isDirectory) {
                throw GradleException(
                    "AGP-selected Android build-tools ${android.buildToolsVersion} were not found",
                )
            }
            val executable = if (System.getProperty("os.name").startsWith("Windows")) {
                "aapt2.exe"
            } else {
                "aapt2"
            }
            val aapt2 = buildTools.resolve(executable)
            if (!aapt2.isFile) {
                throw GradleException("aapt2 was not found in AGP-selected build-tools")
            }
            fun dump(apk: File, file: String): String {
                val output = ByteArrayOutputStream()
                exec {
                    commandLine(aapt2, "dump", "xmltree", apk, "--file", file)
                    standardOutput = output
                }
                return output.toString(Charsets.UTF_8)
            }
            variantApks.forEach { apk ->
                val mergedManifest = dump(apk, "AndroidManifest.xml")
                val resources = ByteArrayOutputStream().also { output ->
                    exec {
                        commandLine(aapt2, "dump", "resources", apk)
                        standardOutput = output
                    }
                }.toString(Charsets.UTF_8)
                val filePathsResource = UpdaterProviderVerifier.resolvePackagedResource(
                    resources,
                    "xml/file_paths",
                )
                UpdaterProviderVerifier.verifyPackagedUpdaterManifest(
                    mergedManifest,
                    updaterAuthority,
                    filePathsResource.id,
                )
                val packagedPaths = dump(apk, filePathsResource.archivePath)
                UpdaterProviderVerifier.verifyPackagedUpdaterPaths(packagedPaths)
            }
        }
    }
    tasks.matching { it.name == "package$variantName" }.configureEach {
        finalizedBy(verifyPackagedScope)
    }
}
