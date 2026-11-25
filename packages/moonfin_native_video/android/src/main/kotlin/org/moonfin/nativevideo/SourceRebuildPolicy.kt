package org.moonfin.nativevideo

/** Keeps decoder replacement decisions aligned with the source setup adapter. */
internal object SourceRebuildPolicy {
    fun shouldRebuild(
        playerHasLoadedSource: Boolean,
        mediaTypeChanged: Boolean,
        decoderPreferenceChanged: Boolean,
        nextIsAudio: Boolean,
    ): Boolean = mediaTypeChanged || decoderPreferenceChanged ||
        (!nextIsAudio && playerHasLoadedSource)

    /**
     * Whether a rebuilt player takes over the video view of the one before it,
     * and with it the frame still on screen. Only a reopen of the same title
     * does (its enhancement settings changed): the picture then never leaves
     * the screen, so a television in Dolby Vision or HDR stays in it instead of
     * dropping out and coming back. Every other source gets a fresh view, which
     * works around decoders that hang on a reused surface. A view the decoder
     * did not draw into itself (the Auto HDR renderer did) is not kept either:
     * its surface has that renderer's format and size.
     */
    fun keepVideoView(
        reopen: Boolean,
        nextIsAudio: Boolean,
        mediaTypeChanged: Boolean,
        decoderDrawsIntoView: Boolean,
    ): Boolean = reopen && !nextIsAudio && !mediaTypeChanged && decoderDrawsIntoView
}
