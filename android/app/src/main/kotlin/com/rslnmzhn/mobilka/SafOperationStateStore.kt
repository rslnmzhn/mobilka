package com.rslnmzhn.mobilka

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

internal class SafOperationStateStore(
    private val nameOf: (StateDocument) -> String,
    private val exact: (String) -> StateDocument?,
    private val create: (String, ByteArray) -> StateDocument,
    private val overwrite: (StateDocument, ByteArray) -> Unit,
    private val read: (StateDocument) -> ByteArray,
) {
    data class StateDocument(val identity: String, val opaque: Any)
    data class Loaded(val document: StateDocument, val payload: JSONObject, val generation: Long)

    fun load(operationId: String): Loaded? {
        val candidates = listOf("$operationId.state.a", "$operationId.state.b")
            .mapNotNull { name -> exact(name)?.let { parse(it) } }
        return candidates.maxByOrNull { it.generation }
    }

    fun persist(operationId: String, payload: JSONObject, previous: Loaded?): Loaded {
        val current = load(operationId)
        if (previous != null && (current == null ||
                current.document.identity != previous.document.identity ||
                current.generation != previous.generation)) throw InvalidStateException()
        if (previous == null && current != null) throw InvalidStateException()
        val generation = (previous?.generation ?: 0L) + 1L
        payload.put("schema", SCHEMA)
        payload.put("generation", generation)
        val encoded = encode(payload)
        val nextName = if (previous?.document?.let(nameOf) ==
            "$operationId.state.a") "$operationId.state.b" else "$operationId.state.a"
        val existing = exact(nextName)
        val document = if (existing == null) create(nextName, encoded) else {
            overwrite(existing, encoded)
            existing
        }
        val loaded = parse(document) ?: throw InvalidStateException()
        if (loaded.generation != generation || canonical(loaded.payload) != canonical(payload)) {
            throw InvalidStateException()
        }
        return loaded
    }

    private fun parse(document: StateDocument): Loaded? {
        return try {
            val envelope = JSONObject(read(document).toString(Charsets.UTF_8))
            if (envelope.length() != 2) return null
            val payload = envelope.getJSONObject("payload")
            val checksum = envelope.getString("checksum")
            if (payload.getInt("schema") != SCHEMA ||
                checksum != sha256(canonical(payload).toByteArray(Charsets.UTF_8))) return null
            val generation = payload.getLong("generation")
            if (generation < 1) return null
            Loaded(document, payload, generation)
        } catch (_: Exception) {
            null
        }
    }

    private fun encode(payload: JSONObject): ByteArray {
        val envelope = JSONObject()
            .put("payload", payload)
            .put("checksum", sha256(canonical(payload).toByteArray(Charsets.UTF_8)))
        return canonical(envelope).toByteArray(Charsets.UTF_8)
    }

    private fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") {
            JSONObject.quote(it) + ":" + canonical(value.get(it))
        }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") {
            canonical(value.get(it))
        }
        is String -> JSONObject.quote(value)
        is Boolean, is Number -> value.toString()
        else -> throw InvalidStateException()
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    class InvalidStateException : Exception()

    private companion object { const val SCHEMA = 2 }
}
