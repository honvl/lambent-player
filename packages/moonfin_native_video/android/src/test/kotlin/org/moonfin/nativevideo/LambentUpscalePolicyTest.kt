package org.moonfin.nativevideo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LambentUpscalePolicyTest {
    private val enhanced = "http://192.168.1.20:47800/v1/enhanced/i_42/index.m3u8?tv=1&maxh=1080"

    @Test
    fun anSdrTitleFromAnyServerIsScaled() {
        assertTrue(LambentUpscalePolicy.applies("video", false, "SDR", "http://192.168.1.20:47800/Videos/i_42/stream.mkv?static=true"))
        assertTrue(LambentUpscalePolicy.applies("video", false, "sdr", "https://plex.example/library/parts/1/file.mkv"))
    }

    @Test
    fun hdrAndAnUnknownRangeStayOnTheDirectPath() {
        val url = "https://plex.example/library/parts/1/file.mkv"
        for (range in listOf("HDR10", "HDR10Plus", "HLG", "DOVI", "DOVIWithHDR10", null, "")) {
            assertFalse("$range", LambentUpscalePolicy.applies("video", false, range, url))
        }
    }

    @Test
    fun thePcsPictureIsScaledOnlyWhenThePlanAsks() {
        assertFalse(LambentUpscalePolicy.applies("video", false, "SDR", enhanced))
        assertFalse(LambentUpscalePolicy.applies("video", false, "SDR", "$enhanced&cmp=1"))
        assertTrue(LambentUpscalePolicy.applies("video", false, "SDR", "$enhanced&cup=2160"))
    }

    @Test
    fun aStreamThePcLiftsToHdrIsNotScaledHoweverSdrTheTitle() {
        assertFalse(LambentUpscalePolicy.applies("video", false, "SDR", "$enhanced&hdr=1&dv=1&cup=2160"))
        assertFalse(LambentUpscalePolicy.applies("video", false, "SDR", "$enhanced&cup=2160&hdr=1"))
        assertTrue(LambentUpscalePolicy.applies("video", false, "SDR", "$enhanced&hdr=0&dv=0&cup=2160"))
    }

    @Test
    fun previewsAndAudioAreLeftAlone() {
        val url = "https://plex.example/library/parts/1/file.mkv"
        assertFalse(LambentUpscalePolicy.applies("video", true, "SDR", url))
        assertFalse(LambentUpscalePolicy.applies("audio", false, "SDR", url))
    }

    @Test
    fun theOutputFitsTheScreenInEvenPixels() {
        assertEquals(3840 to 2160, LambentUpscalePolicy.outputSize(1920, 1080, 3840, 2160))
        assertEquals(3840 to 1636, LambentUpscalePolicy.outputSize(1920, 818, 3840, 2160))
        assertEquals(3840 to 2160, LambentUpscalePolicy.outputSize(1280, 720, 3840, 2160))
        assertEquals(2880 to 2160, LambentUpscalePolicy.outputSize(1440, 1080, 3840, 2160))
    }

    @Test
    fun standardDefinitionMayBeAnamorphicAndStaysDirect() {
        assertNull(LambentUpscalePolicy.outputSize(720, 480, 3840, 2160))
        assertNull(LambentUpscalePolicy.outputSize(720, 576, 3840, 2160))
        assertNull(LambentUpscalePolicy.outputSize(854, 480, 3840, 2160))
        // An ultrawide 720p title is short, not standard definition.
        assertEquals(3840 to 1608, LambentUpscalePolicy.outputSize(1280, 536, 3840, 2160))
    }

    @Test
    fun aSmallScaleOrAnUnknownSizeIsNotWorthIt() {
        // 1.33x, under the shader's own 1.41x.
        assertNull(LambentUpscalePolicy.outputSize(2880, 1620, 3840, 2160))
        assertNull(LambentUpscalePolicy.outputSize(3840, 2160, 3840, 2160))
        // A 1080p title on a 1080p panel, and a phone's 1080p title.
        assertNull(LambentUpscalePolicy.outputSize(1920, 1080, 1920, 1080))
        assertNull(LambentUpscalePolicy.outputSize(1920, 1080, 2400, 1080))
        assertNull(LambentUpscalePolicy.outputSize(0, 0, 3840, 2160))
        assertNull(LambentUpscalePolicy.outputSize(1920, 1080, 0, 0))
    }
}
