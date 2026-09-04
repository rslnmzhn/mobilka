package com.rslnmzhn.mobilka

import android.net.Uri
import android.provider.DocumentsContract
import org.json.JSONObject

internal class SafWorkspaceMutations(private val access: SafWorkspaceAccess) {
    private val recovery = SafWorkspaceRecovery(access, ::load, ::persist)

    fun prepare(args: Map<*, *>): Map<String, Any?> {
        val scope = access.mutationScope(args)
        val id = access.string(args, "operationId")
        if (!SafWorkspaceAccess.OPERATION_ID.matches(id)) brokerFail("invalid_argument")
        val operation = access.string(args, "operation")
        if (operation !in OPERATIONS) brokerFail("invalid_argument")
        val path = access.safePath(access.string(args, "path"), false)
        val destination = access.nullableString(args, "destination")?.let {
            access.safePath(it, false)
        }
        if ((operation == "move_file") != (destination != null)) {
            brokerFail("invalid_argument")
        }
        val expectMissing = args["expectMissing"] as? Boolean
            ?: brokerFail("invalid_argument")
        val expectedIdentity = access.nullableString(args, "expectedIdentity")
        val expectedHash = access.nullableString(args, "expectedHash")
        val target = access.resolve(scope.session, path, true)
        access.verifyExpectation(
            target,
            expectMissing,
            expectedIdentity,
            expectedHash,
            scope.session,
        )
        if (destination != null && access.resolve(scope.session, destination, true) != null) {
            brokerFail("destination_exists")
        }
        if (target?.directory == true && operation != "make_directory") {
            brokerFail("workspace_operation_unsupported")
        }
        val hidden = access.exact(scope.session, SafWorkspaceAccess.HIDDEN, true)
            ?: access.createDirectory(scope.session, SafWorkspaceAccess.HIDDEN)
        if (!hidden.directory || stateStore(hidden.uri).load(id) != null ||
            access.exact(hidden.uri, "$id.stage", true) != null ||
            access.exact(hidden.uri, "$id.backup", true) != null ||
            access.exact(hidden.uri, "$id.old", true) != null) {
            brokerFail("operation_exists")
        }
        access.requireStableMoveIdentity(hidden.uri, id)
        val bytes = args["bytes"] as? ByteArray
        if (operation in WRITES &&
            (bytes == null || bytes.size > SafWorkspaceAccess.MAX_BYTES)) {
            brokerFail("invalid_argument")
        }
        val stage = when {
            operation in WRITES && expectMissing ->
                access.createBytes(hidden.uri, scope.tree, "$id.stage", bytes!!)
            operation == "make_directory" -> {
                val directory = access.createDirectory(hidden.uri, "$id.stage")
                SafStored(directory.uri, access.documentId(directory.uri), "")
            }
            operation in WRITES -> access.createBytes(
                hidden.uri,
                scope.tree,
                "$id.stage",
                bytes!!,
            )
            else -> null
        }
        val backup = if (target != null && !target.directory) {
            val old = access.readStable(target.uri, scope.session).first
            access.createBytes(hidden.uri, scope.tree, "$id.backup", old)
        } else {
            null
        }
        val state = JSONObject().apply {
            put("operationId", id)
            put("token", randomWorkspaceToken())
            put("rootIdentity", access.documentId(access.scopeRoot(args).root))
            put("sessionIdentity", access.documentId(scope.session))
            put("sessionKey", access.safePath(access.string(args, "sessionKey"), false).single())
            put("operation", operation)
            put("path", path.joinToString("/"))
            put("destination", destination?.joinToString("/"))
            put("phase", "prepared")
            put("expectMissing", expectMissing)
            put("expectedIdentity", expectedIdentity)
            put("expectedHash", expectedHash)
            put("destinationAbsent", destination == null ||
                access.resolve(scope.session, destination, true) == null)
            put("stageUri", stage?.uri?.toString())
            put("stageDocId", stage?.identity)
            put("stageIdentity", stage?.identity)
            put("stageHash", stage?.hash)
            put("stageSize", bytes?.size)
            put("backupUri", backup?.uri?.toString())
            put("backupIdentity", backup?.identity)
            put("backupHash", backup?.hash)
            put("backupSize", backup?.let {
                access.inspect(it.uri, scope.tree, false).size
            })
            put("sourceUri", target?.uri?.toString())
            put("sourceDocId", target?.let { access.documentId(it.uri) })
        }
        try {
            stateStore(hidden.uri).persist(id, state, null)
        } catch (error: Exception) {
            cleanupFailedPreparation(hidden.uri, id)
            throw error
        }
        return mapOf("operationId" to id, "token" to state.getString("token"))
    }

