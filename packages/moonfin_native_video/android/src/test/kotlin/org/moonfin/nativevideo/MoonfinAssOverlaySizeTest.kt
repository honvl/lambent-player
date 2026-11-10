package org.moonfin.nativevideo

import androidx.media3.common.util.Size
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

// The on-device upscaler gives the video a 4K surface behind a 1080p view, so
// libass is laid out on the overlay's own size, not the player's surface.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class MoonfinAssOverlaySizeTest {
    @Test
    fun libassUsesTheOverlaysSizeNotTheUpscaledSurface() {
        val h = MoonfinAssOverlayTestHarness()
        val listener = MoonfinAssPlayerListener(h.handler, h.dialogue, h.overlay)

        h.overlay.layout(0, 0, 1920, 1080)
        listener.onSurfaceSizeChanged(3840, 2160)

        assertEquals(Size(1920, 1080), h.handler.surfaceSize)
    }

    @Test
    fun aNewLayoutResizesLibass() {
        val h = MoonfinAssOverlayTestHarness()

        h.overlay.layout(0, 0, 1920, 1080)
        h.overlay.layout(0, 0, 1440, 1080)

        assertEquals(Size(1440, 1080), h.handler.surfaceSize)
    }
}
