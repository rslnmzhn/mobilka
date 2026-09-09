package com.rslnmzhn.mobilka.documents

import java.nio.ByteBuffer
import java.security.MessageDigest

internal object DocumentWorkerProtocol {
    const val VERSION = 1
    const val START = 1
    const val CANCEL = 2
    const val HEADER_BYTES = 108
    const val MAX_SOURCE_BYTES = 10485760
    const val MAX_OUTPUT_BYTES = 1048576
    const val MAX_CHUNK_BYTES = 65536

    enum class Operation { PDF_TEXT, PDF_OCR, IMAGE_OCR }
    enum class Language { ENG, RUS, ENG_RUS }

    data class Request(
        val jobId: String,
        val jobBytes: ByteArray,
        val operation: Operation,
        val language: Language,
        val firstPage: Int,
        val pageCount: Int,
        val limits: List<Int>,
        val source: ByteArray,
    ) {
        val deadlineMillis: Int get() = limits[8]
        val outputBytes: Int get() = limits[7]
    }

    fun parse(bytes: ByteArray): Request {
        require(bytes.size in HEADER_BYTES..HEADER_BYTES + MAX_SOURCE_BYTES)
        val buffer = ByteBuffer.wrap(bytes)
        require(buffer.int == 0x4d445701)
        val job = ByteArray(16).also { buffer.get(it) }
        val hash = ByteArray(32).also { buffer.get(it) }
        val operation = Operation.values().getOrNull(buffer.get().toInt())
        val language = Language.values().getOrNull(buffer.get().toInt())
        require(operation != null && language != null)
        val first = buffer.short.toInt() and 0xffff
        val count = buffer.short.toInt() and 0xffff
        require(buffer.short.toInt() == 0)
        val sourceBytes = buffer.int
        val limits = List(10) { buffer.int }
        val ceilings = listOf(10485760, 100, 25, 4096, 4000000,
            20000000, 262144, 1048576, 30000, 268435456)
        require(limits.indices.all { limits[it] in 1..ceilings[it] })
        require(buffer.int == 0 && sourceBytes == bytes.size - HEADER_BYTES)
        require(sourceBytes <= limits[0])
        require(count in 1..limits[2] && first >= 1 && first <= limits[1] - count + 1)
        require(operation != Operation.IMAGE_OCR || (first == 1 && count == 1))
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(bytes, HEADER_BYTES, sourceBytes)
        require(MessageDigest.isEqual(hash, digest.digest()))
        return Request(job.joinToString("") { "%02x".format(it.toInt() and 255) },
            job, operation, language, first, count, limits,
            bytes.copyOfRange(HEADER_BYTES, bytes.size))
    }

    // Terminal status 2 is unavailable, never a successful extraction.
    fun unavailable(jobId: String): ByteArray {
        require(jobId.matches(Regex("[0-9a-f]{32}")))
        return ByteBuffer.allocate(51).apply {
            putInt(47)
            put(VERSION.toByte())
            put(1.toByte())
            for (index in 0 until 16) {
                put(jobId.substring(index * 2, index * 2 + 2).toInt(16).toByte())
            }
            putInt(0)
            putInt(0)
            putInt(0)
            put(2.toByte())
            putInt(0)
            putInt(0)
            putInt(0)
            putInt(0)
        }.array()
    }
}
