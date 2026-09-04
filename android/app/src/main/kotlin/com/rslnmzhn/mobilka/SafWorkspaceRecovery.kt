package com.rslnmzhn.mobilka

import android.net.Uri
import android.provider.DocumentsContract

internal class SafWorkspaceRecovery(
    private val access: SafWorkspaceAccess,
    private val load: (Map<*, *>) -> SafLoaded,
    private val persist: (SafLoaded, String) -> Unit,
) {
    fun reconcileLoaded(loaded: SafLoaded): String {
        val state = loaded.state
        val phase = state.getString("phase")
        if (phase == "rolledBack") return "rolledBack"
        val path = access.safePath(state.getString("path"), false)
        val source = access.resolve(loaded.scope.session, path, true)
        val result = when (state.getString("operation")) {
            "write_file", "apply_patch" -> reconcileWrite(loaded, source)
            "delete_file" -> reconcileDelete(loaded, source)
            "move_file" -> reconcileMove(loaded, source)
            "make_directory" -> reconcileCreate(loaded, source, true)
            else -> "indeterminate"
        }
        if (result == "committed" && phase != "committed") persist(loaded, "committed")
        return result
    }

    private fun reconcileWrite(loaded: SafLoaded, source: SafDoc?): String {
        val state = loaded.state
        val afterHash = state.optionalString("stageHash") ?: return "indeterminate"
        if (!state.getBoolean("expectMissing")) {
            val oldId = state.optionalString("sourceDocId") ?: return "indeterminate"
            val stageId = state.optionalString("stageDocId") ?: return "indeterminate"
            val path = access.safePath(state.getString("path"), false)
            val parent = access.resolveParent(loaded.scope.session, path)
            val quarantined = access.childByDocumentId(loaded.hidden, oldId)
            val oldInParent = access.childByDocumentId(parent, oldId)
            if (source != null) {
                if (source.directory) return "indeterminate"
                val sourceId = access.documentId(source.uri)
                val sourceHash = access.inspect(source.uri, loaded.scope.session, true).hash
                if (sourceId == stageId && sourceHash == afterHash &&
                    quarantined != null && verifiedOld(loaded, quarantined)) return "committed"
                if (sourceId == oldId && sourceHash == state.optionalString("expectedHash") &&
                    quarantined == null) return "notCommitted"
                return "indeterminate"
            }
            if (oldInParent != null && verifiedOld(loaded, oldInParent)) {
                return "notCommitted"
            }
            if (quarantined == null || !verifiedOld(loaded, quarantined)) {
                return "indeterminate"
            }
            val staged = access.childByDocumentId(loaded.hidden, stageId)
                ?: access.childByDocumentId(parent, stageId)
                ?: return "indeterminate"
            if (staged.directory || access.inspect(staged.uri, loaded.scope.tree, true).hash !=
                afterHash) return "indeterminate"
            return "notCommitted"
        }
        return reconcileCreate(loaded, source, false)
    }

    private fun reconcileCreate(
        loaded: SafLoaded,
        source: SafDoc?,
        directory: Boolean,
    ): String {
        val state = loaded.state
        val stageIdentity = state.optionalString("stageDocId") ?: return "indeterminate"
        val stage = access.childByDocumentId(loaded.hidden, stageIdentity)
        if (source != null) {
            if (source.directory != directory ||
                access.documentId(source.uri) != stageIdentity) return "indeterminate"
            if (!directory && access.inspect(source.uri, loaded.scope.session, true).hash !=
                state.optionalString("stageHash")) return "indeterminate"
            return "committed"
        }
        if (stage != null && access.documentId(stage.uri) == stageIdentity) {
            if (!directory && access.inspect(stage.uri, loaded.scope.tree, true).hash !=
                state.optionalString("stageHash")) return "indeterminate"
            return "notCommitted"
        }
        val path = access.safePath(state.getString("path"), false)
        val parent = access.resolveParent(loaded.scope.session, path)
        val movedByName = access.exact(parent, "${loaded.id}.stage", true)
        if (movedByName != null && access.documentId(movedByName.uri) == stageIdentity &&
            movedByName.directory == directory) {
            if (!directory && access.inspect(
                    movedByName.uri,
                    loaded.scope.session,
                    true,
                ).hash != state.optionalString("stageHash")) return "indeterminate"
            return "notCommitted"
        }
        val movedById = access.childByDocumentId(parent, stageIdentity)
        if (movedById != null && movedById.directory == directory) return "notCommitted"
        val moved = state.optionalString("movedUri")?.let(Uri::parse)
        if (moved != null && safeIdentity(moved) == stageIdentity) return "notCommitted"
        return "indeterminate"
    }

    private fun reconcileDelete(loaded: SafLoaded, source: SafDoc?): String {
        val state = loaded.state
        val expected = state.optionalString("expectedIdentity") ?: return "indeterminate"
        if (source != null) {
            return if (access.documentId(source.uri) == expected &&
                access.inspect(source.uri, loaded.scope.session, true).hash ==
                state.optionalString("expectedHash")) "notCommitted" else "indeterminate"
        }
        val sourceDocId = state.optionalString("sourceDocId") ?: return "indeterminate"
        val quarantined = access.childByDocumentId(loaded.hidden, sourceDocId)
            ?: return "indeterminate"
        val named = access.exact(loaded.hidden, "${loaded.id}.old", true)
            ?: return "notCommitted"
        return if (access.documentId(named.uri) == sourceDocId &&
            access.documentId(quarantined.uri) == sourceDocId &&
            access.inspect(named.uri, loaded.scope.tree, true).hash ==
            state.optionalString("expectedHash")) "committed" else "indeterminate"
    }

    private fun reconcileMove(loaded: SafLoaded, source: SafDoc?): String {
        val state = loaded.state
        val expected = state.optionalString("expectedIdentity") ?: return "indeterminate"
        val destination = access.safePath(state.getString("destination"), false)
        val target = access.resolve(loaded.scope.session, destination, true)
        if (source == null && target != null && access.documentId(target.uri) == expected &&
            access.inspect(target.uri, loaded.scope.session, true).hash ==
            state.optionalString("expectedHash")) return "committed"
        if (source != null && access.documentId(source.uri) == expected && target == null) {
            return "notCommitted"
        }
        val moved = state.optionalString("movedUri")?.let(Uri::parse)
            ?: access.childByDocumentId(
                access.resolveParent(loaded.scope.session, destination),
                expected,
            )?.uri
        return if (source == null && moved != null && safeIdentity(moved) == expected) {
            "notCommitted"
        } else {
            "indeterminate"
        }
    }

    fun rollback(loaded: SafLoaded) {
        if (loaded.state.getString("phase") == "rolledBack") return
        val reconciled = reconcileLoaded(loaded)
        if (loaded.state.getString("phase") == "committed") {
            brokerFail("already_committed")
        }
        if (reconciled == "indeterminate") {
            brokerFail("mutation_indeterminate")
        }
        val state = loaded.state
        val path = access.safePath(state.getString("path"), false)
        when (state.getString("operation")) {
            "write_file", "apply_patch" -> rollbackWrite(loaded, path)
            "delete_file" -> rollbackDelete(loaded, path)
            "move_file" -> rollbackMove(loaded, path)
            "make_directory" -> rollbackCreate(loaded, path)
        }
        persist(loaded, "rolledBack")
    }

    private fun rollbackWrite(loaded: SafLoaded, path: List<String>) {
        val state = loaded.state
        val current = access.resolve(loaded.scope.session, path, true)
        if (state.getBoolean("expectMissing")) {
            rollbackCreate(loaded, path)
            return
        }
        if (current != null) {
            if (!current.directory && access.documentId(current.uri) ==
                state.getString("sourceDocId") &&
                access.inspect(current.uri, loaded.scope.session, true).hash ==
                state.getString("expectedHash")) return
            // A replacement or manually-created target is never overwritten.
            brokerFail("mutation_indeterminate")
        }
        val parent = access.resolveParent(loaded.scope.session, path)
        val stageId = state.getString("stageDocId")
        val stagedInParent = access.childByDocumentId(parent, stageId)
        if (stagedInParent != null) {
            if (stagedInParent.directory || access.inspect(
                    stagedInParent.uri,
                    loaded.scope.tree,
                    true,
                ).hash != state.getString("stageHash")) brokerFail("mutation_indeterminate")
            persist(loaded, "rollbackStageMoving")
            val hiddenStage = moveDocument(access, stagedInParent.uri, parent, loaded.hidden)
            if (access.documentId(hiddenStage) != stageId) brokerFail("mutation_indeterminate")
            persist(loaded, "rollbackStageMoved")
        }
        restoreQuarantined(loaded, path, "rollbackOldMoving", "rollbackOldMoved")
    }

    private fun rollbackDelete(loaded: SafLoaded, path: List<String>) {
        val state = loaded.state
        val existing = access.resolve(loaded.scope.session, path, true)
        if (existing != null) {
            if (existing.directory || access.documentId(existing.uri) !=
                state.getString("sourceDocId") ||
                access.inspect(existing.uri, loaded.scope.session, true).hash !=
                state.getString("expectedHash")) brokerFail("mutation_indeterminate")
            return
        }
        restoreQuarantined(loaded, path, "rollbackDeleteMoving", "rollbackDeleteMoved")
    }

    private fun restoreQuarantined(
        loaded: SafLoaded,
        path: List<String>,
        movingPhase: String,
        movedPhase: String,
    ) {
        val state = loaded.state
        val parent = access.resolveParent(loaded.scope.session, path)
        if (access.resolve(loaded.scope.session, path, true) != null) {
            brokerFail("mutation_indeterminate")
        }
        val sourceId = state.getString("sourceDocId")
        val hiddenOriginal = access.childByDocumentId(loaded.hidden, sourceId)
        val parentOriginal = access.childByDocumentId(parent, sourceId)
        val quarantined = hiddenOriginal ?: parentOriginal
            ?: brokerFail("mutation_indeterminate")
        if (!verifiedOld(loaded, quarantined)) brokerFail("mutation_indeterminate")
        val restored = if (hiddenOriginal != null) {
            persist(loaded, movingPhase)
            moveDocument(access, quarantined.uri, loaded.hidden, parent).also {
                if (access.documentId(it) != sourceId) brokerFail("mutation_indeterminate")
                state.put("restoredUri", it.toString())
                persist(loaded, movedPhase)
            }
        } else {
            quarantined.uri
        }
        persist(loaded, "rollbackOldRenaming")
        val renamed = renameDocument(access, restored, path.last())
        state.put("restoredUri", renamed.toString())
        persist(loaded, "rollbackOldRenamed")
        val exact = access.exact(parent, path.last(), false)
            ?: brokerFail("mutation_indeterminate")
        if (exact.directory || renamed != exact.uri ||
            access.documentId(renamed) != state.getString("sourceDocId") ||
            access.documentId(exact.uri) != state.getString("sourceDocId") ||
            access.inspect(exact.uri, loaded.scope.session, true).hash !=
            state.getString("expectedHash")) brokerFail("mutation_indeterminate")
    }

    private fun rollbackMove(loaded: SafLoaded, path: List<String>) {
        val state = loaded.state
        if (access.resolve(loaded.scope.session, path, true) != null) return
        val destination = access.safePath(state.getString("destination"), false)
        val destinationParent = access.resolveParent(loaded.scope.session, destination)
        val sourceParent = access.resolveParent(loaded.scope.session, path)
        val moved = access.resolve(loaded.scope.session, destination, true)
            ?: access.childByDocumentId(destinationParent, state.getString("expectedIdentity"))
            ?: state.optionalString("movedUri")?.let { SafDoc(Uri.parse(it), false) }
            ?: brokerFail("mutation_indeterminate")
        if (access.documentId(moved.uri) != state.getString("expectedIdentity")) {
            brokerFail("mutation_indeterminate")
        }
        if (moved.directory || access.inspect(moved.uri, loaded.scope.session, true).hash !=
            state.getString("expectedHash")) brokerFail("mutation_indeterminate")
        val returned = moveDocument(access, moved.uri, destinationParent, sourceParent)
        val renamed = renameDocument(access, returned, path.last())
        val restored = access.exact(sourceParent, path.last(), false)
            ?: brokerFail("mutation_indeterminate")
        if (access.documentId(restored.uri) != access.documentId(renamed)) {
            brokerFail("mutation_indeterminate")
        }
        if (access.inspect(restored.uri, loaded.scope.session, true).hash !=
            state.getString("expectedHash")) brokerFail("mutation_indeterminate")
    }

    private fun rollbackCreate(loaded: SafLoaded, path: List<String>) {
        val state = loaded.state
        val stageIdentity = state.getString("stageDocId")
        val parent = access.resolveParent(loaded.scope.session, path)
        val current = access.resolve(loaded.scope.session, path, true)
            ?: access.childByDocumentId(parent, stageIdentity)
            ?: state.optionalString("movedUri")?.let { SafDoc(Uri.parse(it), false) }
            ?: access.childByDocumentId(loaded.hidden, stageIdentity)
            ?: return
        if (access.documentId(current.uri) != stageIdentity) {
            brokerFail("mutation_indeterminate")
        }
        val directory = state.getString("operation") == "make_directory"
        if (current.directory != directory) brokerFail("mutation_indeterminate")
        if (!directory && access.inspect(current.uri, loaded.scope.tree, true).hash !=
            state.getString("stageHash")) brokerFail("mutation_indeterminate")
        val hiddenCopy = access.childByDocumentId(loaded.hidden, stageIdentity)
        if (hiddenCopy == null) {
            val returned = try {
                moveDocument(access, current.uri, parent, loaded.hidden)
            } catch (_: Exception) {
                null
            }
            if (returned == null || access.documentId(returned) != stageIdentity) {
                brokerFail("mutation_indeterminate")
            }
            delete(returned)
        } else {
            delete(hiddenCopy.uri)
        }
        if (access.childByDocumentId(parent, stageIdentity) != null ||
            access.childByDocumentId(loaded.hidden, stageIdentity) != null ||
            access.resolve(loaded.scope.session, path, true) != null) {
            brokerFail("mutation_indeterminate")
        }
    }

    fun cleanup(args: Map<*, *>) {
        val receiptMap = args["prepared"] as? Map<*, *>
            ?: brokerFail("invalid_prepared_receipt")
        val id = access.string(receiptMap, "operationId")
        val token = access.string(receiptMap, "token")
        if (!SafWorkspaceAccess.OPERATION_ID.matches(id) ||
            !SafWorkspaceAccess.TOKEN.matches(token)) brokerFail("invalid_prepared_receipt")
        val scope = access.existingScope(args) ?: return
        val hidden = access.exact(scope.session, SafWorkspaceAccess.HIDDEN, true) ?: return
        val store = SafWorkspaceStateAdapter(access, hidden.uri).store()
        val state = store.load(id)
        if (state == null) {
            val absent = listOf("stage", "backup", "old", "state.a", "state.b")
                .all { access.exact(hidden.uri, "$id.$it", true) == null }
            if (absent) return
            brokerFail("mutation_indeterminate")
        }
        if (state.payload.getString("token") != token) {
            brokerFail("invalid_prepared_receipt")
        }
        listOf("stage", "backup", "old").forEach { suffix ->
            if (suffix != "old" || state.payload.getString("operation") !in
                setOf("delete_file", "write_file", "apply_patch")) {
                access.exact(hidden.uri, "$id.$suffix", true)?.let { delete(it.uri) }
            }
        }
        if (state.payload.getString("operation") in
            setOf("delete_file", "write_file", "apply_patch") &&
            !state.payload.getBoolean("expectMissing")) {
            val sourceDocId = state.payload.optionalString("sourceDocId")
                ?: brokerFail("mutation_indeterminate")
            access.childByDocumentId(hidden.uri, sourceDocId)?.let { document ->
                if (document.directory || access.inspect(document.uri, scope.tree, true).hash !=
                    state.payload.optionalString("expectedHash")) {
                    brokerFail("mutation_indeterminate")
                }
                if (state.payload.getString("phase") != "committed") {
                    renameDocument(access, document.uri, "$id.old")
                }
                val owned = access.childByDocumentId(hidden.uri, sourceDocId)
                    ?: brokerFail("mutation_indeterminate")
                delete(owned.uri)
            }
            access.exact(hidden.uri, "$id.old", true)?.let { old ->
                if (old.directory || access.documentId(old.uri) != sourceDocId ||
                    access.inspect(old.uri, scope.tree, true).hash !=
                    state.payload.optionalString("expectedHash")) {
                    brokerFail("mutation_indeterminate")
                }
                delete(old.uri)
            }
            if (access.childByDocumentId(hidden.uri, sourceDocId) != null) {
                brokerFail("mutation_indeterminate")
            }
        }
        // Delete both slots last. A retry succeeds when the first slot deletion crashed.
        listOf("state.a", "state.b").forEach { suffix ->
            access.exact(hidden.uri, "$id.$suffix", true)?.let { delete(it.uri) }
        }
    }

    private fun verifiedOld(loaded: SafLoaded, document: SafDoc): Boolean =
        !document.directory &&
            access.documentId(document.uri) == loaded.state.optionalString("sourceDocId") &&
            access.inspect(document.uri, loaded.scope.tree, true).hash ==
            loaded.state.optionalString("expectedHash")

    private fun safeIdentity(uri: Uri): String? = try {
        access.documentId(uri)
    } catch (_: Exception) {
        null
    }

    private fun delete(uri: Uri) {
        try {
            if (!DocumentsContract.deleteDocument(access.resolver, uri)) {
                brokerFail("mutation_indeterminate")
            }
        } catch (_: UnsupportedOperationException) {
            brokerFail("workspace_operation_unsupported")
        }
    }
}
