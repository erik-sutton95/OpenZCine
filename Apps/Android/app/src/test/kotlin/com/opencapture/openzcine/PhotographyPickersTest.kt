package com.opencapture.openzcine

import com.opencapture.opencine.vocabulary.LadderWrite
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlCapabilities
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertyRefreshStatus
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.NikonLadderControl
import com.opencapture.opencine.nikon.WhiteBalanceTint
import com.opencapture.opencine.vocabulary.CaptureTint
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** JVM coverage for the photography picker presentations and stills policy. */
class PhotographyPickersTest {
    private val snapshot =
        CameraPropertySnapshot(
            iso = 800,
            isoAuto = false,
            exposureMode = "M",
            shutterSpeed = "1/250",
            iris = "f/2.8",
            whiteBalanceMode = "Auto",
            captureSelector = "photo",
            stillCaptureMode = "Single",
            imageSize = "Size L",
            compression = "RAW+JPEG Fine",
            meteringMode = "Matrix",
            pictureControl = "Standard",
            userModeProgram = null,
            imageArea = "FX",
            rawCompression = "High efficiency",
        )

    private fun settings(
        properties: CameraPropertySnapshot = snapshot,
        timerDelay: Int = 0,
    ) = photographyCaptureSettings(
        properties = properties,
        wbPicker = null,
        photoTimerDelaySeconds = timerDelay,
    )

    @Test
    fun `photo WB keeps the advertised Auto preset while the movie codec filters it`() {
        val properties = snapshot.copy(
            codec = "R3D NE",
            codecSelection = "R3D NE",
            whiteBalanceMode = "Daylight",
            whiteBalanceTint = "A1 · M0.25",
            controlCapabilities = CameraControlCapabilities(
                whiteBalanceValues = listOf("Auto", "Daylight"),
                whiteBalanceTints = listOf("Neutral", "A1 · M0.25"),
            ),
        )
        val dashboard = commandDashboardPresentation(
            snapshot = properties,
            refreshStatus = CameraPropertyRefreshStatus.Ready,
            sessionState = CameraSessionState.Connected(CameraIdentity("body", "Body", "unit-camera")),
            tileOrder = CommandTileKind.entries,
        )
        val movie = assertNotNull(monitorCaptureSettings(dashboard, PhoneStringResolver { resource, _ -> resource.toString() })
            .first { it.kind == MonitorPickerKind.WHITE_BALANCE }.picker)
        val photo = assertNotNull(photographyCaptureSettings(properties, movie, photoTimerDelaySeconds = 0)
            .first { it.kind == MonitorPickerKind.WHITE_BALANCE }.picker)
        val movieSheet = videoLadderPresentation(movie)
        val photoSheet = videoLadderPresentation(photo)
        val moviePresets = movieSheet.tabs.single { it.key == NikonLadderControl.Value(1) }
        val photoPresets = photoSheet.tabs.single { it.key == NikonLadderControl.Value(1) }
        assertEquals(listOf("Daylight"), moviePresets.ladder.values)
        assertEquals(listOf("Auto", "Daylight"), photoPresets.ladder.values)
        assertEquals(movie.modes, photo.modes, "Photo composition must retain the body's requests and mode keys")
        val (request, value) = assertNotNull(requestForLadderWrite(photo, LadderWrite(photoPresets.key, "Auto")))
        assertEquals(CameraControl.WHITE_BALANCE to "Auto", request.control to value)
        assertEquals(listOf("Auto", "Daylight"), request.options)
        assertEquals(CaptureTint(greenMagenta = -1, amberBlue = 2, range = WhiteBalanceTint.cellRange),
            photoSheet.tabs.single { it.key == NikonLadderControl.Value(2) }.tint)
        assertFalse(nikonCapturePopup(movie).photography, "Photo composition must not mutate the movie popup")
        assertTrue(nikonCapturePopup(photo).photography)
    }

