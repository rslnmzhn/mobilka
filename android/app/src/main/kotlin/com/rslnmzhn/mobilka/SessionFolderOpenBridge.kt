package com.rslnmzhn.mobilka

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Opens an existing session document, never a root or a directory picker. */
class SessionFolderOpenBridge(activity: Activity, messenger: BinaryMessenger) {
    private val access = SafWorkspaceAccess(activity)
    private val main = Handler(Looper.getMainLooper())

    private companion object {
        val executor = Executors.newSingleThreadExecutor()
    }

    init {
        MethodChannel(messenger, "mobilka/session_folder").setMethodCallHandler { call, result ->
            if (call.method != "openSessionFolder") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val args = call.arguments as? Map<*, *> ?: brokerFail("invalid_argument")
                    val tree = Uri.parse(args["treeUri"] as? String ?: brokerFail("invalid_argument"))
                    if (tree.scheme != "content" || !DocumentsContract.isTreeUri(tree)) {
                        brokerFail("workspace_grant_invalid")
                    }
                    // SAF selection persists a plain /tree/<id> URI. The shared access
                    // validator expects its equivalent tree-backed root document URI.
                    val normalized = args.toMutableMap().apply {
                        this["treeUri"] = DocumentsContract.buildDocumentUriUsingTree(
                            tree, DocumentsContract.getTreeDocumentId(tree),
                        ).toString()
                    }
                    // Reuses persisted-grant validation and exact child lookup. No writes.
                    val scope = access.existingScope(normalized) ?: brokerFail("session_missing")
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(scope.session, DocumentsContract.Document.MIME_TYPE_DIR)
                        clipData = ClipData.newRawUri("session", scope.session)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    main.post {
                        try {
                            // No ACTION_OPEN_DOCUMENT_TREE fallback: it could show the root.
                            if (activity.isFinishing || activity.isDestroyed) {
                                brokerFail("folder_open_failed")
                            }
                            activity.startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            result.error("folder_open_failed", "Cannot open session folder", null)
                        }
                    }
                } catch (error: WorkspaceBrokerException) {
                    main.post { result.error(error.code, "Session folder unavailable", null) }
                } catch (_: Exception) {
                    main.post {
                        result.error("folder_open_failed", "Cannot open session folder", null)
                    }
                }
            }
        }
    }
}
