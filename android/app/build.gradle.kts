import java.util.Properties
import java.io.ByteArrayOutputStream
import javax.xml.XMLConstants
import javax.xml.parsers.DocumentBuilderFactory

data class AaptXmlAttribute(val resourceName: String, val value: String)

data class AaptXmlNode(
    val elementName: String,
    val attributes: MutableList<AaptXmlAttribute> = mutableListOf(),
    val children: MutableList<AaptXmlNode> = mutableListOf(),
)

fun parseAaptXmlTree(dump: String): AaptXmlNode {
    val elementPattern = Regex("^(\\s*)E: ([^\\s(]+)(?: \\(line=\\d+\\))?\\s*$")
    val attributePattern = Regex("^(\\s*)A: ([^=]+)=(.*)$")
    val stack = mutableListOf<Pair<Int, AaptXmlNode>>()
    val roots = mutableListOf<AaptXmlNode>()

    dump.lineSequence().filter { it.isNotBlank() }.forEachIndexed { index, line ->
        val elementMatch = elementPattern.matchEntire(line)
        if (elementMatch != null) {
            val indent = elementMatch.groupValues[1].length
            val node = AaptXmlNode(elementMatch.groupValues[2])
            while (stack.isNotEmpty() && stack.last().first >= indent) stack.removeLast()
            if (stack.isEmpty()) roots.add(node) else stack.last().second.children.add(node)
            stack.add(indent to node)
            return@forEachIndexed
        }

        val attributeMatch = attributePattern.matchEntire(line)
        if (attributeMatch != null) {
            val indent = attributeMatch.groupValues[1].length
            val owner = stack.lastOrNull { it.first < indent }?.second
                ?: throw GradleException("aapt2 attribute has no parent at line ${index + 1}")
            val printedName = attributeMatch.groupValues[2]
                .replace(Regex("\\(0x[0-9a-fA-F]+\\)$"), "")
            val resourceName = if (printedName.startsWith(
                    "http://schemas.android.com/apk/res/android:",
                )) {
                "android:${printedName.substringAfterLast(':')}"
            } else {
                printedName
            }
            val printedValue = attributeMatch.groupValues[3]
            val value = if (printedValue.startsWith('"')) {
                Regex("^\"([^\"]*)\"").find(printedValue)?.groupValues?.get(1)
                    ?: throw GradleException("Malformed quoted aapt2 value at line ${index + 1}")
            } else {
                printedValue.substringBefore(' ').trim()
            }
            owner.attributes.add(AaptXmlAttribute(resourceName, value))
            return@forEachIndexed
        }

        if (!line.trimStart().startsWith("N: ")) {
            throw GradleException("Unsupported aapt2 xmltree line ${index + 1}: $line")
        }
    }
    if (roots.size != 1) throw GradleException("Expected exactly one aapt2 XML root")
    return roots.single()
}

fun AaptXmlNode.exactAttribute(resourceName: String): String {
    val matching = attributes.filter { it.resourceName == resourceName }
    if (matching.size != 1) {
        throw GradleException("Expected exactly one $resourceName attribute on $elementName")
    }
    return matching.single().value
}

fun AaptXmlNode.descendants(elementName: String): List<AaptXmlNode> = buildList {
    children.forEach { child ->
        if (child.elementName == elementName) add(child)
        addAll(child.descendants(elementName))
    }
}

fun resolvePackagedResourceId(resourcesDump: String, resourceName: String): String {
    val matches = Regex(
        "(?m)^\\s*resource (0x[0-9a-fA-F]+) ${Regex.escape(resourceName)}\\s*$",
    ).findAll(resourcesDump).toList()
    if (matches.size != 1) {
        throw GradleException("Expected exactly one packaged $resourceName resource")
    }
    return matches.single().groupValues[1].lowercase()
}

