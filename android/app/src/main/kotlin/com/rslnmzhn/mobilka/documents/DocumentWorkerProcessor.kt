package com.rslnmzhn.mobilka.documents

internal object DocumentWorkerProcessor {
    const val available = false

    fun process(request: DocumentWorkerProtocol.Request): ByteArray =
        DocumentWorkerProtocol.unavailable(request.jobId)
}
