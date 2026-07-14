package com.opencapture.openzcine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** Regression coverage for close while native transfer setup is still running. */
@OptIn(ExperimentalCoroutinesApi::class)
class MediaTransferCoordinatorTest {
    @Test
    fun `close waits for preparation then stops exactly once`() = runTest {
        val preparationStarted = CompletableDeferred<Unit>()
        val allowPreparationToFinish = CompletableDeferred<Unit>()
        var prepares = 0
        var stops = 0
        val coordinator =
            MediaTransferCoordinator(
                prepareTransfer = {
                    prepares++
                    preparationStarted.complete(Unit)
                    allowPreparationToFinish.await()
                    PlaybackPreparation.Failed("synthetic preparation result")
                },
                stopTransfer = { stops++ },
            )

        val preparation = async { coordinator.prepare() }
        preparationStarted.await()
        val closing = async { coordinator.close() }
        runCurrent()

        assertEquals(0, stops)
        allowPreparationToFinish.complete(Unit)
        assertIs<PlaybackPreparation.Failed>(preparation.await())
        closing.await()

        assertEquals(1, prepares)
        assertEquals(1, stops)
        assertEquals(PlaybackPreparation.Cancelled, coordinator.prepare())
        coordinator.close()
        assertEquals(1, stops)
    }
}
