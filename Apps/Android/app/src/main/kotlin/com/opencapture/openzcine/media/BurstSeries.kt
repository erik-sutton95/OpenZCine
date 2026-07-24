package com.opencapture.openzcine.media

/**
 * Kotlin mirror of the shared Swift core `BurstSeriesGrouping` (Android re-implements media
 * grouping natively, like the RAW+JPEG pairing key). One media frame for burst detection.
 */
internal data class BurstFrame(
    val id: String,
    val storageId: Long?,
    val handle: Long?,
    /** PTP capture date `YYYYMMDDThhmmss` (or empty — an undated frame never joins a burst). */
    val captureDate: String,
    /** Case-insensitive filename stem; RAW and JPEG of one shot share it. */
    val stem: String,
    val isRaw: Boolean,
    /** Format + dimensions signature; frames must match to share a series. */
    val formatKey: String,
)

/** A detected burst run: [memberIDs] in capture order; the representative is the first. */
internal data class BurstSeries(val memberIDs: List<String>) {
    val representativeID: String
        get() = memberIDs.first()

    val count: Int
        get() = memberIDs.size
}

/** App-side burst detection — no new protocol. Mirrors Swift core `BurstSeriesGrouping`. */
internal object BurstSeriesGrouping {
    /**
     * Groups frames into burst series of at least [minCount] shots: a run extends while frames are
     * on the same storage, share a [BurstFrame.formatKey], and each is within [windowSeconds] of
     * the previous. RAW+JPEG frames of one shot collapse to a single member (a burst of N pairs is
     * one series of N, not 2N), so singles and lone pairs are never grouped; undated or
     * storage-less frames stay singletons. Input order is irrelevant — grouping sorts by capture
     * identity so contiguity means capture order, not display order.
     */
    fun group(
        frames: List<BurstFrame>,
        minCount: Int = 3,
        windowSeconds: Int = 1,
    ): List<BurstSeries> {
        val sorted =
            collapsePairs(frames).sortedWith(
                compareBy({ it.storageId ?: 0L }, { it.captureDate }, { it.handle ?: 0L }),
            )
        val series = mutableListOf<BurstSeries>()
        val run = mutableListOf<BurstFrame>()
        fun flush() {
            if (run.size >= minCount) series.add(BurstSeries(run.map { it.id }))
            run.clear()
        }
        for (shot in sorted) {
            val seconds = captureSeconds(shot.captureDate)
            if (shot.storageId == null || seconds == null) {
                flush() // undated / storage-less frames can't burst — they break the run
                continue
            }
            val last = run.lastOrNull()
            val lastSeconds = last?.let { captureSeconds(it.captureDate) }
            if (
                last != null &&
                    lastSeconds != null &&
                    last.storageId == shot.storageId &&
                    last.formatKey == shot.formatKey &&
                    seconds - lastSeconds <= windowSeconds
            ) {
                run.add(shot)
            } else {
                flush()
                run.add(shot)
            }
        }
        flush()
        return series
    }

    /** One shot per `(storageId, stem)`; the JPEG side represents a RAW+JPEG pair. */
    private fun collapsePairs(frames: List<BurstFrame>): List<BurstFrame> {
        val byKey = LinkedHashMap<String, BurstFrame>()
        for (frame in frames) {
            val key = "${frame.storageId ?: "-"}/${frame.stem}"
            val existing = byKey[key]
            when {
                existing == null -> byKey[key] = frame
                existing.isRaw && !frame.isRaw -> byKey[key] = frame
            }
        }
        return byKey.values.toList()
    }

    /**
     * Parses `YYYYMMDDThhmmss` to a monotonic second key with EXACT same-day differences; null for
     * an empty or malformed date. The calendar is approximate (ignores month lengths) on purpose:
     * only differences within one run matter, and any cross-day gap lands far above the window,
     * which correctly breaks a run — a continuous-drive burst never spans midnight.
     */
    fun captureSeconds(captureDate: String): Int? {
        if (captureDate.length < 15 || captureDate[8] != 'T') return null
        fun number(start: Int, end: Int): Int? = captureDate.substring(start, end).toIntOrNull()
        val year = number(0, 4) ?: return null
        val month = number(4, 6) ?: return null
        val day = number(6, 8) ?: return null
        val hour = number(9, 11) ?: return null
        val minute = number(11, 13) ?: return null
        val second = number(13, 15) ?: return null
        return ((((year * 12 + month) * 31 + day) * 24 + hour) * 60 + minute) * 60 + second
    }
}