    private fun cleanupFailedPreparation(hidden: Uri, id: String) {
        listOf("stage", "backup", "old", "state.a", "state.b").forEach { suffix ->
            access.exact(hidden, "$id.$suffix", true)?.let { document ->
                if (!DocumentsContract.deleteDocument(access.resolver, document.uri)) {
                    brokerFail("mutation_indeterminate")
                }
            }
        }
    }

    fun commit(args: Map<*, *>): Any? {
        val loaded = load(args)
        val state = loaded.state
        if (state.getString("phase") == "committed") return null
        when (val result = recovery.reconcileLoaded(loaded)) {
            "committed" -> return null
            "indeterminate" -> brokerFail("mutation_indeterminate")
            "rolledBack" -> brokerFail("invalid_prepared_receipt")
            "notCommitted" -> Unit
            else -> brokerFail("mutation_indeterminate")
        }
        val path = access.safePath(state.getString("path"), false)
        val target = access.resolve(loaded.scope.session, path, true)
        access.verifyExpectation(
            target,
            state.getBoolean("expectMissing"),
            state.optionalString("expectedIdentity"),
            state.optionalString("expectedHash"),
            loaded.scope.session,
        )
        when (state.getString("operation")) {
            "write_file", "apply_patch" -> commitWrite(loaded, path, target)
            "delete_file" -> commitDelete(loaded, path, target!!)
            "move_file" -> commitMove(loaded, path, target!!)
            "make_directory" -> commitCreate(loaded, path, directory = true)
        }
        persist(loaded, "committed")
        return null
    }

    private fun commitWrite(loaded: SafLoaded, path: List<String>, target: SafDoc?) {
        val state = loaded.state
        if (!state.getBoolean("expectMissing")) {
            commitOverwrite(loaded, path, target!!)
            return
        }
        commitCreate(loaded, path, directory = false)
    }

    private fun commitOverwrite(loaded: SafLoaded, path: List<String>, target: SafDoc) {
        val state = loaded.state
        val parent = access.resolveParent(loaded.scope.session, path)
        access.verifyExpectation(target, false, state.getString("expectedIdentity"),
            state.getString("expectedHash"), loaded.scope.session)
        persist(loaded, "overwriteQuarantining")
        val quarantined = moveDocument(access, target.uri, parent, loaded.hidden)
        if (access.documentId(quarantined) != state.getString("sourceDocId") ||
            access.inspect(quarantined, loaded.scope.tree, true).hash !=
            state.getString("expectedHash")) {
            brokerFail("mutation_indeterminate")
        }
        state.put("quarantineUri", quarantined.toString())
        persist(loaded, "overwriteQuarantined")
        persist(loaded, "overwriteQuarantineRenaming")
        val namedOld = renameDocument(access, quarantined, "${loaded.id}.old")
        state.put("quarantineUri", namedOld.toString())
        persist(loaded, "overwriteQuarantineRenamed")
        verifyQuarantine(loaded, namedOld)

        val staged = access.childByDocumentId(loaded.hidden, state.getString("stageDocId"))
            ?: brokerFail("mutation_indeterminate")
        persist(loaded, "overwriteStageMoving")
        val moved = moveDocument(access, staged.uri, loaded.hidden, parent)
        if (access.documentId(moved) != state.getString("stageDocId")) {
            brokerFail("mutation_indeterminate")
        }
        state.put("movedUri", moved.toString())
        persist(loaded, "overwriteStageMoved")
        persist(loaded, "overwriteStageRenaming")
        val renamed = renameDocument(access, moved, path.last())
        state.put("resultUri", renamed.toString())
        persist(loaded, "overwriteStageRenamed")
        val result = access.exact(parent, path.last(), false)
            ?: brokerFail("mutation_indeterminate")
        if (result.directory || renamed != result.uri ||
            access.documentId(renamed) != state.getString("stageDocId") ||
            access.documentId(result.uri) != state.getString("stageDocId") ||
            access.inspect(result.uri, loaded.scope.session, true).hash !=
            state.getString("stageHash")) brokerFail("mutation_indeterminate")
    }

    private fun verifyQuarantine(loaded: SafLoaded, uri: Uri) {
        val state = loaded.state
        val exact = access.exact(loaded.hidden, "${loaded.id}.old", false)
            ?: brokerFail("mutation_indeterminate")
        if (exact.directory || access.documentId(uri) != state.getString("sourceDocId") ||
            access.documentId(exact.uri) != state.getString("sourceDocId") ||
            access.inspect(exact.uri, loaded.scope.tree, true).hash !=
            state.getString("expectedHash")) brokerFail("mutation_indeterminate")
    }

