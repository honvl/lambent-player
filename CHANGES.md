# Changes from Moonfin

Lambent is a modified version of [Moonfin](https://github.com/Moonfin-Client/Moonfin-Core), changed by Honver Lam from 30 October 2026 on, starting from upstream commit `fc19dbdb249b`. This file and the git history record which files changed and when, as GPL-2.0 section 2(a) asks.

## In short

- Presented as Lambent: name, icons, a glass skin for the TV and player screens.
- Works with Lambent Server: enhanced streams, the compare, on-device upscaling and HDR, downloads, and Lambent Enhance purchases.
- Removed from Lambent's builds: retro games and their emulator cores, Moonfin's update check, donation links and push messaging.

## Commits

- 2026-11-10 TV: the Lambent Enhance purchase rows show which one the remote is on
- 2026-11-10 Apple TV: Lambent Enhance bought in the app through StoreKit 2 (tvos/Runner/AppleTvStoreChannel.swift), and the version shown at start-up comes from the build
- 2026-11-09 Lambent's name goes into upstream's strings as they load (tool/gen_lambent_l10n.py), so the translation files stay as upstream ships them
- 2026-11-09 Merge upstream Moonfin main (637 commits)
- 2026-11-04 Direct play: upscale and HDR lift on the device for a paid screen
- 2026-11-04 Apple TV: upscale and HDR lift only when the plan asks (cup, chdr=1)
- 2026-11-04 TV libraries keep the floating sidebar, no home button
- 2026-11-03 Hide Seerr behind one switch
- 2026-11-03 Downloads: wait for the server instead of failing when the connection drops
- 2026-11-03 Lambent Server: download originals only
- 2026-11-03 iPad: only the work worth its power; Auto HDR on the device when the plan says chdr=1
- 2026-11-03 LiftBench: the iPad's HDR lift cost (LIFT_HDR) and the screen's EDR headroom
- 2026-11-03 TV show page opens on its On Deck episode, as Plex's does
- 2026-11-03 Play test fixes: forward each Play purchase once; ask for notifications on the first download
- 2026-11-02 StoreKit test fixes: load products again on the Enhance screen; forward each purchase once
- 2026-11-02 AI upscaler from 1.4x only: under it the shaders take the picture
- 2026-11-02 LiftBench: the iPad's upscale (LIFT_IPAD), timed at the player's size on the screen
- 2026-11-02 iPad: Lambent's upscaler on the device when the plan asks (cup)
- 2026-11-02 Foldables: move the player's landscape lock with the fold; stream media through the test proxy
- 2026-11-02 iPad fixes: subtitle canvas on the software path, enhancement chip in the centred layout, cast rail overflow
- 2026-11-02 Without Enhance or a trial, enhancement is compare-only
- 2026-11-02 Lambent Enhance on mobile: licence status, store purchases forwarded to the server, phone-only landscape lock
- 2026-11-02 WIP: mobile identity, Bonjour, Firebase off, touch enhancement panel
- 2026-11-02 Apple TV AI upscaler: a Neural Engine student above 30 fps; finish folded into the last pass
- 2026-11-02 Apple TV AI upscaler: the network's buffers are IOSurfaces (A16: 26 -> 17.6 ms a picture)
- 2026-11-02 Apple TV: never drop the HDR lift mid-title; the lift as a 65^3 table
- 2026-11-02 Apple TV AI upscaler: drop the HDR lift before the upscaler; late counts the slowest stage
- 2026-11-02 Apple TV AI upscaler: three stages (pack, network, finish), 30 fps on an A16
- 2026-11-02 Apple TV AI upscaler: int8 models optional, lift kernels timed, pack wait measured
- 2026-11-02 Apple TV AI upscaler: network and GPU at once, direct read at 2x; timed on an A16
- 2026-11-02 Apple TV: Lambent's AI upscaler on the Neural Engine, and upscaling without the HDR lift
- 2026-11-01 Apple TV upscaler: step down on throughput, measured on an A16
- 2026-11-01 Apple TV Auto HDR: upscale to the screen with FSRCNNX (A19) or RAVU-lite
- 2026-11-01 Android TV: HDR comes from the PC, not the device
- 2026-11-01 Android TV Auto HDR: upscale to the screen in the stage (RAVU-lite), not in the HWC
- 2026-11-01 HDR on this TV is on by default whenever Enhance on PC is off
- 2026-11-01 Android TV: Auto HDR on the device for SDR titles (ExoPlayer)
- 2026-11-01 Apple TV: Auto HDR on the device for SDR titles (prototype)
- 2026-11-01 TV details pages laid out like Plex's; Inter Display and Figtree on glass
- 2026-11-01 TV sidebar as Plex draws it; library icons by kind; no home videos in the banner
- 2026-11-01 Android TV: the system's focus and select sounds as the remote moves
- 2026-11-01 Details page: the hero column fits the row on Apple TV
- 2026-11-01 tvos/tools/RemoteDriver: drive an Apple TV simulator with the Siri Remote
- 2026-11-01 Apple TV native player: the same bar as Android TV, and a morphing play/pause
- 2026-11-01 TV player bar: subtitles, audio and next on top, no seek buttons, a morphing play/pause
- 2026-11-01 Android TV: Lambent's live ASS tracks, fed to libass as the PC reads them
- 2026-11-01 Apple TV player: smaller buttons, more room between the seek bar and the row
- 2026-11-01 Apple TV: the glass bar as Android TV draws it, the compare tag, full previews
- 2026-11-01 Apple TV: Lambent's Liquid Glass player in the native Swift player
- 2026-11-01 Apple TV: the Flutter player by default, so it shows Lambent's glass player
- 2026-11-01 Skip the first-run setup wizard: Lambent's defaults are the glass layout
- 2026-11-01 Apple TV: Lambent's icon, Top Shelf banners, app id and team
- 2026-11-01 Apple TV: find Lambent Server through the system's Bonjour
- 2026-11-01 Apple TV: adopt the scene life cycle, which the tvOS 27 SDK requires to launch
- 2026-11-01 Mark the PlaybackInfo request playback starts from (LambentPlay), so Lambent Server starts the PC while the TV switches mode
- 2026-11-01 Theme music on by default, as Plex plays a show's theme; screensaver test follows the night-landscape default
- 2026-10-31 TV player: Back cancels a preview seek instead of letting it land
- 2026-10-31 TV player: the first left/right press previews when the title has thumbnails
- 2026-10-31 Wide colour's own default is 100%
- 2026-10-31 Player: an Enhanced tag on the right half while Compare is on
- 2026-10-31 4K HDR panel: Compare with original, and slider tracks on the picture rows
- 2026-10-31 Wide colour defaults to 50%; the panel says Off at 0
- 2026-10-31 Wide colour in the Lambent enhancement panel and settings (gamut)
- 2026-10-31 Count subtitles delivered inside an HLS stream as the stream's own tracks
- 2026-10-30 Find Lambent Server over Bonjour; match the film's frame rate on TV
- 2026-10-30 Glass TV player: narrower compact bar, smoother reopen, less rebuilding
- 2026-10-30 Brand: use the Vision Pro sunset mark instead of the amber orb
- 2026-10-30 Compact glass player bar, PC-enhancement off and defaults, simpler settings
- 2026-10-30 Night landscape screensaver, the default idle screen
- 2026-10-30 Match the enhancement panel's brightness and peak ranges to the server
- 2026-10-30 Enhancement panel on the 4K HDR chip; fix details chips; My Media off
- 2026-10-30 Lambent glass layout: hero + first row home, glass chips and title on details
- 2026-10-30 Brand: present as Lambent (strings, logo/icons/banner, app label, hide Moonfin support/update surfaces)
- 2026-10-30 Lambent glass TV player: enhancement chip, glass back button and title block, lighter fades
- 2026-10-30 Lambent glass skin: amber accent, rounded cards, floating TV player bar