fun verifyPackagedUpdaterManifest(
    dump: String,
    updaterAuthority: String,
    filePathsResourceId: String,
) {
    val manifest = parseAaptXmlTree(dump)
    if (manifest.elementName != "manifest") throw GradleException("Packaged manifest root is invalid")
    val applications = manifest.children.filter { it.elementName == "application" }
    if (applications.size != 1) throw GradleException("Expected exactly one packaged application")
    val providers = manifest.descendants("provider")
    val namedProviders = providers.filter {
        it.attributes.any { attribute ->
            attribute.resourceName == "android:name" &&
                attribute.value == "androidx.core.content.FileProvider"
        }
    }
    val authorityProviders = providers.filter {
        it.attributes.any { attribute ->
            attribute.resourceName == "android:authorities" && attribute.value == updaterAuthority
        }
    }
    if (namedProviders.size != 1 || authorityProviders.size != 1 ||
        namedProviders.single() !== authorityProviders.single()) {
        throw GradleException("Packaged updater FileProvider is missing or ambiguous")
    }
    val provider = namedProviders.single()
    if (provider !in applications.single().children) {
        throw GradleException("Packaged updater FileProvider is not an application child")
    }
    if (provider.exactAttribute("android:name") != "androidx.core.content.FileProvider" ||
        provider.exactAttribute("android:authorities") != updaterAuthority ||
        provider.exactAttribute("android:exported") != "false" ||
        provider.exactAttribute("android:grantUriPermissions") != "true") {
        throw GradleException("Packaged updater FileProvider declaration is not exact")
    }
    val metaData = provider.children.filter { it.elementName == "meta-data" }
    if (metaData.size != 1 ||
        metaData.single().exactAttribute("android:name") !=
        "android.support.FILE_PROVIDER_PATHS" ||
        metaData.single().exactAttribute("android:resource").lowercase() !=
        "@${filePathsResourceId.lowercase()}") {
        throw GradleException("Packaged updater FileProvider metadata is not exact")
    }
}

fun verifyPackagedUpdaterPaths(dump: String) {
    val paths = parseAaptXmlTree(dump)
    if (paths.elementName != "paths" || paths.children.size != 1) {
        throw GradleException("Packaged updater paths must contain exactly one path entry")
    }
    val cachePath = paths.children.single()
    if (cachePath.elementName != "cache-path" || cachePath.children.isNotEmpty() ||
        cachePath.attributes.size != 2 ||
        cachePath.exactAttribute("name") != "updates" ||
        cachePath.exactAttribute("path") != "updates/") {
        throw GradleException("Packaged updater cache-path is not exactly updates/")
    }
}

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
        val provider = """
          E: provider (line=1)
            A: http://schemas.android.com/apk/res/android:name(0x01010003)="androidx.core.content.FileProvider" (Raw: "androidx.core.content.FileProvider")
            A: http://schemas.android.com/apk/res/android:exported(0x01010010)=false
            A: http://schemas.android.com/apk/res/android:authorities(0x01010018)="com.example.app.updater.files" (Raw: "com.example.app.updater.files")
            A: http://schemas.android.com/apk/res/android:grantUriPermissions(0x0101001b)=true
              E: meta-data (line=2)
                A: http://schemas.android.com/apk/res/android:name(0x01010003)="android.support.FILE_PROVIDER_PATHS" (Raw: "android.support.FILE_PROVIDER_PATHS")
                A: http://schemas.android.com/apk/res/android:resource(0x01010025)=@0x7f100000
        """.trimIndent()
        fun manifest(vararg providerDumps: String) = buildString {
            appendLine("E: manifest (line=1)")
            appendLine("  E: application (line=1)")
            providerDumps.forEach { dump ->
                dump.lineSequence().forEach { appendLine("    $it") }
            }
        }
        val validPaths = """
            E: paths (line=1)
              E: cache-path (line=2)
                A: name="updates" (Raw: "updates")
                A: path="updates/" (Raw: "updates/")
        """.trimIndent()
        verifyPackagedUpdaterManifest(
            manifest(provider),
            "com.example.app.updater.files",
            "0x7f100000",
        )
        verifyPackagedUpdaterPaths(validPaths)

        fun expectRejected(label: String, verification: () -> Unit) {
            try {
                verification()
            } catch (_: GradleException) {
                return
            }
            throw GradleException("Structural verifier accepted malicious fixture: $label")
        }
        expectRejected("duplicate updater provider") {
            verifyPackagedUpdaterManifest(
                manifest(provider, provider),
                "com.example.app.updater.files",
                "0x7f100000",
            )
        }
        expectRejected("additional broad path") {
            verifyPackagedUpdaterPaths(
                validPaths + "\n  E: cache-path (line=3)\n    A: name=\"broad\"\n    A: path=\".\"",
            )
        }
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
            val buildTools = sdkDirectory.resolve("build-tools").listFiles()
                ?.filter { it.isDirectory }
                ?.maxByOrNull { it.name }
                ?: throw GradleException("Android build-tools were not found")
            val executable = if (System.getProperty("os.name").startsWith("Windows")) {
                "aapt2.exe"
            } else {
                "aapt2"
            }
            val aapt2 = buildTools.resolve(executable)
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
                val filePathsResourceId = resolvePackagedResourceId(resources, "xml/file_paths")
                verifyPackagedUpdaterManifest(
                    mergedManifest,
                    updaterAuthority,
                    filePathsResourceId,
                )
                val packagedPaths = dump(apk, "res/xml/file_paths.xml")
                verifyPackagedUpdaterPaths(packagedPaths)
            }
        }
    }
    tasks.matching { it.name == "package$variantName" }.configureEach {
        finalizedBy(verifyPackagedScope)
    }
}