    @Test
    fun `strip renders the iOS tile order with pinned widths and live values`() {
        val tiles = settings()

        assertEquals(
            listOf(
                MonitorPickerKind.MODE, MonitorPickerKind.ISO, MonitorPickerKind.SHUTTER,
                MonitorPickerKind.IRIS, MonitorPickerKind.DRIVE, MonitorPickerKind.FOCUS,
                MonitorPickerKind.WHITE_BALANCE, MonitorPickerKind.METER,
                MonitorPickerKind.PROFILE,
            ),
            tiles.map { it.kind },
        )
        assertEquals(
            listOf("Auto", "25600", "1/16000", "f/2.8", "Single", "Wide-L", "5560K", "Matrix", "Auto"),
            tiles.map { it.widestValue },
        )
        // Every tile except the caller-supplied WB opens a picker in M.
        assertTrue(tiles.filter { it.kind != MonitorPickerKind.WHITE_BALANCE }.all { it.picker != null })
    }

    @Test
    fun `only the histogram scope is billed in photography`() {
        // The cinema scopes are suppressed at render, so a photography scope band
        // must bill only the histogram — otherwise a dead gap opens under the feed.
        assertTrue(ScopeKind.HISTOGRAM.appliesToPhotography)
        assertEquals(
            listOf(ScopeKind.HISTOGRAM),
            ScopeKind.entries.filter { it.appliesToPhotography },
        )
    }

    @Test
    fun `iso picker seeds auto and manual tabs from camera truth`() {
        val manual = settings().first { it.kind == MonitorPickerKind.ISO }.picker
        assertNotNull(manual)
        // isoAuto false opens Manual (iOS stillISOPickerModeIndex).
        assertEquals(1, manual.initialModeIndex)
        assertEquals("Auto", manual.modes[0].label)
        assertTrue(manual.modes[0].drumLocked)
        assertEquals("On", manual.modes[0].activateRequest?.currentValue)
        assertFalse(manual.modes[0].applyValueOnActivate)
        assertEquals("Off", manual.modes[1].activateRequest?.currentValue)
        assertTrue(manual.modes[1].applyValueOnActivate)
        assertFalse(manual.modes[1].disabled)
        assertEquals("800", manual.modes[1].request.currentValue)

        val auto =
            settings(snapshot.copy(isoAuto = true, iso = 51200))
                .first { it.kind == MonitorPickerKind.ISO }.picker
        assertNotNull(auto)
        assertEquals(0, auto.initialModeIndex)
        // The live Auto value joins the ladder so the locked drum can centre on it.
        assertTrue("51200" in auto.modes[0].request.options)

        // Full-auto program: Manual grays out (iOS pickerModeDisabled).
        val fullAuto =
            settings(snapshot.copy(exposureMode = "Auto"))
                .first { it.kind == MonitorPickerKind.ISO }.picker
        assertNotNull(fullAuto)
        assertTrue(fullAuto.modes[1].disabled)
    }

    @Test
    fun `mode picker gates the U-bank inner program to the banks`() {
        val outside = settings().first { it.kind == MonitorPickerKind.MODE }.picker
        assertNotNull(outside)
        assertEquals(listOf("Mode", "U Mode"), outside.modes.map { it.label })
        assertTrue(outside.modes[1].disabled)
        assertEquals(CameraControl.EXPOSURE_MODE, outside.modes[0].request.control)
        assertEquals(
            CameraControl.STILL_USER_MODE_PROGRAM,
            outside.modes[1].request.control,
        )

        val inBank =
            settings(snapshot.copy(exposureMode = "U2", userModeProgram = "A"))
                .first { it.kind == MonitorPickerKind.MODE }.picker
        assertNotNull(inBank)
        assertFalse(inBank.modes[1].disabled)
        assertEquals("A", inBank.modes[1].request.currentValue)
    }

