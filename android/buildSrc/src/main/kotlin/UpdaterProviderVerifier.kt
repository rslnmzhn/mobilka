package mobilka.gradle

import org.gradle.api.GradleException

object UpdaterProviderVerifier {
    data class AaptXmlAttribute(val resourceName: String, val value: String)

    data class AaptXmlNode(
        val elementName: String,
        val attributes: MutableList<AaptXmlAttribute> = mutableListOf(),
        val children: MutableList<AaptXmlNode> = mutableListOf(),
    )

    data class PackagedResourceRef(val id: String, val archivePath: String)

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
                    ?: throw GradleException(
                        "aapt2 attribute has no parent at line ${index + 1}",
                    )
                val printedName = attributeMatch.groupValues[2]
                    .replace(Regex("\\(0x[0-9a-fA-F]+\\)$"), "")
                val resourceName = if (printedName.startsWith(ANDROID_NAMESPACE)) {
                    "android:${printedName.substringAfterLast(':')}"
                } else {
                    printedName
                }
                val printedValue = attributeMatch.groupValues[3]
                val value = if (printedValue.startsWith('"')) {
                    Regex("^\"([^\"]*)\"").find(printedValue)?.groupValues?.get(1)
                        ?: throw GradleException(
                            "Malformed quoted aapt2 value at line ${index + 1}",
                        )
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

    fun resolvePackagedResource(resourcesDump: String, resourceName: String): PackagedResourceRef {
        val resourcePattern = Regex("^(\\s*)resource (0x[0-9a-fA-F]+) (\\S+)\\s*$")
        val filePattern = Regex(
            "^(\\s*)\\(([^()]*)\\)\\s+\\(file\\)\\s+(\\S+)\\s+type=XML\\s*$",
        )
        val lines = resourcesDump.lines()
        val matchingBlocks = mutableListOf<Triple<String, Int, List<Pair<Int, String>>>>()
        var index = 0
        while (index < lines.size) {
            val resource = resourcePattern.matchEntire(lines[index])
            if (resource == null) {
                index++
                continue
            }
            val resourceIndent = resource.groupValues[1].length
            val id = resource.groupValues[2].lowercase()
            val name = resource.groupValues[3]
            val block = mutableListOf<Pair<Int, String>>()
            index++
            while (index < lines.size) {
                val line = lines[index]
                val nextResource = resourcePattern.matchEntire(line)
                if (nextResource != null &&
                    nextResource.groupValues[1].length <= resourceIndent) {
                    break
                }
                if (line.isNotBlank()) block.add(index + 1 to line)
                index++
            }
            if (name == resourceName) matchingBlocks.add(Triple(id, resourceIndent, block))
        }
        if (matchingBlocks.size != 1) {
            throw GradleException("Expected exactly one packaged $resourceName resource")
        }

        val (id, resourceIndent, block) = matchingBlocks.single()
        if (block.isEmpty()) {
            throw GradleException("Packaged $resourceName has no configurations")
        }
        var valueIndent: Int? = null
        val entries = block.map { (lineNumber, line) ->
            val match = filePattern.matchEntire(line)
                ?: throw GradleException(
                    "Unsupported packaged $resourceName value at line $lineNumber: $line",
                )
            val indent = match.groupValues[1].length
            if (indent <= resourceIndent || (valueIndent != null && indent != valueIndent)) {
                throw GradleException(
                    "Inconsistent packaged $resourceName value indentation at line $lineNumber",
                )
            }
            valueIndent = indent
            if (indent != resourceIndent + 2) {
                throw GradleException(
                    "Packaged $resourceName value is not a direct child at line $lineNumber",
                )
            }
            val config = match.groupValues[2]
            if (config != config.trim()) {
                throw GradleException("Invalid packaged $resourceName configuration")
            }
            config to match.groupValues[3]
        }
        if (entries.map { it.first }.toSet().size != entries.size) {
            throw GradleException("Duplicate packaged $resourceName configuration")
        }
        val archivePaths = entries.map { it.second }.distinct()
        if (archivePaths.size != 1) {
            throw GradleException("Packaged $resourceName configurations resolve differently")
        }
        val archivePath = archivePaths.single()
        val components = archivePath.split('/')
        if (archivePath.length > 512 || !SAFE_ARCHIVE_PATH.matches(archivePath) ||
            !archivePath.startsWith("res/") || !archivePath.endsWith(".xml") ||
            components.any { it.isEmpty() || it == "." || it == ".." }) {
            throw GradleException("Unsafe packaged XML path for $resourceName")
        }
        return PackagedResourceRef(id, archivePath)
    }

    fun verifyPackagedUpdaterManifest(
        dump: String,
        updaterAuthority: String,
        filePathsResourceId: String,
    ) {
        val manifest = parseAaptXmlTree(dump)
        if (manifest.elementName != "manifest") {
            throw GradleException("Packaged manifest root is invalid")
        }
        val applications = manifest.children.filter { it.elementName == "application" }
        if (applications.size != 1) {
            throw GradleException("Expected exactly one packaged application")
        }
        val providers = manifest.descendants("provider")
        val namedProviders = providers.filter {
            it.attributes.any { attribute ->
                attribute.resourceName == "android:name" &&
                    attribute.value == "androidx.core.content.FileProvider"
            }
        }
        val authorityProviders = providers.filter {
            it.attributes.any { attribute ->
                attribute.resourceName == "android:authorities" &&
                    attribute.value == updaterAuthority
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

    fun selfTest() {
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

        val multipleConfigurations = """
            resource 0x7F100000 xml/file_paths
              () (file) res/8K.xml type=XML
              (land) (file) res/8K.xml type=XML
            resource 0x7f100001 xml/other
              () (file) res/xml/other.xml type=XML
        """.trimIndent()
        val sourceStyleResource = """
            resource 0x7f100000 xml/file_paths
              () (file) res/xml/file_paths.xml type=XML
        """.trimIndent()
        check(
            resolvePackagedResource(multipleConfigurations, "xml/file_paths") ==
                PackagedResourceRef("0x7f100000", "res/8K.xml"),
        )
        check(
            resolvePackagedResource(sourceStyleResource, "xml/file_paths") ==
                PackagedResourceRef("0x7f100000", "res/xml/file_paths.xml"),
        )

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
        expectRejected("exact resource alias") {
            resolvePackagedResource(
                "resource 0x7f100000 xml/file_paths\n  () @xml/other",
                "xml/file_paths",
            )
        }
        expectRejected("non-XML archive entry") {
            resolvePackagedResource(
                "resource 0x7f100000 xml/file_paths\n  () (file) res/8K.xml type=RAW",
                "xml/file_paths",
            )
        }
        expectRejected("duplicate configuration") {
            resolvePackagedResource(
                "resource 0x7f100000 xml/file_paths\n" +
                    "  () (file) res/8K.xml type=XML\n" +
                    "  () (file) res/8K.xml type=XML",
                "xml/file_paths",
            )
        }
        expectRejected("nested otherwise-valid configuration") {
            resolvePackagedResource(
                "resource 0x7f100000 xml/file_paths\n" +
                    "  () (file) res/8K.xml type=XML\n" +
                    "    (land) (file) res/8K.xml type=XML",
                "xml/file_paths",
            )
        }
        expectRejected("differing configuration paths") {
            resolvePackagedResource(
                "resource 0x7f100000 xml/file_paths\n" +
                    "  () (file) res/8K.xml type=XML\n" +
                    "  (land) (file) res/9L.xml type=XML",
                "xml/file_paths",
            )
        }
        expectRejected("unsupported resource metadata") {
            resolvePackagedResource(
                "resource 0x7f100000 xml/file_paths\n" +
                    "  () (file) res/8K.xml type=XML\n  source=res/xml/file_paths.xml",
                "xml/file_paths",
            )
        }
        expectRejected("duplicate resource") {
            resolvePackagedResource(
                sourceStyleResource + "\n" + sourceStyleResource,
                "xml/file_paths",
            )
        }
        expectRejected("traversal archive path") {
            resolvePackagedResource(
                "resource 0x7f100000 xml/file_paths\n" +
                    "  () (file) res/../8K.xml type=XML",
                "xml/file_paths",
            )
        }
    }

    private fun AaptXmlNode.exactAttribute(resourceName: String): String {
        val matching = attributes.filter { it.resourceName == resourceName }
        if (matching.size != 1) {
            throw GradleException("Expected exactly one $resourceName attribute on $elementName")
        }
        return matching.single().value
    }

    private fun AaptXmlNode.descendants(elementName: String): List<AaptXmlNode> = buildList {
        children.forEach { child ->
            if (child.elementName == elementName) add(child)
            addAll(child.descendants(elementName))
        }
    }

    private const val ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android:"
    private val SAFE_ARCHIVE_PATH = Regex("^[A-Za-z0-9._/-]+$")
}
