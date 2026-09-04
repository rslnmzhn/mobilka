package com.rslnmzhn.mobilka

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Base64
import org.json.JSONObject
import java.security.SecureRandom

internal class SessionWorkspaceSafMutationHandlers(context: Context) {
    private val access = SafWorkspaceAccess(context)
    private val mutations = SafWorkspaceMutations(access)

    fun dispatch(method: String, args: Map<*, *>): Any? = when (method) {
        "rootIdentity" -> access.documentId(access.scopeRoot(args).root)
        "validateDocument" -> validateDocument(args)
        "readDocument" -> readDocument(args)
        "listDocuments" -> listDocuments(args)
        "prepareMutation" -> mutations.prepare(args)
        "commitPrepared" -> mutations.commit(args)
        "reconcilePrepared" -> mutations.reconcile(args)
        "rollbackPrepared" -> mutations.rollback(args)
        "cleanupPrepared" -> mutations.cleanup(args)
        else -> throw UnsupportedOperationException()
    }

    private fun listDocuments(args: Map<*, *>): List<Map<String, Any?>> {
        val scope = access.existingScope(args) ?: return emptyList()
        val path = access.safePath(access.string(args, "path"), true)
        val directory = access.resolve(scope.session, path, false)
            ?: brokerFail("not_found")
        if (!directory.directory) brokerFail("wrong_type")
        return access.listDocuments(directory.uri, scope.session, 501)
    }

    private fun validateDocument(args: Map<*, *>): Map<String, Any?>? {
        val scope = access.existingScope(args) ?: return null
        val path = access.safePath(access.string(args, "path"), true)
        val expected = access.parseUri(access.string(args, "documentUri"))
        access.requireChild(scope.session, expected)
        val document = access.resolve(scope.session, path, true) ?: return null
        if (access.documentId(document.uri) != access.documentId(expected)) {
            brokerFail("metadata_changed")
        }
        val hashFile = args["hash"] as? Boolean ?: brokerFail("invalid_argument")
        val snapshot = access.inspect(document.uri, scope.session, hashFile = hashFile)
        return snapshot.toMap()
    }

    private fun readDocument(args: Map<*, *>): Map<String, Any?> {
        val scope = access.existingScope(args) ?: brokerFail("not_found")
        val path = access.safePath(access.string(args, "path"), false)
        val expected = access.parseUri(access.string(args, "documentUri"))
        access.requireChild(scope.session, expected)
        val document = access.resolve(scope.session, path, false)
            ?: brokerFail("not_found")
        if (document.directory ||
            access.documentId(document.uri) != access.documentId(expected)) {
            brokerFail("metadata_changed")
        }
        val (bytes, snapshot) = access.readStable(document.uri, scope.session)
        return snapshot.toMap() + ("bytes" to bytes)
    }

    private fun SafSnapshot.toMap(): Map<String, Any?> = mapOf(
        "documentId" to documentId,
        "size" to size,
        "sha256" to hash,
        "type" to if (directory) "directory" else "file",
    )
}

internal data class SafReceipt(val id: String, val token: String, val sessionKey: String)
internal data class SafLoaded(
    val scope: SafScope,
    val hidden: Uri,
    val state: JSONObject,
    val id: String,
    var stateDocument: SafOperationStateStore.StateDocument,
    var generation: Long,
)

internal fun JSONObject.optionalString(key: String): String? =
    if (!has(key) || isNull(key)) null else getString(key)

internal fun randomWorkspaceToken(): String {
    val bytes = ByteArray(32)
    SecureRandom().nextBytes(bytes)
    return Base64.encodeToString(
        bytes,
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
    )
}

internal fun moveDocument(
    access: SafWorkspaceAccess,
    document: Uri,
    from: Uri,
    to: Uri,
): Uri = try {
    DocumentsContract.moveDocument(access.resolver, document, from, to)
        ?: brokerFail("workspace_operation_unsupported")
} catch (_: UnsupportedOperationException) {
    brokerFail("workspace_operation_unsupported")
}

internal fun renameDocument(
    access: SafWorkspaceAccess,
    document: Uri,
    name: String,
): Uri = try {
    DocumentsContract.renameDocument(access.resolver, document, name)
        ?: brokerFail("workspace_operation_unsupported")
} catch (_: UnsupportedOperationException) {
    brokerFail("workspace_operation_unsupported")
}