    @Test
    fun `shutter and iris gray outside their programs including U banks`() {
        // M allows both.
        assertTrue(settings().first { it.kind == MonitorPickerKind.SHUTTER }.picker != null)
        assertTrue(settings().first { it.kind == MonitorPickerKind.IRIS }.picker != null)

        // A: aperture stays, shutter grays (live readout, no picker).
        val aperturePriority = settings(snapshot.copy(exposureMode = "A"))
        val shutterTile = aperturePriority.first { it.kind == MonitorPickerKind.SHUTTER }
        assertNull(shutterTile.picker)
        assertTrue(shutterTile.dimmed)
        assertEquals("1/250", shutterTile.value)
        assertFalse(aperturePriority.first { it.kind == MonitorPickerKind.IRIS }.dimmed)

        // S: shutter stays, iris grays.
        val shutterPriority = settings(snapshot.copy(exposureMode = "S"))
        assertNull(shutterPriority.first { it.kind == MonitorPickerKind.IRIS }.picker)
        assertNotNull(shutterPriority.first { it.kind == MonitorPickerKind.SHUTTER }.picker)

        // A U bank resolves through its inner program (U1 running as S).
        val bank = settings(snapshot.copy(exposureMode = "U1", userModeProgram = "S"))
        assertNull(bank.first { it.kind == MonitorPickerKind.IRIS }.picker)
        assertNotNull(bank.first { it.kind == MonitorPickerKind.SHUTTER }.picker)
    }

    @Test
    fun `shutter picker prefers the camera speed enum over the ladder`() {
        val cameraEnum =
            snapshot.copy(
                controlCapabilities =
                    CameraControlCapabilities(shutterValues = listOf("1/125", "1/250", "1/500")),
            )
        val picker = settings(cameraEnum).first { it.kind == MonitorPickerKind.SHUTTER }.picker
        assertNotNull(picker)
        assertEquals(listOf("1/125", "1/250", "1/500"), picker.modes[0].request.options)
        assertEquals("1/250", picker.modes[0].request.currentValue)

        // Ladder fallback keeps Bulb and the whole-second forms.
        val fallback = settings().first { it.kind == MonitorPickerKind.SHUTTER }.picker
        assertNotNull(fallback)
        assertTrue("Bulb" in fallback.modes[0].request.options)
        assertTrue("30s" in fallback.modes[0].request.options)
    }

    @Test
    fun `every function picker prefers the body's advertised list over the ladder`() {
        // #274: the drums must mirror the connected body — its values, in its order — not a
        // fixed union of the Z lineup. A Z6III's release order is Single, CL, CH, CH+.
        val body =
            snapshot.copy(
                exposureMode = "P",
                controlCapabilities =
                    CameraControlCapabilities(
                        exposureModes = listOf("Auto", "P", "S", "A", "M"),
                        driveModes =
                            listOf(
                                "Single", "Continuous L", "Continuous H", "Continuous H+",
                            ),
                        meteringModes = listOf("Matrix", "Spot"),
                        pictureControls = listOf("Standard", "Flat", "Custom 1"),
                        focusModes = listOf("AF-S", "AF-C", "AF-A", "MF"),
                        focusAreas = listOf("Single", "3D tracking", "Auto"),
                        focusSubjects = listOf("Off", "People"),
                    ),
            )
        val built = settings(body)
        fun options(kind: MonitorPickerKind, tab: Int = 0) =
            assertNotNull(built.first { it.kind == kind }.picker).modes[tab].request.options

        assertEquals(listOf("Auto", "P", "S", "A", "M"), options(MonitorPickerKind.MODE))
        assertEquals(
            listOf("Single", "Continuous L", "Continuous H", "Continuous H+"),
            options(MonitorPickerKind.DRIVE),
        )
        assertEquals(listOf("Matrix", "Spot"), options(MonitorPickerKind.METER))
        assertEquals(
            listOf("Standard", "Flat", "Custom 1"),
            options(MonitorPickerKind.PROFILE),
        )
        assertEquals(listOf("Single", "3D tracking", "Auto"), options(MonitorPickerKind.FOCUS, 1))
        assertEquals(listOf("Off", "People"), options(MonitorPickerKind.FOCUS, 2))
    }

