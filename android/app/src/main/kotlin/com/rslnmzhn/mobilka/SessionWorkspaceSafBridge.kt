package com.rslnmzhn.mobilka

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class SessionWorkspaceSafBridge(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val handlers = SessionWorkspaceSafMutationHandlers(context)
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in METHODS) {
            result.notImplemented()
            return
        }
        executor.execute {
            try {
                val args = call.arguments as? Map<*, *>
                    ?: throw WorkspaceBrokerException("invalid_argument")
                val value = handlers.dispatch(call.method, args)
                main.post { result.success(value) }
            } catch (error: WorkspaceBrokerException) {
                main.post {
                    result.error(error.code, "Workspace operation rejected", null)
                }
            } catch (_: Exception) {
                main.post {
                    result.error(
                        "mutation_indeterminate",
                        "Workspace operation failed",
                        null,
                    )
                }
            }
        }
    }

    private companion object {
        const val CHANNEL = "mobilka/session_workspace"
        val METHODS = setOf(
            "rootIdentity",
            "validateDocument",
            "readDocument",
            "listDocuments",
            "prepareMutation",
            "commitPrepared",
            "reconcilePrepared",
            "rollbackPrepared",
            "cleanupPrepared",
        )
    }
}
