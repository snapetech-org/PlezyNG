package com.bbflight.background_downloader

import java.io.IOException
import java.io.OutputStream

internal data class DownloadVolumeCapacity(val available: Long, val total: Long)

internal class DownloadStorageException(message: String, cause: Throwable? = null) :
    IOException(message, cause)

internal fun isDownloadStorageFailure(description: String?): Boolean =
    description?.startsWith("Insufficient space to store") == true ||
        description?.startsWith("Download storage capacity could not be determined") == true

/**
 * Guards the actual destination descriptor, including unknown-length downloads
 * and copy fallbacks. Charge every write against at most one MiB of sampled
 * headroom; refresh after one second as well so a slow/paused writer cannot keep
 * using an old sample. Unknown capacity remains a storage failure (including
 * SAF providers that cannot report the destination volume).
 */
internal class DownloadStorageGuard(
    private val output: OutputStream,
    private val checkValue: Int,
    contentLength: Long,
    private val capacity: () -> DownloadVolumeCapacity,
    private val removeIncomplete: () -> Unit,
    private val isCapacityError: (IOException) -> Boolean = { false },
    private val nanoTime: () -> Long = System::nanoTime
) : OutputStream() {
    companion object {
        private const val WRITE_BUDGET = 1024 * 1024
        private const val SAMPLE_LIFETIME_NANOS = 1_000_000_000L
    }

    private var closed = false
    private var writeBudget = 0
    private var sampledAt = 0L

    init {
        checkCapacity(contentLength.coerceAtLeast(0))
    }

    private fun checkCapacity(bytes: Long) {
        if (bytes > headroom()) {
            fail(DownloadStorageException("Insufficient space to store the file to be downloaded"))
        }
    }

    private fun headroom(): Long {
        if (checkValue == 0) return Long.MAX_VALUE
        val volume = try {
            capacity().also {
                require(it.total > 0 && it.available >= 0 && it.available <= it.total)
            }
        } catch (e: Exception) {
            fail(DownloadStorageException(
                "Download storage capacity could not be determined", e
            ))
        }
        val floor = if (checkValue < 0) {
            maxOf(256L * 1024 * 1024, volume.total / 100)
        } else {
            checkValue.toLong() * 1024 * 1024
        }
        // Subtraction avoids overflow for very large advertised lengths.
        return volume.available - floor
    }

    private fun fail(error: DownloadStorageException): Nothing {
        try {
            if (!closed) {
                closed = true
                output.close()
            }
        } catch (e: Exception) {
            error.addSuppressed(e)
        }
        try {
            removeIncomplete()
        } catch (e: Exception) {
            error.addSuppressed(e)
        }
        throw error
    }

    private fun replenishBudget() {
        if (writeBudget > 0 && nanoTime() - sampledAt < SAMPLE_LIFETIME_NANOS) return
        // Account for buffered bytes before sampling the actual destination.
        flush()
        val remaining = headroom()
        if (remaining <= 0) {
            fail(DownloadStorageException("Insufficient space to store the file to be downloaded"))
        }
        writeBudget = minOf(WRITE_BUDGET.toLong(), remaining).toInt()
        sampledAt = nanoTime()
    }

    override fun write(value: Int) {
        check(!closed) { "Download output is closed" }
        replenishBudget()
        try {
            output.write(value)
            writeBudget--
        } catch (e: IOException) {
            handleWriteFailure(e)
        }
    }

    override fun write(bytes: ByteArray, offset: Int, length: Int) {
        if (offset < 0 || length < 0 || offset > bytes.size - length) {
            throw IndexOutOfBoundsException()
        }
        check(!closed) { "Download output is closed" }
        var position = offset
        var remaining = length
        while (remaining > 0) {
            replenishBudget()
            val count = minOf(remaining, writeBudget)
            try {
                output.write(bytes, position, count)
                writeBudget -= count
            } catch (e: IOException) {
                handleWriteFailure(e)
            }
            position += count
            remaining -= count
        }
    }

    private fun handleWriteFailure(error: IOException): Nothing {
        if (isCapacityError(error)) {
            fail(DownloadStorageException("Insufficient space to store the file to be downloaded", error))
        }
        // A failed write may be the first observation of capacity consumed concurrently.
        checkCapacity(1)
        throw error
    }

    override fun flush() {
        if (!closed) {
            writeBudget = 0
            try {
                output.flush()
            } catch (e: IOException) {
                handleWriteFailure(e)
            }
        }
    }

    override fun close() {
        if (!closed) {
            closed = true
            writeBudget = 0
            try {
                output.close()
            } catch (e: IOException) {
                // The descriptor may already be closed: do not query it here.
                if (isCapacityError(e)) {
                    fail(DownloadStorageException("Insufficient space to store the file to be downloaded", e))
                }
                throw e
            }
        }
    }
}