    @Test
    fun `the mode fallback never invents user banks and the body's banks still show`() {
        // The reported Zf: offered U1/U2/U3 it does not have. With no advertised program enum
        // the drum keeps the conservative ladder.
        val fallback =
            assertNotNull(settings().first { it.kind == MonitorPickerKind.MODE }.picker)
        assertEquals(listOf("Auto", "P", "S", "A", "M"), fallback.modes[0].request.options)
        assertFalse(fallback.modes[0].request.options.any { it.startsWith("U") })

        // A body that DOES advertise banks still gets them — the rule is "what the body says".
        val withBanks =
            settings(
                snapshot.copy(
                    controlCapabilities =
                        CameraControlCapabilities(
                            exposureModes = listOf("P", "S", "A", "M", "U1", "U2", "U3"),
                        ),
                ),
            ).first { it.kind == MonitorPickerKind.MODE }.picker
        assertNotNull(withBanks)
        assertTrue("U3" in withBanks.modes[0].request.options)
    }

    @Test
    fun `an advertised drive list still hides the positions the app owns`() {
        // Quick is dial-only and Self-timer belongs to the Built-in Timer tab, even when the
        // body lists them.
        val picker =
            settings(
                snapshot.copy(
                    controlCapabilities =
                        CameraControlCapabilities(
                            driveModes =
                                listOf("Single", "Self-timer", "Continuous L", "Quick"),
                        ),
                ),
            ).first { it.kind == MonitorPickerKind.DRIVE }.picker
        assertNotNull(picker)
        assertEquals(listOf("Single", "Continuous L"), picker.modes[0].request.options)
    }

    @Test
    fun `focus area names the body's settings and never the subject-detection tab`() {
        // "3D tracking" and "Subject tracking" are AF-AREA modes; the Subject tab is subject
        // DETECTION. Collapsing either into a generic "Subject" is the #274 label report.
        val picker = assertNotNull(settings().first { it.kind == MonitorPickerKind.FOCUS }.picker)
        val areas = picker.modes[1].request.options
        val subjects = picker.modes[2].request.options
        assertTrue("3D tracking" in areas)
        assertFalse("Subject" in areas)
        assertFalse("3D" in areas)
        assertFalse(subjects.any { it in areas && it != "Auto" })
    }

    @Test
    fun `drive picker mirrors the iOS timer tab exclusivity`() {
        val idle = settings().first { it.kind == MonitorPickerKind.DRIVE }.picker
        assertNotNull(idle)
        assertEquals(listOf("Drive", "Built-in Timer", "App-timer"), idle.modes.map { it.label })
        assertFalse(idle.modes[0].disabled)
        assertTrue(idle.modes[1].showsTimerShots)
        assertTrue(idle.modes[2].showsTimerShots)
        // Quick and Self-timer never appear in the Drive drum.
        assertFalse("Quick" in idle.modes[0].request.options)
        assertFalse("Self-timer" in idle.modes[0].request.options)

        // Body timer engaged: Drive + App-timer gray, Built-in reads On.
        val bodyTimer =
            settings(snapshot.copy(stillCaptureMode = "Self-timer"))
                .first { it.kind == MonitorPickerKind.DRIVE }.picker
        assertNotNull(bodyTimer)
        assertTrue(bodyTimer.modes[0].disabled)
        assertEquals("On", bodyTimer.modes[1].request.currentValue)
        assertTrue(bodyTimer.modes[2].disabled)

        // App timer armed: Built-in grays, App reads its delay.
        val appTimer =
            settings(timerDelay = 5).first { it.kind == MonitorPickerKind.DRIVE }.picker
        assertNotNull(appTimer)
        assertTrue(appTimer.modes[1].disabled)
        assertEquals("5s", appTimer.modes[2].request.currentValue)
    }

    @Test
    fun `an unreported value stays unknown instead of seeding the drum`() {
        // A3-29: a seeded current (ISO 800, JPEG Fine) reads as already applied, so picking it sent
        // no write while the body's value was unknown. Only the app's own timer has a known value.
        val unknown = CameraPropertySnapshot(captureSelector = "photo")
        val pickers = settings(unknown).mapNotNull { it.picker } + photographyTopBarPickers(unknown).values
        val seeded =
            pickers.flatMap { picker -> picker.modes.map { "${picker.kind}/${it.label}" to it.request.currentValue } }
                .filter { (tab, current) -> current.isNotEmpty() && tab != "DRIVE/App-timer" }
        assertEquals(emptyList(), seeded)
    }