    private fun commitCreate(loaded: SafLoaded, path: List<String>, directory: Boolean) {
        val state = loaded.state
        val parent = access.resolveParent(loaded.scope.session, path)
        if (access.resolve(loaded.scope.session, path, true) != null) {
            brokerFail("stale_target")
        }
        val staged = access.parseUri(
            state.optionalString("stageUri") ?: brokerFail("invalid_prepared_receipt"),
        )
        if (access.documentId(staged) != state.getString("stageDocId")) {
            brokerFail("mutation_indeterminate")
        }
        access.requireChild(loaded.hidden, staged)
        persist(loaded, "createMoving")
        val moved = moveDocument(access, staged, loaded.hidden, parent)
        if (access.documentId(moved) != state.getString("stageIdentity")) {
            try { moveDocument(access, moved, parent, loaded.hidden) } catch (_: Exception) {}
            brokerFail("workspace_operation_unsupported")
        }
        state.put("movedUri", moved.toString())
        persist(loaded, "createMoved")
        persist(loaded, "createRenaming")
        val renamed = renameDocument(access, moved, path.last())
        state.put("resultUri", renamed.toString())
        persist(loaded, "createRenamed")
        val result = access.exact(parent, path.last(), false)
            ?: brokerFail("mutation_indeterminate")
        if (renamed != result.uri || result.directory != directory ||
            access.documentId(renamed) != state.getString("stageIdentity") ||
            access.documentId(result.uri) != state.getString("stageIdentity")) {
            brokerFail("mutation_indeterminate")
        }
        if (!directory && access.inspect(result.uri, loaded.scope.session, true).hash !=
            state.getString("stageHash")) brokerFail("mutation_indeterminate")
    }

    private fun commitDelete(loaded: SafLoaded, path: List<String>, target: SafDoc) {
        val state = loaded.state
        val parent = access.resolveParent(loaded.scope.session, path)
        access.verifyExpectation(
            target,
            false,
            state.getString("expectedIdentity"),
            state.getString("expectedHash"),
            loaded.scope.session,
        )
        persist(loaded, "deleteMoving")
        val quarantined = moveDocument(access, target.uri, parent, loaded.hidden)
        if (access.documentId(quarantined) != state.getString("sourceDocId") ||
            access.inspect(quarantined, loaded.scope.tree, true).hash !=
            state.getString("expectedHash")) {
            brokerFail("mutation_indeterminate")
        }
        state.put("quarantineUri", quarantined.toString())
        persist(loaded, "deleteQuarantined")
        persist(loaded, "deleteRenaming")
        val namedQuarantine = renameDocument(access, quarantined, "${loaded.id}.old")
        state.put("quarantineUri", namedQuarantine.toString())
        persist(loaded, "deleteMoved")
        val exact = access.exact(loaded.hidden, "${loaded.id}.old", false)
            ?: brokerFail("mutation_indeterminate")
        if (namedQuarantine != exact.uri || exact.directory ||
            access.documentId(namedQuarantine) != state.getString("sourceDocId") ||
            access.documentId(exact.uri) != state.getString("sourceDocId") ||
            access.inspect(exact.uri, loaded.scope.tree, true).hash !=
            state.getString("expectedHash")) {
            brokerFail("mutation_indeterminate")
        }
    }

    private fun commitMove(loaded: SafLoaded, path: List<String>, target: SafDoc) {
        val destination = access.safePath(loaded.state.getString("destination"), false)
        val sourceParent = access.resolveParent(loaded.scope.session, path)
        val destinationParent = access.resolveParent(loaded.scope.session, destination)
        if (access.resolve(loaded.scope.session, destination, true) != null) {
            brokerFail("destination_exists")
        }
        persist(loaded, "moveMoving")
        val moved = moveDocument(access, target.uri, sourceParent, destinationParent)
        if (access.documentId(moved) != loaded.state.getString("sourceDocId")) {
            try { moveDocument(access, moved, destinationParent, sourceParent) } catch (_: Exception) {}
            brokerFail("workspace_operation_unsupported")
        }
        loaded.state.put("movedUri", moved.toString())
        persist(loaded, "moveMoved")
        persist(loaded, "moveRenaming")
        val renamed = renameDocument(access, moved, destination.last())
        loaded.state.put("resultUri", renamed.toString())
        persist(loaded, "moveRenamed")
        val result = access.exact(destinationParent, destination.last(), false)
            ?: rollbackMovedDocument(loaded, moved, destinationParent, sourceParent, path.last())
        if (result.directory ||
            access.documentId(result.uri) != loaded.state.getString("sourceDocId") ||
            access.inspect(result.uri, loaded.scope.session, true).hash !=
            loaded.state.getString("expectedHash")) {
            rollbackMovedDocument(loaded, result.uri, destinationParent, sourceParent, path.last())
        }
    }

