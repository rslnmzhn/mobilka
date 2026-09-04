package com.rslnmzhn.mobilka

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import java.io.ByteArrayOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest

internal class WorkspaceBrokerException(val code: String) : Exception()
internal fun brokerFail(code: String): Nothing = throw WorkspaceBrokerException(code)

internal data class SafDoc(val uri: Uri, val directory: Boolean)
internal data class SafScope(val tree: Uri, val session: Uri)
internal data class SafScopeRoot(
    val tree: Uri,
    val root: Uri,
    val sessionKey: String,
)
internal data class SafSnapshot(
    val documentId: String,
    val size: Long,
    val hash: String?,
    val directory: Boolean,
)
internal data class SafStored(val uri: Uri, val identity: String, val hash: String)

internal class SafWorkspaceAccess(context: Context) {
    val resolver: ContentResolver = context.contentResolver

    fun scopeRoot(args: Map<*, *>): SafScopeRoot {
        val tree = parseUri(string(args, "treeUri"), "workspace_grant_invalid")
        if (!DocumentsContract.isTreeUri(tree)) brokerFail("workspace_grant_invalid")
        val permission = resolver.persistedUriPermissions.singleOrNull {
            it.uri.scheme == tree.scheme && it.uri.authority == tree.authority &&
                treeId(it.uri) == treeId(tree)
        } ?: brokerFail("workspace_grant_invalid")
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        if (!permission.isReadPermission || !permission.isWritePermission || flags == 0) {
            brokerFail("workspace_grant_invalid")
        }
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, treeId(tree))
        nullableString(args, "rootIdentity")?.let {
            if (it != documentId(root)) brokerFail("workspace_binding_changed")
        }
        val sessionKey = safePath(string(args, "sessionKey"), false).singleOrNull()
            ?: brokerFail("invalid_argument")
        return SafScopeRoot(tree, root, sessionKey)
    }

    fun mutationScope(args: Map<*, *>): SafScope {
        val base = scopeRoot(args)
        val sessions = exact(base.root, "sessions", true)
            ?: createDirectory(base.root, "sessions")
        val session = exact(sessions.uri, base.sessionKey, true)
            ?: createDirectory(sessions.uri, base.sessionKey)
        if (!sessions.directory || !session.directory) brokerFail("wrong_type")
        return SafScope(base.tree, session.uri)
    }

    fun existingScope(args: Map<*, *>): SafScope? {
        val base = scopeRoot(args)
        val sessions = exact(base.root, "sessions", true) ?: return null
        val session = exact(sessions.uri, base.sessionKey, true) ?: return null
        if (!sessions.directory || !session.directory) brokerFail("wrong_type")
        return SafScope(base.tree, session.uri)
    }

    fun resolve(root: Uri, parts: List<String>, missing: Boolean): SafDoc? {
        var current = root
        for ((index, name) in parts.withIndex()) {
            val child = exact(current, name, missing && index == parts.lastIndex)
                ?: return null
            if (index != parts.lastIndex && !child.directory) brokerFail("wrong_type")
            current = child.uri
            if (index == parts.lastIndex) return child
        }
        return SafDoc(current, true)
    }

    fun resolveParent(root: Uri, parts: List<String>): Uri {
        if (parts.size == 1) return root
        val parent = resolve(root, parts.dropLast(1), false)
            ?: brokerFail("parent_missing")
        if (!parent.directory) brokerFail("wrong_type")
        return parent.uri
    }

    fun exact(parent: Uri, name: String, missing: Boolean): SafDoc? {
        requireChild(parent, parent)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            parent,
            documentId(parent),
        )
        val matches = mutableListOf<SafDoc>()
        resolver.query(children, PROJECTION, null, null, null)?.use { cursor ->
            var rows = 0
            while (cursor.moveToNext()) {
                if (++rows > MAX_CURSOR_ROWS) brokerFail("listing_limit_exceeded")
                if (cursor.getString(1) != name) continue
                val uri = DocumentsContract.buildDocumentUriUsingTree(
                    parent,
                    cursor.getString(0),
                )
                requireChild(parent, uri)
                matches += SafDoc(
                    uri,
                    cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR,
                )
                if (matches.size > 1) brokerFail("ambiguous_child")
            }
        } ?: brokerFail("workspace_operation_unsupported")
        if (matches.isEmpty() && missing) return null
        if (matches.size != 1) brokerFail("ambiguous_child")
        return matches.single()
    }

    fun childByDocumentId(parent: Uri, expectedId: String): SafDoc? {
        requireChild(parent, parent)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            parent,
            documentId(parent),
        )
        var result: SafDoc? = null
        resolver.query(children, PROJECTION, null, null, null)?.use { cursor ->
            var rows = 0
            while (cursor.moveToNext()) {
                if (++rows > MAX_CURSOR_ROWS) brokerFail("listing_limit_exceeded")
                if (cursor.getString(0) != expectedId) continue
                if (result != null) brokerFail("ambiguous_child")
                result = SafDoc(
                    DocumentsContract.buildDocumentUriUsingTree(parent, expectedId),
                    cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR,
                )
            }
        } ?: brokerFail("workspace_operation_unsupported")
        return result
    }

    fun requireStableMoveIdentity(hidden: Uri, operationId: String) {
        val first = exact(hidden, ".probe-a", true) ?: createDirectory(hidden, ".probe-a")
        val second = exact(hidden, ".probe-b", true) ?: createDirectory(hidden, ".probe-b")
        val probeName = "$operationId.identity-probe"
        val renamedName = "$operationId.identity-probe-renamed"
        val probe = try {
            createBytes(first.uri, hidden, probeName, byteArrayOf())
        } catch (_: Exception) {
            brokerFail("saf_two_phase_unsupported")
        }
        try {
            val moved = moveDocument(this, probe.uri, first.uri, second.uri)
            if (documentId(moved) != probe.identity) brokerFail("saf_two_phase_unsupported")
            val renamed = renameDocument(this, moved, renamedName)
            if (documentId(renamed) != probe.identity ||
                exact(second.uri, renamedName, false)?.let { documentId(it.uri) } !=
                probe.identity) brokerFail("saf_two_phase_unsupported")
            val restored = moveDocument(this, renamed, second.uri, first.uri)
            if (documentId(restored) != probe.identity) brokerFail("saf_two_phase_unsupported")
            val originalName = renameDocument(this, restored, probeName)
            if (documentId(originalName) != probe.identity ||
                !DocumentsContract.deleteDocument(resolver, originalName)) {
                brokerFail("saf_two_phase_unsupported")
            }
        } catch (_: WorkspaceBrokerException) {
            brokerFail("saf_two_phase_unsupported")
        } catch (_: Exception) {
            brokerFail("saf_two_phase_unsupported")
        }
    }

    fun inspect(uri: Uri, scope: Uri, hashFile: Boolean): SafSnapshot {
        validateDocumentUri(scope, uri)
        val before = querySnapshot(uri)
        if (before.directory || !hashFile) return before
        val bytes = readBounded(uri, scope, before)
        val after = querySnapshot(uri)
        if (after.documentId != before.documentId || after.size != before.size ||
            sha256(bytes) != after.hash && after.hash != null) {
            brokerFail("metadata_changed")
        }
        return before.copy(hash = sha256(bytes))
    }

    fun readStable(uri: Uri, scope: Uri): Pair<ByteArray, SafSnapshot> {
        validateDocumentUri(scope, uri)
        val before = querySnapshot(uri)
        if (before.directory) brokerFail("wrong_type")
        val bytes = readBounded(uri, scope, before)
        val after = querySnapshot(uri)
        val digest = sha256(bytes)
        if (after.documentId != before.documentId || after.size != before.size ||
            after.directory) brokerFail("metadata_changed")
        return bytes to before.copy(hash = digest)
    }

    private fun readBounded(uri: Uri, scope: Uri, before: SafSnapshot): ByteArray {
        validateDocumentUri(scope, uri)
        val output = ByteArrayOutputStream()
        resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
            FileInputStream(descriptor.fileDescriptor).use { input ->
                val buffer = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > MAX_BYTES) brokerFail("workspace_file_too_large")
                    output.write(buffer, 0, count)
                }
            }
        } ?: brokerFail("workspace_operation_unsupported")
        validateDocumentUri(scope, uri)
        val reopened = querySnapshot(uri)
        val bytes = output.toByteArray()
        if (reopened.documentId != before.documentId ||
            reopened.size != before.size || bytes.size.toLong() != before.size) {
            brokerFail("metadata_changed")
        }
        return bytes
    }

    fun writeStable(uri: Uri, scope: Uri, bytes: ByteArray): SafSnapshot {
        validateDocumentUri(scope, uri)
        val identity = documentId(uri)
        resolver.openFileDescriptor(uri, "rwt")?.use { descriptor ->
            FileOutputStream(descriptor.fileDescriptor).use { output ->
                output.write(bytes)
                output.flush()
                output.fd.sync()
            }
        } ?: brokerFail("workspace_operation_unsupported")
        val (actual, snapshot) = readStable(uri, scope)
        if (snapshot.documentId != identity || !actual.contentEquals(bytes)) {
            brokerFail("mutation_indeterminate")
        }
        return snapshot
    }

    fun listDocuments(parent: Uri, scope: Uri, maxEntries: Int): List<Map<String, Any?>> {
        if (maxEntries !in 1..MAX_CURSOR_ROWS) brokerFail("invalid_argument")
        requireChild(scope, parent)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            parent,
            documentId(parent),
        )
        val result = mutableListOf<Map<String, Any?>>()
        resolver.query(children, LIST_PROJECTION, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (result.size >= maxEntries) brokerFail("too_many_entries")
                val id = cursor.getString(0)
                val uri = DocumentsContract.buildDocumentUriUsingTree(parent, id)
                requireChild(scope, uri)
                result += mapOf(
                    "uri" to uri.toString(),
                    "documentId" to id,
                    "name" to cursor.getString(1),
                    "isDirectory" to (cursor.getString(2) ==
                        DocumentsContract.Document.MIME_TYPE_DIR),
                    "mimeType" to cursor.getString(2),
                    "size" to if (cursor.getString(2) ==
                        DocumentsContract.Document.MIME_TYPE_DIR) {
                        0L
                    } else if (cursor.isNull(3)) {
                        null
                    } else {
                        cursor.getLong(3)
                    },
                )
            }
        } ?: brokerFail("workspace_operation_unsupported")
        return result
    }

    fun createBytes(parent: Uri, scope: Uri, name: String, bytes: ByteArray): SafStored {
        if (exact(parent, name, true) != null) brokerFail("operation_exists")
        val uri = DocumentsContract.createDocument(
            resolver,
            parent,
            "application/octet-stream",
            name,
        ) ?: brokerFail("mutation_indeterminate")
        validateDocumentUri(scope, uri)
        writeStable(uri, scope, bytes)
        val found = exact(parent, name, false) ?: brokerFail("mutation_indeterminate")
        if (documentId(found.uri) != documentId(uri)) brokerFail("mutation_indeterminate")
        return SafStored(uri, documentId(uri), sha256(bytes))
    }

    fun createDirectory(parent: Uri, name: String): SafDoc {
        if (exact(parent, name, true) != null) brokerFail("operation_exists")
        val uri = DocumentsContract.createDocument(
            resolver,
            parent,
            DocumentsContract.Document.MIME_TYPE_DIR,
            name,
        ) ?: brokerFail("mutation_indeterminate")
        val found = exact(parent, name, false) ?: brokerFail("mutation_indeterminate")
        if (!found.directory || documentId(found.uri) != documentId(uri)) {
            brokerFail("mutation_indeterminate")
        }
        return found
    }

    fun verifyExpectation(
        doc: SafDoc?,
        missing: Boolean,
        identity: String?,
        expectedHash: String?,
        scope: Uri,
    ) {
        if (missing) {
            if (doc != null) brokerFail("stale_target")
            return
        }
        if (doc == null || identity == null || documentId(doc.uri) != identity) {
            brokerFail("stale_target")
        }
        if (!doc.directory) {
            if (expectedHash == null || inspect(doc.uri, scope, true).hash != expectedHash) {
                brokerFail("stale_target")
            }
        }
    }

    fun requireChild(tree: Uri, child: Uri) {
        requireContent(tree)
        requireContent(child)
        if (tree.authority == child.authority &&
            DocumentsContract.isChildDocument(resolver, tree, child)) return
        if (tree.authority != child.authority || treeId(tree) != treeId(child) ||
            documentId(tree) != documentId(child)) brokerFail("unsafe_path")
    }

    private fun validateDocumentUri(scope: Uri, document: Uri) {
        requireChild(scope, document)
        val id = documentId(document)
        if (id.isEmpty()) brokerFail("unsafe_path")
    }

    fun parseUri(value: String, code: String = "unsafe_path"): Uri {
        val uri = Uri.parse(value)
        try {
            requireContent(uri)
            documentId(uri)
        } catch (_: Exception) {
            brokerFail(code)
        }
        return uri
    }

    fun documentId(uri: Uri): String = try {
        DocumentsContract.getDocumentId(uri)
    } catch (_: Exception) {
        brokerFail("unsafe_path")
    }

    fun treeId(uri: Uri): String = try {
        DocumentsContract.getTreeDocumentId(uri)
    } catch (_: Exception) {
        brokerFail("workspace_grant_invalid")
    }

    private fun requireContent(uri: Uri) {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT || uri.authority.isNullOrEmpty()) {
            brokerFail("unsafe_path")
        }
    }

    private fun querySnapshot(uri: Uri): SafSnapshot {
        requireContent(uri)
        var result: SafSnapshot? = null
        resolver.query(uri, INSPECT_PROJECTION, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val size = if (cursor.isNull(2)) null else cursor.getLong(2)
                val directory = cursor.getString(1) ==
                    DocumentsContract.Document.MIME_TYPE_DIR
                if (!directory && (size == null || size < 0 || size > MAX_BYTES)) {
                    brokerFail(if (size != null && size > MAX_BYTES) {
                        "workspace_file_too_large"
                    } else {
                        "metadata_unavailable"
                    })
                }
                result = SafSnapshot(cursor.getString(0), size ?: 0, null, directory)
            }
            if (cursor.moveToNext()) brokerFail("ambiguous_child")
        } ?: brokerFail("workspace_operation_unsupported")
        return result ?: brokerFail("metadata_unavailable")
    }

    fun safePath(value: String, root: Boolean): List<String> {
        if (value.isEmpty()) return if (root) emptyList() else brokerFail("invalid_argument")
        if (value.length > 1024 || value.startsWith('/') || value.endsWith('/')) {
            brokerFail("invalid_argument")
        }
        val parts = value.split('/')
        if (parts.size > 16 || parts.any { !PART.matches(it) || it.startsWith('.') }) {
            brokerFail("invalid_argument")
        }
        return parts
    }

    fun string(map: Map<*, *>, key: String): String =
        map[key] as? String ?: brokerFail("invalid_argument")

    fun nullableString(map: Map<*, *>, key: String): String? = map[key] as? String

    fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    companion object {
        const val HIDDEN = ".mobilka-workspace"
        const val MAX_BYTES = 1024 * 1024
        const val MAX_CURSOR_ROWS = 513
        val OPERATION_ID = Regex("^[A-Za-z0-9_-]{32}$")
        val TOKEN = Regex("^[A-Za-z0-9_-]{43}$")
        private val PART = Regex("^[^./\\\\:][^/\\\\:]{0,127}$")
        private val PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        private val INSPECT_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
        )
        private val LIST_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
        )
    }
}