    @Test
    fun `each drive tab writes through its own request`() {
        // A3-03: all three tabs drive STILL_DRIVE and two offer "Off". App-timer Off must
        // clear the app delay, not reach the body's Built-in Timer.
        val drive = settings(timerDelay = 5).first { it.kind == MonitorPickerKind.DRIVE }.picker
        assertNotNull(drive)
        val tabs = videoLadderPresentation(drive).tabs
        fun titleFor(tab: Int, value: String) =
            requestForLadderWrite(drive, LadderWrite(tabs[tab].key, value))?.first?.title

        assertEquals("App-timer", titleFor(2, "Off"))
        assertEquals("App-timer", titleFor(2, "10s"))
        assertEquals("Built-in Timer", titleFor(1, "Off"))
        assertEquals("DRIVE", titleFor(0, "Single"))
    }

    @Test
    fun `focus tile and mode tab read the stills side not leftover movie AF-F`() {
        // iOS `photographyCaptureValues` used the movie `focusMode` field, so the
        // photo strip showed AF-F or "—" while the Focus panel confirmed AF-S (#272).
        val split =
            snapshot.copy(focusMode = "AF-F", stillFocusMode = "AF-S")
        val tiles = settings(split)
        val focus = tiles.first { it.kind == MonitorPickerKind.FOCUS }
        assertEquals("AF-S", focus.value)
        assertEquals("AF-S", focus.picker?.modes?.get(0)?.request?.currentValue)

        val movieOnly = snapshot.copy(focusMode = "AF-F", stillFocusMode = null)
        val blank = settings(movieOnly).first { it.kind == MonitorPickerKind.FOCUS }
        assertEquals("—", blank.value)
    }

    @Test
    fun `focus picker routes three independent stills controls`() {
        val picker = settings().first { it.kind == MonitorPickerKind.FOCUS }.picker
        assertNotNull(picker)
        assertEquals(
            listOf(
                CameraControl.STILL_FOCUS_MODE,
                CameraControl.STILL_FOCUS_AREA,
                CameraControl.STILL_FOCUS_SUBJECT,
            ),
            picker.modes.map { it.request.control },
        )
        assertTrue(picker.modes.none { it.applyValueOnActivate })
    }

    @Test
    fun `top bar pickers cover size tabs and the quality pair`() {
        val pickers = photographyTopBarPickers(snapshot)

        val size = pickers.getValue(MonitorPickerKind.SIZE)
        assertEquals(listOf("Area", "Size"), size.modes.map { it.label })
        assertEquals(CameraControl.STILL_IMAGE_AREA, size.modes[0].request.control)
        assertEquals("FX", size.modes[0].request.currentValue)
        assertEquals(CameraControl.STILL_IMAGE_SIZE, size.modes[1].request.control)
        assertEquals("Size L", size.modes[1].request.currentValue)

        // Camera-reported resolution strings take over the Size drum verbatim.
        val cameraSizes =
            photographyTopBarPickers(
                snapshot.copy(
                    imageSize = "6048x4032",
                    controlCapabilities =
                        CameraControlCapabilities(
                            imageSizes = listOf("6048x4032", "4528x3024", "3024x2016"),
                        ),
                ),
            ).getValue(MonitorPickerKind.SIZE)
        assertEquals(
            listOf("6048x4032", "4528x3024", "3024x2016"),
            cameraSizes.modes[1].request.options,
        )
        assertEquals("6048x4032", cameraSizes.modes[1].request.currentValue)

        val quality = pickers.getValue(MonitorPickerKind.QUALITY)
        assertEquals(CameraControl.STILL_QUALITY, quality.modes[0].request.control)
        assertEquals("RAW+JPEG Fine", quality.modes[0].request.currentValue)
        assertTrue(MonitorPickerKind.SIZE.isTopBarPicker())
        assertTrue(MonitorPickerKind.QUALITY.isTopBarPicker())
    }

