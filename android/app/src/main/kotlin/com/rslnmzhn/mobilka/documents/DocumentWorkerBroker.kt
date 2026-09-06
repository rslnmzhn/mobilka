package com.rslnmzhn.mobilka.documents

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

internal class DocumentWorkerBroker(private val context: Context) {
    companion object {
        fun register(messenger: BinaryMessenger) {
            MethodChannel(messenger, "mobilka/document_worker").setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(mapOf(
                        "version" to 1,
                        "available" to false,
                        "capabilities" to emptyList<String>(),
                        "reason" to "document_worker_unavailable",
                    ))
                    "start", "cancel" -> result.error("document_worker_unavailable", null, null)
                    else -> result.notImplemented()
                }
            }
        }
    }

    // Internal transport only. The production channel never invokes this until
    // processor provisioning and memory/termination guarantees are verified.
    fun start(requestBytes: ByteArray, onDeath: () -> Unit): Job {
        check(Looper.myLooper() == Looper.getMainLooper())
        require(requestBytes.size <= DocumentWorkerProtocol.HEADER_BYTES +
            DocumentWorkerProtocol.MAX_SOURCE_BYTES)
        val bytes = requestBytes.copyOf()
        val request = DocumentWorkerProtocol.parse(bytes)
        val file = File.createTempFile("document-worker-", ".snapshot", context.cacheDir)
        var opened: ParcelFileDescriptor? = null
        val input = try {
            file.outputStream().use { it.write(bytes) }
            val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            opened = descriptor
            check(file.delete()) { "Unable to unlink document snapshot" }
            descriptor
        } catch (error: Exception) {
            opened?.close()
            if (file.exists() && !file.delete()) {
                Log.w("DocumentWorker", "Unable to remove failed snapshot")
            }
            throw error
        }
        val pipe = try {
            ParcelFileDescriptor.createPipe()
        } catch (error: Exception) {
            input.close()
            throw error
        }
        return Job(request, input, pipe[0], pipe[1], onDeath).also { it.bind() }
    }

    inner class Job internal constructor(
        private val request: DocumentWorkerProtocol.Request,
        private val input: ParcelFileDescriptor,
        private val output: ParcelFileDescriptor,
        private val sink: ParcelFileDescriptor,
        private val onDeath: () -> Unit,
    ) : ServiceConnection {
        private val handler = Handler(Looper.getMainLooper())
        private val reader = Executors.newSingleThreadExecutor()
        private var binder: IBinder? = null
        private var bound = false
        private var stopping = false
        private var deathObserved = false
        private val timeout = Runnable { cancel() }
        private val deathRecipient = IBinder.DeathRecipient {
            handler.post { observedDeath() }
        }

        internal fun bind() {
            try {
                bound = context.bindIsolatedService(
                    Intent(context, DocumentWorkerService::class.java),
                    Context.BIND_AUTO_CREATE, request.jobId, context.mainExecutor, this,
                )
                check(bound) { "Document worker binding rejected" }
                handler.postDelayed(timeout, request.deadlineMillis.toLong())
            } catch (error: Exception) {
                input.close()
                output.close()
                sink.close()
                reader.shutdownNow()
                throw error
            }
        }

        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            binder = service
            try {
                service.linkToDeath(deathRecipient, 0)
                if (stopping) {
                    cancel()
                    return
                }
                val message = Message.obtain(null, DocumentWorkerProtocol.START)
                message.data = Bundle().apply {
                    putParcelable("input", input)
                    putParcelable("output", sink)
                }
                Messenger(service).send(message)
                sink.close()
                reader.execute {
                    try {
                        ParcelFileDescriptor.AutoCloseInputStream(output).use { stream ->
                            val buffer = ByteArray(DocumentWorkerProtocol.MAX_CHUNK_BYTES)
                            var remaining = request.outputBytes + (request.pageCount + 1) * 51
                            while (true) {
                                val count = stream.read(buffer)
                                if (count == -1) break
                                require(count <= remaining)
                                remaining -= count
                            }
                        }
                    } catch (error: Exception) {
                        Log.w("DocumentWorker", "Worker output rejected or closed", error)
                    } finally {
                        handler.post { cancel() }
                    }
                }
            } catch (error: Exception) {
                Log.w("DocumentWorker", "Worker connection failed", error)
                cancel()
            }
        }

        fun cancel() {
            check(Looper.myLooper() == Looper.getMainLooper())
            stopping = true
            handler.removeCallbacks(timeout)
            try {
                binder?.let { Messenger(it).send(Message.obtain(null, DocumentWorkerProtocol.CANCEL)) }
            } catch (error: android.os.RemoteException) {
                Log.w("DocumentWorker", "Worker cancellation transport closed", error)
            }
            output.close()
            sink.close()
            if (bound) {
                context.unbindService(this)
                bound = false
            }
            // Keep the source descriptor until actual death notification. An
            // absent notification deliberately retains it; this is not reaping.
        }

        private fun observedDeath() {
            if (deathObserved) return
            deathObserved = true
            cancel()
            input.close()
            binder = null
            reader.shutdownNow()
            onDeath()
        }

        override fun onServiceDisconnected(name: ComponentName) {
            cancel()
        }

        override fun onBindingDied(name: ComponentName) {
            cancel()
        }

        override fun onNullBinding(name: ComponentName) {
            cancel()
        }
    }
}
