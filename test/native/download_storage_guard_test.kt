package com.bbflight.background_downloader

import java.io.IOException
import java.io.OutputStream

/** Host-JVM regression tests; no Android SDK or device required. */
private class Destination : OutputStream() {
    var bytes = 0L
    var buffered = 0L
    var available = 32L * 1024 * 1024
    var samples = 0
    var removals = 0
    var closes = 0
    var time = 0L
    var capacityKnown = true
    var failure: String? = null
    val full = IOException("controlled disk full")

    override fun write(value: Int) = write(ByteArray(1), 0, 1)
    override fun write(data: ByteArray, offset: Int, length: Int) {
        if (failure == "write") throw full
        bytes += length
        buffered += length
    }
    override fun flush() {
        if (failure == "flush") throw full
        available -= buffered
        buffered = 0
    }
    override fun close() {
        closes++
        if (failure == "close") throw full
        flush()
    }

    fun guard(configuration: Int = 1, length: Long = -1) = DownloadStorageGuard(
        this, configuration, length,
        {
            samples++
            check(capacityKnown)
            DownloadVolumeCapacity(available, 64L * 1024 * 1024)
        },
        { removals++ },
        { it === full },
        { time }
    )
}

private inline fun <reified T : Throwable> expectFailure(block: () -> Unit): T {
    try { block() } catch (error: Throwable) {
        check(error is T) { "Expected ${T::class.java}, got $error" }
        return error
    }
    error("Expected ${T::class.java}")
}

fun main() {
    val mib = 1024 * 1024
    run {
        val output = Destination()
        val guard = output.guard()
        repeat(mib) { guard.write(0) }
        check(output.samples == 2) { "Tiny writes must share one capacity sample" }
        guard.write(0)
        check(output.samples == 3)
        check(output.available == 31L * mib) { "Buffered output must drain before resampling" }
        guard.close()
        check(output.bytes == mib.toLong() + 1)
    }
    run {
        val output = Destination()
        val guard = output.guard()
        guard.write(ByteArray(3 * mib + 7))
        check(output.samples == 5)
        check(output.bytes == 3L * mib + 7)
    }
    run {
        val output = Destination().apply { available = mib.toLong() + 17 }
        val guard = output.guard()
        expectFailure<DownloadStorageException> { guard.write(ByteArray(18)) }
        check(output.bytes == 17L) { "Never cross the configured reserve from a sampled budget" }
        check(output.removals == 1 && output.closes == 1)
        expectFailure<IllegalStateException> { guard.write(0) }
    }
    run {
        val output = Destination()
        val guard = output.guard()
        guard.write(0)
        output.available = mib.toLong()
        output.time = 1_000_000_000L
        expectFailure<DownloadStorageException> { guard.write(0) }
        check(output.bytes == 1L) { "An idle writer must observe concurrent disk usage" }
    }
    run {
        val output = Destination()
        val guard = output.guard()
        guard.write(0)
        guard.flush()
        output.available = mib.toLong()
        expectFailure<DownloadStorageException> { guard.write(0) }
    }
    run {
        val output = Destination()
        expectFailure<DownloadStorageException> { output.guard(length = Long.MAX_VALUE) }
        check(output.bytes == 0L && output.removals == 1)
    }
    run {
        val output = Destination().apply { capacityKnown = false }
        expectFailure<DownloadStorageException> { output.guard() }
        check(output.removals == 1)
    }
    run {
        val output = Destination().apply { available = 64L * mib + 1 }
        expectFailure<DownloadStorageException> { output.guard() }
    }
    run {
        val output = Destination()
        val guard = output.guard(configuration = 0)
        output.capacityKnown = false
        guard.write(ByteArray(2 * mib))
        check(output.samples == 0)
        output.failure = "write"
        expectFailure<DownloadStorageException> { guard.write(0) }
        check(output.removals == 1)
    }
    for (operation in listOf("write", "flush", "close")) {
        val output = Destination()
        val guard = output.guard()
        guard.write(0)
        output.failure = operation
        val error = expectFailure<DownloadStorageException> {
            when (operation) {
                "write" -> guard.write(0)
                "flush" -> guard.flush()
                "close" -> guard.close()
            }
        }
        check(error.cause === output.full)
        check(output.removals == 1 && output.closes == 1)
        guard.close()
        check(output.closes == 1)
    }
    run {
        val output = Destination()
        val guard = output.guard()
        expectFailure<IndexOutOfBoundsException> { guard.write(ByteArray(2), 1, 2) }
        guard.write(ByteArray(0))
        check(output.bytes == 0L && output.samples == 1)
    }
    run {
        val output = Destination()
        // The automatic 256 MiB reserve is larger than this test volume.
        expectFailure<DownloadStorageException> { output.guard(configuration = -1) }
    }
    println("DownloadStorageGuard: 14 regression scenarios passed")
}
