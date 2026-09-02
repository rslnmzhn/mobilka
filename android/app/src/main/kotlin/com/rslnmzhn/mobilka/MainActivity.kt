package com.rslnmzhn.mobilka

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        METHOD_RUNTIME_INFO -> result.success(runtimeInfo())
                        METHOD_STAGING_PATH -> result.success(requireUpdatesDirectory().absolutePath)
                        METHOD_SAFE_LIST -> result.success(safeListUpdates())
                        METHOD_CREATE_PART -> result.success(createDownloadPart(call.arguments as Map<*, *>))
                        METHOD_IMPORT -> result.success(importVerifiedDownload(call.arguments as Map<*, *>))
                        METHOD_VERIFY -> result.success(verifyStaged(call.arguments as Map<*, *>))
                        METHOD_SAFE_DELETE -> {
                            safeDeleteUpdate(call.arguments as Map<*, *>)
                            result.success(null)
                        }
                        METHOD_PREFLIGHT_APK -> {
                            val apk = requireVerifiedFile(call.arguments as Map<*, *>)
                            result.success(preflightApk(apk).toMap())
                        }

                        METHOD_INSTALL_APK -> {
                            val apk = requireVerifiedFile(call.arguments as Map<*, *>)
                            val preflight = preflightApk(apk)
                            result.success(installApk(apk, preflight))
                        }

                        else -> result.notImplemented()
                    }
                } catch (error: UpdaterException) {
                    result.error(error.code, error.message, null)
                } catch (error: Exception) {
                    result.error(ERROR_NATIVE, error.message ?: "Android updater failed", null)
                }
            }
    }

    private fun runtimeInfo(): Map<String, Any> {
        val currentPackage = currentPackageInfo()
        val signers = signerFingerprints(currentPackage)
        if (signers.size != 1 || signers.single() != EXPECTED_SIGNER_SHA256) {
            throw UpdaterException(
                ERROR_RUNTIME_INFO,
                "The installed app signer is not trusted for updates",
            )
        }
        return mapOf(
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"),
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
            "packageName" to packageName,
            "versionCode" to currentPackage.longVersionCode,
            "signingSha256" to signers.single(),
        )
    }

    private fun requireUpdatePath(rawPath: String?, allowPartial: Boolean): File {
        if (rawPath.isNullOrBlank()) throw UpdaterException(ERROR_INVALID_ARGUMENT, "basename is required")
        val updatesDirectory = requireUpdatesDirectory()
        if (File(rawPath).name != rawPath || !isGeneratedName(rawPath)) throw UpdaterException(ERROR_INVALID_PATH, "Invalid basename")
        val rawApk = File(updatesDirectory, rawPath)
        val apk = rawApk.canonicalFile
        val path = rawApk.toPath()
        val lowerName = apk.name.lowercase(Locale.US)
        val allowedExtension = lowerName.endsWith(".apk") ||
            (allowPartial && lowerName.endsWith(".apk.part"))
        if (apk.parentFile != updatesDirectory || !allowedExtension ||
            Files.isSymbolicLink(path) || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
            throw UpdaterException(
                ERROR_INVALID_PATH,
                "APK must be a direct child of the app cache updates directory",
            )
        }
        if (!apk.isFile || !apk.canRead()) {
            throw UpdaterException(ERROR_INVALID_PATH, "APK does not exist or is not readable")
        }
        return apk
    }

    private fun requireApkPath(rawPath: String?): File = requireUpdatePath(rawPath, false)

    private fun hashStream(stream: java.io.InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun identity(path: Path, hash: String): Map<String, Any> {
        val attributes = Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        return mapOf("basename" to path.fileName.toString(), "size" to attributes.size(), "sha256" to hash,
            "identityToken" to (attributes.fileKey()?.toString() ?: "${attributes.size()}|${attributes.lastModifiedTime().toMillis()}"))
    }

    private fun requireVerifiedFile(arguments: Map<*, *>): File {
        val name = arguments[ARG_BASENAME] as? String
        val expectedSize = (arguments[ARG_EXPECTED_SIZE] as? Number)?.toLong()
        val expectedHash = arguments[ARG_EXPECTED_SHA] as? String
        val expectedIdentity = arguments[ARG_IDENTITY] as? String
        val file = requireUpdatePath(name, true)
        val path = file.toPath()
        val hash = Files.newInputStream(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use(::hashStream)
        val actual = identity(path, hash)
        if (actual["size"] != expectedSize || hash != expectedHash ||
            (expectedIdentity != null && actual["identityToken"] != expectedIdentity)) {
            throw UpdaterException(ERROR_INVALID_PATH, "Staged update identity or digest changed")
        }
        return file
    }

    private fun verifyStaged(arguments: Map<*, *>): Map<String, Any>? = try {
        val file = requireVerifiedFile(arguments)
        val hash = arguments[ARG_EXPECTED_SHA] as String
        identity(file.toPath(), hash)
    } catch (_: Exception) { null }

    private fun importVerifiedDownload(arguments: Map<*, *>): Map<String, Any> {
        val partialName = arguments[ARG_PARTIAL_NAME] as? String ?: throw UpdaterException(ERROR_INVALID_ARGUMENT, "partialName is required")
        val name = arguments[ARG_BASENAME] as? String ?: throw UpdaterException(ERROR_INVALID_ARGUMENT, "basename is required")
        val expectedSize = (arguments[ARG_EXPECTED_SIZE] as? Number)?.toLong()
        val expectedHash = arguments[ARG_EXPECTED_SHA] as? String
        if (!isGeneratedName(name) || File(name).name != name) throw UpdaterException(ERROR_INVALID_PATH, "Invalid basename")
        val root = requireUpdatesDirectory().toPath()
        if (partialName != "$name.part" || !isGeneratedName(partialName)) throw UpdaterException(ERROR_INVALID_PATH, "Invalid partial basename")
        val part = root.resolve(partialName)
        val destination = root.resolve(name)
        try {
            if (!Files.isRegularFile(part, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(part)) throw UpdaterException(ERROR_INVALID_PATH, "Unsafe partial")
            val hash = Files.newInputStream(part, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use(::hashStream)
            if (Files.size(part) != expectedSize || hash != expectedHash) throw UpdaterException(ERROR_INVALID_PATH, "Imported update digest mismatch")
            Files.move(part, destination, StandardCopyOption.ATOMIC_MOVE)
            return requireVerifiedFile(arguments).let { identity(it.toPath(), expectedHash!!) }
        } catch (error: Exception) {
            Files.deleteIfExists(part)
            throw error
        }
    }

    private fun createDownloadPart(arguments: Map<*, *>): String {
        val name = arguments[ARG_PARTIAL_NAME] as? String ?: throw UpdaterException(ERROR_INVALID_ARGUMENT, "partialName is required")
        if (!name.endsWith(".part") || !isGeneratedName(name)) throw UpdaterException(ERROR_INVALID_PATH, "Invalid partial basename")
        val root = requireUpdatesDirectory().toPath()
        val part = root.resolve(name)
        Files.newByteChannel(part, setOf(StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)).close()
        return part.toFile().absolutePath
    }

    private fun requireUpdatesDirectory(): File {
        val directory = File(cacheDir, UPDATES_DIRECTORY)
        if (!directory.exists() && !directory.mkdir()) {
            throw UpdaterException(ERROR_INVALID_PATH, "Could not create the update cache directory")
        }
        val path = directory.toPath()
        if (Files.isSymbolicLink(path) || !Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
            throw UpdaterException(ERROR_INVALID_PATH, "Update cache root is not a regular directory")
        }
        val canonical = directory.canonicalFile
        if (canonical != directory.absoluteFile) {
            throw UpdaterException(ERROR_INVALID_PATH, "Update cache root identity changed")
        }
        return canonical
    }

    private fun safeListUpdates(): List<Map<String, Any>> {
        val root = requireUpdatesDirectory().toPath()
        return Files.newDirectoryStream(root).use { stream ->
            stream.mapNotNull { path ->
                if (path.parent != root || !isGeneratedName(path.fileName.toString()) ||
                    !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path)) null
                else mapOf(
                    "basename" to path.fileName.toString(),
                    "size" to Files.size(path),
                    "modifiedMillis" to Files.getLastModifiedTime(path, LinkOption.NOFOLLOW_LINKS).toMillis(),
                    "sha256" to Files.newInputStream(path, StandardOpenOption.READ).use(::hashStream),
                    "identityToken" to (Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS).fileKey()?.toString() ?: ""),
                )
            }.toList()
        }
    }

    private fun safeDeleteUpdate(arguments: Map<*, *>) {
        val candidate = requireVerifiedFile(arguments).toPath()
        val root = requireUpdatesDirectory().toPath()
        if (candidate.parent != root) throw UpdaterException(ERROR_INVALID_PATH, "Unsafe update child")
        val before = Files.readAttributes(candidate, java.nio.file.attribute.BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        val again = Files.readAttributes(candidate, java.nio.file.attribute.BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        if (before.fileKey() != again.fileKey()) throw UpdaterException(ERROR_INVALID_PATH, "Update file changed")
        Files.delete(candidate)
    }

    private fun isGeneratedName(name: String): Boolean = Regex(
        "^mobilka-\\d+\\.\\d+\\.\\d+-(android|windows)-[A-Za-z0-9_-]+-[0-9a-f]+\\.(apk|msi)(\\.part)?$",
    ).matches(name)

    private fun preflightApk(apk: File): ApkPreflight {
        val archive = packageManager.getPackageArchiveInfo(
            apk.absolutePath,
            PackageManager.GET_SIGNING_CERTIFICATES,
        ) ?: throw UpdaterException(ERROR_INVALID_APK, "PackageManager could not parse the APK")

        if (archive.packageName != EXPECTED_PACKAGE_NAME) {
            throw UpdaterException(ERROR_PACKAGE_MISMATCH, "APK package name is not mobilka")
        }
        val currentVersionCode = currentPackageInfo().longVersionCode
        if (archive.longVersionCode <= currentVersionCode) {
            throw UpdaterException(
                ERROR_VERSION_NOT_NEWER,
                "APK versionCode must be greater than the installed versionCode",
            )
        }
        val signers = signerFingerprints(archive)
        if (signers.size != 1 || signers.single() != EXPECTED_SIGNER_SHA256) {
            throw UpdaterException(ERROR_SIGNER_MISMATCH, "APK signer does not match mobilka")
        }
        return ApkPreflight(archive.packageName, archive.longVersionCode, signers.single())
    }

    private fun installApk(apk: File, preflight: ApkPreflight): Map<String, Any> {
        if (!packageManager.canRequestPackageInstalls()) {
            val settingsIntent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
            if (settingsIntent.resolveActivity(packageManager) == null) {
                throw UpdaterException(ERROR_PERMISSION_SETTINGS, "Unknown-source settings are unavailable")
            }
            startActivity(settingsIntent)
            return mapOf("status" to STATUS_PENDING_PERMISSION)
        }

        val apkUri = try {
            FileProvider.getUriForFile(this, "$packageName.updater.files", apk)
        } catch (error: IllegalArgumentException) {
            throw UpdaterException(ERROR_INVALID_PATH, "APK is outside the update provider scope")
        }
        val installIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, APK_MIME_TYPE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (installIntent.resolveActivity(packageManager) == null) {
            throw UpdaterException(ERROR_INSTALLER_UNAVAILABLE, "No Android package installer is available")
        }
        startActivity(installIntent)
        return preflight.toMap() + ("status" to STATUS_INSTALLER_LAUNCHED)
    }

    private fun currentPackageInfo(): PackageInfo = packageManager.getPackageInfo(
        packageName,
        PackageManager.GET_SIGNING_CERTIFICATES,
    )

    private fun signerFingerprints(packageInfo: PackageInfo): List<String> {
        val signingInfo = packageInfo.signingInfo ?: return emptyList()
        return signingInfo.apkContentsSigners.map { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString(":") { byte -> "%02X".format(byte.toInt() and 0xFF) }
        }
    }

    private data class ApkPreflight(
        val packageName: String,
        val versionCode: Long,
        val signingSha256: String,
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "status" to STATUS_READY,
            "packageName" to packageName,
            "versionCode" to versionCode,
            "signingSha256" to signingSha256,
        )
    }

    private class UpdaterException(val code: String, override val message: String) : Exception(message)

    private companion object {
        const val CHANNEL_NAME = "com.rslnmzhn.mobilka/updater"
        const val METHOD_RUNTIME_INFO = "getRuntimeInfo"
        const val METHOD_STAGING_PATH = "getStagingPath"
        const val METHOD_SAFE_LIST = "safeListUpdates"
        const val METHOD_CREATE_PART = "createDownloadPart"
        const val METHOD_SAFE_DELETE = "safeDeleteUpdate"
        const val METHOD_IMPORT = "importVerifiedDownload"
        const val METHOD_VERIFY = "verifyStaged"
        const val METHOD_PREFLIGHT_APK = "preflightApk"
        const val METHOD_INSTALL_APK = "installApk"
        const val ARG_BASENAME = "basename"
        const val ARG_PARTIAL_NAME = "partialName"
        const val ARG_EXPECTED_SIZE = "expectedSize"
        const val ARG_EXPECTED_SHA = "expectedSha256"
        const val ARG_IDENTITY = "identityToken"
        const val UPDATES_DIRECTORY = "updates"
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        const val EXPECTED_PACKAGE_NAME = "com.rslnmzhn.mobilka"
        const val EXPECTED_SIGNER_SHA256 =
            "4A:76:9B:92:8D:47:82:77:30:E3:C5:E1:5A:E3:86:5C:D8:B8:99:93:13:A3:E5:79:BA:A9:B7:34:56:46:55:CD"
        const val STATUS_READY = "ready"
        const val STATUS_PENDING_PERMISSION = "pendingPermission"
        const val STATUS_INSTALLER_LAUNCHED = "installerLaunched"
        const val ERROR_INVALID_ARGUMENT = "invalidArgument"
        const val ERROR_INVALID_PATH = "invalidPath"
        const val ERROR_INVALID_APK = "invalidApk"
        const val ERROR_PACKAGE_MISMATCH = "packageMismatch"
        const val ERROR_VERSION_NOT_NEWER = "versionNotNewer"
        const val ERROR_SIGNER_MISMATCH = "signerMismatch"
        const val ERROR_PERMISSION_SETTINGS = "permissionSettingsUnavailable"
        const val ERROR_INSTALLER_UNAVAILABLE = "installerUnavailable"
        const val ERROR_RUNTIME_INFO = "runtimeInfoUnavailable"
        const val ERROR_NATIVE = "nativeError"
    }
}
