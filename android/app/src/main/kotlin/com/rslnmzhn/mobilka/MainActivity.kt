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

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        METHOD_RUNTIME_INFO -> result.success(runtimeInfo())
                        METHOD_PREFLIGHT_APK -> {
                            val apk = requireApkPath(call.argument<String>(ARG_APK_PATH))
                            result.success(preflightApk(apk).toMap())
                        }

                        METHOD_INSTALL_APK -> {
                            val apk = requireApkPath(call.argument<String>(ARG_APK_PATH))
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

    private fun requireApkPath(rawPath: String?): File {
        if (rawPath.isNullOrBlank()) {
            throw UpdaterException(ERROR_INVALID_ARGUMENT, "apkPath is required")
        }
        val updatesDirectory = File(cacheDir, UPDATES_DIRECTORY).apply {
            if (!exists() && !mkdirs()) {
                throw UpdaterException(ERROR_INVALID_PATH, "Could not create the update cache directory")
            }
        }.canonicalFile
        val apk = File(rawPath).canonicalFile
        if (apk.parentFile != updatesDirectory || !apk.name.lowercase(Locale.US).endsWith(".apk")) {
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
        const val METHOD_PREFLIGHT_APK = "preflightApk"
        const val METHOD_INSTALL_APK = "installApk"
        const val ARG_APK_PATH = "apkPath"
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
