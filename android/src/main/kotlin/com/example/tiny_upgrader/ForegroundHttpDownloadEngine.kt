package com.example.tiny_upgrader

import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.math.max

internal class ForegroundHttpDownloadEngine(
    private val isActive: () -> Boolean,
    private val listener: Listener,
    private val connectionChanged: (HttpURLConnection?) -> Unit = {},
) {
    interface Listener {
        fun onProgress(downloaded: Long, total: Long, networkRetry: Int, validationRetry: Int)

        fun onRetry(
            code: String,
            message: String?,
            downloaded: Long,
            networkRetry: Int,
            validationRetry: Int,
        )

        fun onRangeReset()

        fun onValidation(fileSize: Long)
    }

    fun execute(task: ForegroundDownloadTask): Long {
        var networkRetry = 0
        var validationRetry = 0
        while (isActive()) {
            try {
                return downloadOnce(task, networkRetry, validationRetry)
            } catch (error: EngineValidationFailure) {
                ensureActive()
                if (validationRetry >= task.maxValidationRetryCount) {
                    throw EngineFinalFailure(
                        "VALIDATION_RETRY_EXHAUSTED",
                        error.message ?: "APK validation failed.",
                    )
                }
                validationRetry += 1
                File(task.savePath).delete()
                listener.onRetry(
                    "VALIDATION_RETRY",
                    error.message,
                    0,
                    networkRetry,
                    validationRetry,
                )
            } catch (error: EngineNonRetryableFailure) {
                throw EngineFinalFailure(error.code, error.message ?: error.code)
            } catch (error: EngineCancelled) {
                throw error
            } catch (error: Exception) {
                ensureActive()
                if (networkRetry >= task.maxNetworkRetryCount) {
                    throw EngineFinalFailure(
                        "NETWORK_RETRY_EXHAUSTED",
                        error.message ?: "Network download failed.",
                    )
                }
                networkRetry += 1
                val file = File(task.savePath)
                listener.onRetry(
                    "NETWORK_RETRY",
                    error.message,
                    if (file.isFile) file.length() else 0L,
                    networkRetry,
                    validationRetry,
                )
                waitForRetry(networkRetry)
            }
        }
        throw EngineCancelled()
    }

    private fun downloadOnce(
        task: ForegroundDownloadTask,
        networkRetry: Int,
        validationRetry: Int,
    ): Long {
        val file = File(task.savePath)
        file.parentFile?.mkdirs()
        var existingLength = if (file.isFile) file.length() else 0L

        if (task.expectedSize > 0 && existingLength > task.expectedSize) {
            file.delete()
            existingLength = 0
        }
        if (task.expectedSize > 0 && existingLength == task.expectedSize) {
            validateFile(task, file)
            return file.length()
        }
        if (task.expectedSize > 0) {
            val availableBytes = file.parentFile?.usableSpace ?: 0L
            val requiredBytes =
                (task.expectedSize - existingLength) +
                    task.expectedSize +
                    task.minFreeSpaceMarginBytes
            if (availableBytes < requiredBytes) {
                throw EngineNonRetryableFailure(
                    "INSUFFICIENT_STORAGE",
                    "$requiredBytes bytes required; $availableBytes bytes available.",
                )
            }
        }

        val connection = (URL(task.url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 30_000
            instanceFollowRedirects = true
            requestMethod = "GET"
            task.headers.forEach { (key, value) -> setRequestProperty(key, value) }
            if (existingLength > 0) {
                setRequestProperty("Range", "bytes=$existingLength-")
            }
        }
        connectionChanged(connection)

        try {
            ensureActive()
            val statusCode = connection.responseCode
            if (statusCode == HTTP_RANGE_NOT_SATISFIABLE) {
                if (file.isFile && file.length() > 0) {
                    validateFile(task, file)
                    return file.length()
                }
                throw EngineValidationFailure("HTTP 416 with an incomplete local file.")
            }
            if (statusCode >= 500 || statusCode == 408 || statusCode == 429) {
                throw IOException("HTTP $statusCode")
            }
            if (statusCode != HttpURLConnection.HTTP_OK &&
                statusCode != HttpURLConnection.HTTP_PARTIAL
            ) {
                throw EngineNonRetryableFailure("HTTP_ERROR", "HTTP $statusCode")
            }

            var append = false
            var writeOffset = 0L
            var totalBytes = task.expectedSize
            if (statusCode == HttpURLConnection.HTTP_PARTIAL) {
                val range = parseContentRange(connection.getHeaderField("Content-Range"))
                    ?: throw EngineValidationFailure("Missing or invalid Content-Range.")
                val responseLength = connection.contentLengthLong
                val valid =
                    range.start == existingLength &&
                        range.end >= range.start &&
                        (range.total == null || range.end < range.total) &&
                        (responseLength <= 0 || responseLength == range.end - range.start + 1) &&
                        (range.total == null ||
                            task.expectedSize <= 0 ||
                            range.total == task.expectedSize)
                if (!valid) {
                    throw EngineValidationFailure(
                        "Content-Range does not match the local file.",
                    )
                }
                append = existingLength > 0
                writeOffset = existingLength
                if (totalBytes <= 0) {
                    totalBytes = range.total ?: (existingLength + max(responseLength, 0))
                }
            } else if (existingLength > 0) {
                listener.onRangeReset()
            }
            if (totalBytes <= 0 && connection.contentLengthLong > 0) {
                totalBytes = writeOffset + connection.contentLengthLong
            }

            BufferedInputStream(connection.inputStream, BUFFER_SIZE).use { input ->
                FileOutputStream(file, append).use { output ->
                    val buffer = ByteArray(BUFFER_SIZE)
                    var received = 0L
                    var lastEventAt = 0L
                    var lastPercent = -1
                    while (true) {
                        ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        received += count
                        val current = writeOffset + received
                        val percent =
                            if (totalBytes > 0) ((current * 100) / totalBytes).toInt() else -1
                        val now = System.currentTimeMillis()
                        if (lastEventAt == 0L ||
                            now - lastEventAt >= PROGRESS_INTERVAL_MILLIS ||
                            percent >= lastPercent + 1
                        ) {
                            lastEventAt = now
                            lastPercent = percent
                            listener.onProgress(
                                current,
                                totalBytes,
                                networkRetry,
                                validationRetry,
                            )
                        }
                    }
                    output.flush()
                }
            }

            if (task.expectedSize > 0 && file.length() != task.expectedSize) {
                throw EngineValidationFailure(
                    "Downloaded size ${file.length()} does not match ${task.expectedSize}.",
                )
            }
            listener.onValidation(file.length())
            validateFile(task, file)
            return file.length()
        } finally {
            connection.disconnect()
            connectionChanged(null)
        }
    }

    private fun validateFile(task: ForegroundDownloadTask, file: File) {
        if (!file.isFile || file.length() < 4) {
            throw EngineValidationFailure("Downloaded file is empty.")
        }
        file.inputStream().buffered().use { input ->
            val signature = ByteArray(4)
            if (input.read(signature) != 4 ||
                signature[0] != 0x50.toByte() ||
                signature[1] != 0x4b.toByte() ||
                !(
                    (signature[2] == 0x03.toByte() && signature[3] == 0x04.toByte()) ||
                        (signature[2] == 0x05.toByte() && signature[3] == 0x06.toByte()) ||
                        (signature[2] == 0x07.toByte() && signature[3] == 0x08.toByte())
                    )
            ) {
                throw EngineValidationFailure("Downloaded content is not an APK/ZIP file.")
            }
        }

        if (task.expectedHash.isBlank()) return
        val digestName = when (task.hashAlgorithm.lowercase().replace("-", "")) {
            "md5" -> "MD5"
            "sha256" -> "SHA-256"
            else -> throw EngineNonRetryableFailure(
                "UNSUPPORTED_HASH",
                "Unsupported hash algorithm: ${task.hashAlgorithm}",
            )
        }
        val digest = MessageDigest.getInstance(digestName)
        file.inputStream().buffered(BUFFER_SIZE).use { input ->
            val buffer = ByteArray(BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (!actual.equals(task.expectedHash.trim(), ignoreCase = true)) {
            throw EngineValidationFailure("${task.hashAlgorithm} digest does not match.")
        }
    }

    private fun ensureActive() {
        if (!isActive()) throw EngineCancelled()
    }

    private fun waitForRetry(retry: Int) {
        val duration = if (retry >= 4) 4_000L else 500L * (1L shl (retry - 1))
        var waited = 0L
        while (waited < duration) {
            ensureActive()
            Thread.sleep(50)
            waited += 50
        }
    }

    private fun parseContentRange(value: String?): ContentRange? {
        if (value == null) return null
        val match = CONTENT_RANGE_REGEX.matchEntire(value.trim()) ?: return null
        return ContentRange(
            start = match.groupValues[1].toLong(),
            end = match.groupValues[2].toLong(),
            total = match.groupValues[3].takeIf { it != "*" }?.toLong(),
        )
    }

    private data class ContentRange(val start: Long, val end: Long, val total: Long?)

    companion object {
        private const val BUFFER_SIZE = 128 * 1024
        private const val PROGRESS_INTERVAL_MILLIS = 250L
        private const val HTTP_RANGE_NOT_SATISFIABLE = 416
        private val CONTENT_RANGE_REGEX = Regex("""bytes (\d+)-(\d+)/(\d+|\*)""")
    }
}

internal class EngineValidationFailure(message: String) : IOException(message)

internal class EngineNonRetryableFailure(
    val code: String,
    message: String,
) : IOException(message)

internal class EngineFinalFailure(
    val code: String,
    message: String,
) : IOException(message)

internal class EngineCancelled : IOException("Download cancelled.")