    @Test
    fun `quality config decomposes and recomposes the camera labels`() {
        assertEquals(
            StillQualityConfig(rawEnabled = true, tier = "Off", starred = false),
            StillQualityConfig.parse("RAW"),
        )
        assertEquals(
            StillQualityConfig(rawEnabled = true, tier = "Fine", starred = false),
            StillQualityConfig.parse("RAW+JPEG Fine"),
        )
        assertEquals(
            StillQualityConfig(rawEnabled = false, tier = "Normal", starred = true),
            StillQualityConfig.parse("JPEG Normal★"),
        )
        assertNull(StillQualityConfig.parse("TIFF"))
        assertNull(StillQualityConfig.parse(null))

        // Round trips (the write path's label form).
        for (label in listOf(
            "RAW", "RAW+JPEG Fine", "RAW+JPEG Basic★", "JPEG Fine★", "JPEG Basic",
        )) {
            assertEquals(label, StillQualityConfig.parse(label)?.compressionLabel())
        }
        // The unwritable both-off state has no label.
        assertNull(
            StillQualityConfig(rawEnabled = false, tier = "Off", starred = false)
                .compressionLabel(),
        )
    }

    @Test
    fun `body capture sync mirrors the iOS event-drain guards`() {
        // Photo + PLAY armed + no app release: full sync.
        assertEquals(
            BodyCaptureSync.REVIEW_AND_SHOTS,
            bodyCaptureSyncAction(
                isPhotography = true,
                instantReviewEnabled = true,
                appReleaseInFlight = false,
            ),
        )
        // PLAY off still refreshes the shots readout.
        assertEquals(
            BodyCaptureSync.SHOTS_ONLY,
            bodyCaptureSyncAction(
                isPhotography = true,
                instantReviewEnabled = false,
                appReleaseInFlight = false,
            ),
        )
        // An app-initiated release in flight suppresses the event path — that
        // run schedules its own review on completion.
        assertEquals(
            BodyCaptureSync.IGNORE,
            bodyCaptureSyncAction(
                isPhotography = true,
                instantReviewEnabled = true,
                appReleaseInFlight = true,
            ),
        )
        // Movie mode never reacts.
        assertEquals(
            BodyCaptureSync.IGNORE,
            bodyCaptureSyncAction(
                isPhotography = false,
                instantReviewEnabled = true,
                appReleaseInFlight = false,
            ),
        )
    }

    @Test
    fun `photo timer labels round trip`() {
        assertEquals("Off", photoTimerLabel(0))
        assertEquals("5s", photoTimerLabel(5))
        assertEquals(0, photoTimerSeconds("Off"))
        assertEquals(10, photoTimerSeconds("10s"))
    }

    @Test
    fun `review info line captures the shot settings`() {
        assertEquals(
            "ISO 800   1/250   f/2.8   RAW+JPEG Fine",
            photographyReviewInfoLine(snapshot),
        )
        assertEquals(
            null,
            photographyReviewInfoLine(CameraPropertySnapshot()),
        )
    }

    @Test
    fun `size pill ranks camera resolution strings and passes size letters through`() {
        // "Size L"-form strings pass through directly.
        assertEquals("FX · L", snapshot.stillSizeAreaLabel())

        // Raw resolutions rank by pixel count against the camera's enum.
        val ranked =
            snapshot.copy(
                imageSize = "4528x3024",
                controlCapabilities =
                    CameraControlCapabilities(
                        imageSizes = listOf("6048x4032", "4528x3024", "3024x2016"),
                    ),
            )
        assertEquals("FX · M", ranked.stillSizeAreaLabel())

        // Unknown size domain: the area half still shows.
        assertEquals(
            "DX",
            snapshot.copy(imageArea = "DX", imageSize = "9999x9999").stillSizeAreaLabel(),
        )
        assertNull(snapshot.copy(imageArea = null, imageSize = null).stillSizeAreaLabel())
    }
}
