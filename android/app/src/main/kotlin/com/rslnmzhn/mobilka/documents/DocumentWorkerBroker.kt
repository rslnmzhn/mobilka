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
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

internal class DocumentWorkerBroker(private val context: Context) : EventChannel.StreamHandler {
    companion object {
        fun register(context: Context, messenger: BinaryMessenger) {
            val broker = DocumentWorkerBroker(context.applicationContext)
            EventChannel(messenger, "mobilka/document_worker/events").setStreamHandler(broker)
            MethodChannel(messenger, "mobilka/document_worker").setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> {
                        val available = broker.available()
                        result.success(mapOf(
                            "version" to 1,
                            "available" to available,
                            "capabilities" to if (available) listOf(
                                "isolatedProcess", "offline", "immutableInput", "boundedOutput",
                                "osManagedMemoryIsolation", "wallDeadline",
                                "workerInvalidatedAfterDeadline",
                            ) else emptyList<String>(),
                        ))
                    }
                    "start" -> broker.startCall(call.arguments as? Map<*, *>, result)
                    "cancel" -> broker.cancelCall(call.arguments as? Map<*, *>, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    private var events: EventChannel.EventSink? = null
    private var active: Job? = null

    private fun available(): Boolean {
        val library = File(context.applicationInfo.nativeLibraryDir,
            System.mapLibraryName("mobilka_documents_jni"))
        if (!library.isFile) return false
        return try {
            DocumentWorkerProcessor.isReady() &&
                context.assets.open("documents/eng.traineddata").use { it.available() > 0 } &&
                context.assets.open("documents/rus.traineddata").use { it.available() > 0 }
        } catch (_: Throwable) { false }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { events = sink }
    override fun onCancel(arguments: Any?) {
        active?.invalidate()
        active = null
        events = null
    }

    private fun startCall(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val bytes = arguments?.get("request") as? ByteArray
        val jobId = arguments?.get("jobId") as? String
        if (!available()) {
            result.error("document_worker_unavailable", null, null)
            return
        }
        if (bytes == null || jobId == null || active != null || events == null) {
            result.error("document_worker_busy", null, null)
            return
        }
        try {
            val request = DocumentWorkerProtocol.parse(bytes)
            require(request.jobId == jobId)
            val job = Job.create(context, request, bytes) { workerDied() }
            active = job
            job.start(
                onChunk = { chunk -> events?.success(chunk) },
                onComplete = { complete(job) },
            )
            result.success(null)
        } catch (_: Throwable) {
            active = null
            result.error("invalid_document_worker_request", null, null)
        }
    }

    private fun cancelCall(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val job = active
        if (job == null || arguments?.get("jobId") != job.jobId) {
            result.error("document_worker_not_running", null, null)
            return
        }
        active = null
        job.invalidate()
        result.success(null)
    }

    private fun complete(job: Job) {
        if (active !== job) return
        active = null
        job.invalidate()
        events?.endOfStream()
    }

    private fun workerDied() {
        if (active == null) return
        active = null
        events?.error("document_worker_died", null, null)
    }

    private class Job(
        private val context: Context,
        val jobId: String,
        private val input: ParcelFileDescriptor,
        private val output: ParcelFileDescriptor,
        private val serviceOutput: ParcelFileDescriptor,
        private val onDeath: () -> Unit,
    ) : ServiceConnection, IBinder.DeathRecipient {
        companion object {
            fun create(context: Context, request: DocumentWorkerProtocol.Request,
                bytes: ByteArray, onDeath: () -> Unit): Job {
                val snapshot = File.createTempFile("document-worker-", ".snapshot", context.cacheDir)
                snapshot.outputStream().use { it.write(bytes) }
                val input = ParcelFileDescriptor.open(snapshot, ParcelFileDescriptor.MODE_READ_ONLY)
                check(snapshot.delete())
                val pipe = ParcelFileDescriptor.createPipe()
                return Job(context, request.jobId, input, pipe[0], pipe[1], onDeath)
            }
        }

        private var messenger: Messenger? = null
        private var bound = false
        private var invalidated = false

        fun start(onChunk: (ByteArray) -> Unit, onComplete: () -> Unit) {
            Executors.newSingleThreadExecutor().execute {
                try {
                    ParcelFileDescriptor.AutoCloseInputStream(output).use { stream ->
                        val buffer = ByteArray(DocumentWorkerProtocol.MAX_CHUNK_BYTES)
                        while (true) {
                            val count = stream.read(buffer)
                            if (count < 0) break
                            val chunk = buffer.copyOf(count)
                            Handler(Looper.getMainLooper()).post { onChunk(chunk) }
                        }
                    }
                    Handler(Looper.getMainLooper()).post(onComplete)
                } catch (_: Throwable) { died() }
            }
            bound = context.bindService(Intent(context, DocumentWorkerService::class.java), this,
                Context.BIND_AUTO_CREATE)
            check(bound)
        }

        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            if (invalidated) return
            binder.linkToDeath(this, 0)
            messenger = Messenger(binder)
            val message = Message.obtain(null, DocumentWorkerProtocol.START)
            message.data = Bundle().apply {
                putParcelable("input", input)
                putParcelable("output", serviceOutput)
            }
            try {
                messenger!!.send(message)
                input.close()
                serviceOutput.close()
            } catch (_: Throwable) { died() }
        }

        fun invalidate() {
            if (invalidated) return
            invalidated = true
            try { messenger?.send(Message.obtain(null, DocumentWorkerProtocol.CANCEL)) } catch (_: Throwable) {}
            close()
        }

        private fun died() {
            if (invalidated) return
            invalidated = true
            close()
            Handler(Looper.getMainLooper()).post(onDeath)
        }

        private fun close() {
            try { input.close() } catch (_: Throwable) {}
            try { output.close() } catch (_: Throwable) {}
            try { serviceOutput.close() } catch (_: Throwable) {}
            if (bound) { try { context.unbindService(this) } catch (_: Throwable) {}; bound = false }
            messenger = null
        }

        override fun binderDied() = died()
        override fun onServiceDisconnected(name: ComponentName) = died()
        override fun onBindingDied(name: ComponentName) = died()
        override fun onNullBinding(name: ComponentName) = died()
    }
}
