package com.rslnmzhn.mobilka

import android.net.Uri
import android.provider.DocumentsContract

internal class SafWorkspaceStateAdapter(
    private val access: SafWorkspaceAccess,
    private val hidden: Uri,
) {
    fun store() = SafOperationStateStore(
        nameOf = { document -> queryName(documentUri(document)) },
        exact = { name ->
            access.exact(hidden, name, true)?.let {
                if (it.directory) brokerFail("invalid_prepared_receipt")
                SafOperationStateStore.StateDocument(access.documentId(it.uri), it.uri)
            }
        },
        create = { name, bytes ->
            val stored = access.createBytes(hidden, hidden, name, bytes)
            SafOperationStateStore.StateDocument(stored.identity, stored.uri)
        },
        overwrite = { document, bytes ->
            access.writeStable(documentUri(document), hidden, bytes)
        },
        read = { document -> access.readStable(documentUri(document), hidden).first },
    )

    private fun documentUri(document: SafOperationStateStore.StateDocument): Uri =
        document.opaque as? Uri ?: brokerFail("invalid_prepared_receipt")

    private fun queryName(uri: Uri): String {
        var name: String? = null
        access.resolver.query(
            uri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) name = cursor.getString(0)
            if (cursor.moveToNext()) brokerFail("ambiguous_child")
        } ?: brokerFail("workspace_operation_unsupported")
        return name ?: brokerFail("metadata_unavailable")
    }
}