    private fun rollbackMovedDocument(
        loaded: SafLoaded,
        moved: Uri,
        destinationParent: Uri,
        sourceParent: Uri,
        sourceName: String,
    ): Nothing {
        val expected = loaded.state.getString("sourceDocId")
        val candidate = access.childByDocumentId(destinationParent, expected)
            ?: SafDoc(moved, false)
        if (access.documentId(candidate.uri) == expected) {
            try {
                val returned = moveDocument(access, candidate.uri, destinationParent, sourceParent)
                renameDocument(access, returned, sourceName)
            } catch (_: Exception) {
                brokerFail("mutation_indeterminate")
            }
        }
        brokerFail("mutation_indeterminate")
    }

    fun reconcile(args: Map<*, *>): String = recovery.reconcileLoaded(load(args))

    fun rollback(args: Map<*, *>): Any? {
        recovery.rollback(load(args))
        return null
    }

    fun cleanup(args: Map<*, *>): Any? {
        recovery.cleanup(args)
        return null
    }

    private fun load(args: Map<*, *>): SafLoaded {
        val scope = access.mutationScope(args)
        val receipt = receipt(args)
        val hidden = access.exact(scope.session, SafWorkspaceAccess.HIDDEN, false)
            ?: brokerFail("invalid_prepared_receipt")
        if (!hidden.directory) brokerFail("unsafe_path")
        val stored = stateStore(hidden.uri).load(receipt.id)
            ?: brokerFail("invalid_prepared_receipt")
        val state = stored.payload
        if (state.getString("operationId") != receipt.id ||
            state.getString("token") != receipt.token ||
            state.getString("rootIdentity") != access.documentId(access.scopeRoot(args).root) ||
            state.getString("sessionIdentity") != access.documentId(scope.session) ||
            state.getString("sessionKey") != receipt.sessionKey ||
            state.getString("operation") !in OPERATIONS ||
            state.getString("phase") !in PHASES) brokerFail("invalid_prepared_receipt")
        // Stage may already have moved into the exact destination parent.
        state.optionalString("stageUri")?.let {
            val stageId = state.optionalString("stageDocId")
                ?: brokerFail("invalid_prepared_receipt")
            val path = access.safePath(state.getString("path"), false)
            val parent = access.resolveParent(scope.session, path)
            if (access.childByDocumentId(hidden.uri, stageId) == null &&
                access.childByDocumentId(parent, stageId) == null) {
                brokerFail("invalid_prepared_receipt")
            }
        }
        state.optionalString("backupUri")?.let { access.requireChild(hidden.uri, Uri.parse(it)) }
        return SafLoaded(scope, hidden.uri, state, receipt.id, stored.document, stored.generation)
    }

    private fun receipt(args: Map<*, *>): SafReceipt {
        val value = args["prepared"] as? Map<*, *>
            ?: brokerFail("invalid_prepared_receipt")
        if (value.size != 2) brokerFail("invalid_prepared_receipt")
        val id = access.string(value, "operationId")
        val token = access.string(value, "token")
        if (!SafWorkspaceAccess.OPERATION_ID.matches(id) ||
            !SafWorkspaceAccess.TOKEN.matches(token)) brokerFail("invalid_prepared_receipt")
        return SafReceipt(id, token, access.string(args, "sessionKey"))
    }

    private fun persist(loaded: SafLoaded, phase: String) {
        loaded.state.put("phase", phase)
        val previous = SafOperationStateStore.Loaded(
            loaded.stateDocument,
            loaded.state,
            loaded.generation,
        )
        val next = try {
            stateStore(loaded.hidden).persist(loaded.id, loaded.state, previous)
        } catch (_: SafOperationStateStore.InvalidStateException) {
            brokerFail("mutation_indeterminate")
        }
        loaded.stateDocument = next.document
        loaded.generation = next.generation
    }

    private fun stateStore(hidden: Uri) = SafWorkspaceStateAdapter(access, hidden).store()

    companion object {
        val WRITES = setOf("write_file", "apply_patch")
        val OPERATIONS = WRITES + setOf("move_file", "delete_file", "make_directory")
        val PHASES = setOf(
            "prepared", "overwriteQuarantining", "overwriteQuarantined",
            "overwriteQuarantineRenaming", "overwriteQuarantineRenamed",
            "overwriteStageMoving", "overwriteStageMoved", "overwriteStageRenaming",
            "overwriteStageRenamed", "createMoving",
            "createMoved", "createRenaming", "createRenamed", "deleteMoving",
            "deleteQuarantined", "deleteRenaming", "deleteMoved", "moveMoving",
            "moveMoved", "moveRenaming", "moveRenamed", "committed", "rolledBack",
            "rollbackStageMoving", "rollbackStageMoved", "rollbackOldMoving",
            "rollbackOldMoved", "rollbackDeleteMoving", "rollbackDeleteMoved",
            "rollbackOldRenaming", "rollbackOldRenamed",
        )
    }
}
