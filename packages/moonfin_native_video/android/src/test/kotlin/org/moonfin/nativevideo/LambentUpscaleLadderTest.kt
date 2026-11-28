package org.moonfin.nativevideo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LambentUpscaleLadderTest {
    private val sixty = 1000f / 60f
    private val warmUp = LambentUpscaleLadder.WARM_UP_FRAMES
    private val after = LambentUpscaleLadder.FALL_BACK_AFTER

    /** [n] pictures at [ms]; how many of them moved it down. */
    private fun LambentUpscaleLadder.feed(n: Int, ms: Float, interval: Float = sixty) = (1..n).count { timed(ms, interval) }

    @Test
    fun startsOnR3() = assertEquals(3, LambentUpscaleLadder().radius)

    @Test
    fun aGpuThatKeepsUpStaysOnR3() {
        val ladder = LambentUpscaleLadder()
        assertEquals(0, ladder.feed(2000, 11.5f, 1000f / 24f))
        assertEquals(3, ladder.radius)
    }

    @Test
    fun theWarmUpIsNotCounted() {
        val ladder = LambentUpscaleLadder()
        assertEquals(0, ladder.feed(warmUp, 100f))
        assertEquals(0, ladder.over)
    }

    @Test
    fun r3TooSlowAt60StepsToR2AfterItsRun() {
        val ladder = LambentUpscaleLadder()
        // A 2019 Shield's r3 in the player (14 ms) over 80 % of 16.7 ms.
        assertEquals(0, ladder.feed(warmUp + after - 1, 14f))
        assertTrue(ladder.timed(14f, sixty))
        assertEquals(2, ladder.radius)
        assertEquals(0, ladder.over)
    }

    @Test
    fun r2GetsItsOwnWarmUpAndStaysWhenItFits() {
        val ladder = LambentUpscaleLadder()
        ladder.feed(warmUp + after, 14f)
        // Its first pictures are slow too (the new passes warming), but they are its warm-up.
        assertEquals(0, ladder.feed(warmUp, 30f))
        assertEquals(0, ladder.feed(2000, 10.8f))
        assertEquals(2, ladder.radius)
    }

    @Test
    fun r2TooSlowTooEndsInPlainScaling() {
        val ladder = LambentUpscaleLadder()
        assertEquals(2, ladder.feed(2 * (warmUp + after), 20f))
        assertNull(ladder.radius)
        assertFalse(ladder.timed(20f, sixty))
        assertNull(ladder.radius)
    }

    @Test
    fun anOccasionalSlowPictureDoesNotStepDown() {
        val ladder = LambentUpscaleLadder()
        // One in three over budget: the count goes up one, down two.
        val moves = (1..3000).count { ladder.timed(if (it % 3 == 0) 15f else 9f, sixty) }
        assertEquals(0, moves)
        assertEquals(3, ladder.radius)
    }

    @Test
    fun droppedPicturesStepDownEvenWhenTheShaderLooksInBudget() {
        // r3 at 13.0 ms is under 80 % of 16.7, but the player is dropping pictures around it.
        val ladder = LambentUpscaleLadder()
        assertEquals(1, (1..warmUp + after).count { ladder.timed(13f, sixty, dropped = true) })
        assertEquals(2, ladder.radius)
    }

    @Test
    fun anOccasionalDropDoesNotStepDown() {
        val ladder = LambentUpscaleLadder()
        val moves = (1..3000).count { ladder.timed(9f, sixty, dropped = it % 4 == 0) }
        assertEquals(0, moves)
        assertEquals(3, ladder.radius)
    }

    @Test
    fun anUnknownIntervalJudgesNothing() {
        val ladder = LambentUpscaleLadder()
        assertEquals(0, ladder.feed(2000, 100f, 0f))
        assertEquals(3, ladder.radius)
    }
}

class LambentFrameIntervalTest {
    private val sixty = 1000f / 59.94f

    @Test
    fun nothingUntilEnoughGaps() {
        val interval = LambentFrameInterval()
        repeat(LambentFrameInterval.MINIMUM_GAPS - 1) { interval.add(sixty) }
        assertEquals(0f, interval.ms, 0f)
        assertFalse(interval.isDrop(100f))
        interval.add(sixty)
        assertEquals(sixty, interval.ms, 0.001f)
    }

    @Test
    fun dropsDontLengthenTheTitlesInterval() {
        val interval = LambentFrameInterval()
        // One picture in four dropped: a mean would read 20.8 ms.
        repeat(240) { interval.add(if (it % 4 == 3) 2 * sixty else sixty) }
        assertEquals(sixty, interval.ms, 0.001f)
        assertTrue(interval.isDrop(2 * sixty))
        assertFalse(interval.isDrop(sixty))
        assertFalse(interval.isDrop(sixty * 1.2f))
    }

    @Test
    fun seeksStallsAndNonsenseAreNotTheTitles() {
        val interval = LambentFrameInterval()
        repeat(60) { interval.add(1000f / 24f) }
        interval.add(0.5f)
        interval.add(-40f)
        interval.add(5000f)
        assertEquals(1000f / 24f, interval.ms, 0.001f)
        assertFalse(interval.isDrop(5000f))
    }

    @Test
    fun aChangeOfRateIsFollowed() {
        val interval = LambentFrameInterval()
        repeat(60) { interval.add(1000f / 24f) }
        repeat(60) { interval.add(sixty) }
        assertEquals(sixty, interval.ms, 0.001f)
    }
}
