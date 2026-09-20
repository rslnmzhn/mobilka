package com.rslnmzhn.mobilka.documents

import android.util.Log

internal object DocumentWorkerProcessor {
    private val loaded: Boolean by lazy {
        try {
            System.loadLibrary("pdfium")
            System.loadLibrary("mobilka_documents_jni")
            nativeReady()
        } catch (t: Throwable) {
            Log.e("DocumentWorkerProcessor", "Failed to load document worker native libraries: ${t.message}", t)
            false
        }
    }

    fun isReady(): Boolean = loaded

    fun process(request: DocumentWorkerProtocol.Request, english: ByteArray, russian: ByteArray): ByteArray =
        if (loaded) nativeProcess(request.jobBytes, request.operation.ordinal, request.language.ordinal,
            request.firstPage, request.pageCount, request.limits.toIntArray(), request.source,
            english, russian) else throw IllegalStateException("Native document engine unavailable")

    private external fun nativeReady(): Boolean
    private external fun nativeProcess(job: ByteArray, operation: Int, language: Int,
        firstPage: Int, pageCount: Int, limits: IntArray, source: ByteArray,
        english: ByteArray, russian: ByteArray): ByteArray
}
