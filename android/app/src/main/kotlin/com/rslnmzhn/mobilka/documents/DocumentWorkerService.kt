package com.rslnmzhn.mobilka.documents

import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.util.concurrent.Executors

class DocumentWorkerService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var started = false
    private var stopped = false
    private var input: ParcelFileDescriptor? = null
    private var output: ParcelFileDescriptor? = null
    private val watchdog = Runnable { stopJob() }
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        when (message.what) {
            DocumentWorkerProtocol.START -> startJob(message)
            DocumentWorkerProtocol.CANCEL -> stopJob()
            else -> stopJob()
        }
        true
    })

    override fun onBind(intent: Intent): IBinder = messenger.binder

    @Suppress("DEPRECATION")
    private fun startJob(message: Message) {
        val source = message.data.getParcelable<ParcelFileDescriptor>("input")
        val sink = message.data.getParcelable<ParcelFileDescriptor>("output")
        if (started || stopped || source == null || sink == null) {
            source?.close()
            sink?.close()
            stopJob()
            return
        }
        started = true
        val startedAt = SystemClock.elapsedRealtime()
        input = source
        output = sink
        handler.postDelayed(watchdog, 30000)
        executor.execute {
            try {
                require((Os.fcntlInt(source.fileDescriptor, OsConstants.F_GETFL, 0)
                    and OsConstants.O_ACCMODE) == OsConstants.O_RDONLY)
                val size = source.statSize
                require(size in DocumentWorkerProtocol.HEADER_BYTES.toLong()..
                    (DocumentWorkerProtocol.HEADER_BYTES + DocumentWorkerProtocol.MAX_SOURCE_BYTES).toLong())
                val bytes = ByteArray(size.toInt())
                ParcelFileDescriptor.AutoCloseInputStream(source).use { stream ->
                    var offset = 0
                    while (offset < bytes.size) {
                        val read = stream.read(bytes, offset, bytes.size - offset)
                        require(read > 0)
                        offset += read
                    }
                    require(stream.read() == -1)
                }
                val request = DocumentWorkerProtocol.parse(bytes)
                handler.post {
                    if (!stopped) {
                        handler.removeCallbacks(watchdog)
                        val remaining = request.deadlineMillis -
                            (SystemClock.elapsedRealtime() - startedAt)
                        handler.postDelayed(watchdog, remaining.coerceAtLeast(0))
                    }
                }
                fun readAsset(name: String): ByteArray = assets.open(name).use { stream ->
                    val available = stream.available()
                    require(available in 1..16777216)
                    val data = ByteArray(available)
                    var offset = 0
                    while (offset < data.size) {
                        val count = stream.read(data, offset, data.size - offset)
                        require(count > 0)
                        offset += count
                    }
                    require(stream.read() == -1)
                    data
                }
                val english = readAsset("documents/eng.traineddata")
                val russian = readAsset("documents/rus.traineddata")
                require(english.size <= 16777216 && russian.size <= 16777216)
                val response = DocumentWorkerProcessor.process(request, english, russian)
                require(response.size <= request.outputBytes + 4096)
                ParcelFileDescriptor.AutoCloseOutputStream(sink).use { it.write(response) }
            } catch (error: Exception) {
                Log.w("DocumentWorker", "Worker rejected input or transport closed", error)
            } finally {
                handler.post { stopJob() }
            }
        }
    }

    private fun stopJob() {
        stopped = true
        handler.removeCallbacks(watchdog)
        input?.close()
        output?.close()
        input = null
        output = null
        executor.shutdownNow()
        // A bound service does not die merely because stopSelf was called.
        // The broker also releases its sole binding and observes Binder death.
        stopSelf()
    }

    override fun onDestroy() {
        stopJob()
        super.onDestroy()
    }
}
