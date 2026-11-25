package org.moonfin.nativevideo

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.Looper
import android.view.View
import io.github.peerless2012.ass.AssFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.moonfin.nativevideo.MoonfinAssOverlayTestHarness.Piece
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MoonfinAssOverlayLayerTest {
    private fun attachedHarness(): MoonfinAssOverlayTestHarness {
        val h = MoonfinAssOverlayTestHarness()
        Robolectric.buildActivity(Activity::class.java).setup().get().setContentView(h.overlay)
        h.overlay.syncNativeAssTrack(Any())
        return h
    }

    private fun idleMain() = shadowOf(Looper.getMainLooper()).idle()

    @Test
    fun noFrameMeansNoLayerBitmap() {
        val h = attachedHarness()

        h.publishFrame(AssFrame(images = null, changed = 1))
        idleMain()

        assertEquals(View.LAYER_TYPE_NONE, h.overlay.layerType)
    }

    // Each frame's bitmap has a size of its own. Drawn straight to the
    // hardware canvas, each would leave a texture behind in the app's cache.
    @Test
    fun firstFrameMovesDrawingToASoftwareLayer() {
        val h = attachedHarness()

        h.publishFrame(h.frame(6, 9))
        idleMain()
        assertEquals(View.LAYER_TYPE_SOFTWARE, h.overlay.layerType)

        // A gap between cues keeps it: the layer's bitmap is the size of the
        // view either way, and the next line reuses its texture.
        h.publishFrame(AssFrame(images = null, changed = 1))
        idleMain()
        assertEquals(View.LAYER_TYPE_SOFTWARE, h.overlay.layerType)
    }

    // The layer hands onDraw a software canvas. The frame has to land on it,
    // and its buffer stays free for the next frame without a second draw.
    @Test
    fun softwareCanvasGetsTheFrameAndLeavesItsBufferFree() {
        val h = attachedHarness()
        val red = 0xFF000000.toInt()
        h.publishFrame(h.alphaFrame(Piece(x = 3, y = 5, w = 4, h = 2, assColor = red)))
        val first = requireNotNull(h.cachedComposite()).bitmap

        val layer = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888)
        h.overlay.draw(Canvas(layer))

        assertEquals(Color.RED, layer.getPixel(3, 5))
        assertEquals(Color.RED, layer.getPixel(6, 6))
        assertEquals(Color.TRANSPARENT, layer.getPixel(2, 5))
        assertEquals(Color.TRANSPARENT, layer.getPixel(7, 6))

        // Two more frames: the second may take the first one's buffer back,
        // since no hardware display list is still reading it.
        h.publishFrame(h.alphaFrame(Piece(x = 0, y = 0, w = 4, h = 2, assColor = red)))
        h.publishFrame(h.alphaFrame(Piece(x = 1, y = 1, w = 4, h = 2, assColor = red)))
        assertSame(first, requireNotNull(h.cachedComposite()).bitmap)
        assertEquals(2, h.buffers.size)
    }
}
