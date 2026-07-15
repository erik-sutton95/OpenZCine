package com.opencapture.openzcine

import java.awt.image.BufferedImage
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BrandResourcesTest {
    private val repositoryRoot =
        Path.of(
            requireNotNull(System.getProperty("openzcine.repositoryRoot")) {
                "Gradle must expose the OpenZCine repository root to brand resource tests"
            },
        )

    @Test
    fun launcherResourcesCannotFallBackToTheHandDrawnVector() {
        val canonicalIcon =
            repositoryRoot.resolve(
                "ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
            )
        assertEquals(CANONICAL_APP_ICON_SHA256, canonicalIcon.sha256())
        assertSize(canonicalIcon, width = 1_024, height = 1_024)

        val resources = repositoryRoot.resolve("Apps/Android/app/src/main/res")
        val adaptiveForeground =
            resources.resolve("drawable-xxxhdpi/openzcine_launcher_foreground.png")
        assertSize(adaptiveForeground, width = 432, height = 432)
        assertEquals(ADAPTIVE_FOREGROUND_SHA256, adaptiveForeground.sha256())

        val oldVector = resources.resolve("drawable/ic_openzcine_launcher_foreground.xml")
        assertFalse(Files.exists(oldVector), "The Android-specific launcher redraw must stay deleted")

        listOf("ic_launcher.xml", "ic_launcher_round.xml").forEach { fileName ->
            val adaptiveConfig =
                resources.resolve("mipmap-anydpi-v26/$fileName").readText()
            assertTrue(
                adaptiveConfig.contains("@drawable/openzcine_launcher_foreground"),
                "$fileName must use the raster derived from the canonical AppIcon",
            )
            assertFalse(adaptiveConfig.contains("ic_openzcine_launcher_foreground"))
        }

        LEGACY_LAUNCHERS.forEach { (density, expected) ->
            val normal = resources.resolve("mipmap-$density/ic_launcher.png")
            val round = resources.resolve("mipmap-$density/ic_launcher_round.png")
            assertSize(normal, width = expected.size, height = expected.size)
            assertSize(round, width = expected.size, height = expected.size)
            assertEquals(expected.sha256, normal.sha256())
            assertContentEquals(
                Files.readAllBytes(normal),
                Files.readAllBytes(round),
                "Normal and round fallbacks must come from the same AppIcon transform",
            )
        }
    }

    @Test
    fun splashContainsTheCanonicalLogoWithoutRedrawingIt() {
        val canonicalLogo =
            repositoryRoot.resolve("ios/Runner/Assets.xcassets/AppLogo.imageset/AppLogo.png")
        assertEquals(CANONICAL_APP_LOGO_SHA256, canonicalLogo.sha256())
        assertSize(canonicalLogo, width = 512, height = 512)

        val splash =
            repositoryRoot.resolve(
                "Apps/Android/app/src/main/res/drawable-xxxhdpi/openzcine_splash_icon.png",
            )
        assertSize(splash, width = 1_152, height = 1_152)
        assertCenteredPixelsMatch(sourcePath = canonicalLogo, canvasPath = splash)

        val theme =
            repositoryRoot.resolve("Apps/Android/app/src/main/res/values/themes.xml").readText()
        assertTrue(theme.contains("parent=\"Theme.SplashScreen\""))
        assertTrue(theme.contains("@drawable/openzcine_splash_icon"))
        assertTrue(theme.contains("postSplashScreenTheme"))
    }

    private fun assertCenteredPixelsMatch(sourcePath: Path, canvasPath: Path) {
        val source = sourcePath.readImage()
        val canvas = canvasPath.readImage()
        val offsetX = (canvas.width - source.width) / 2
        val offsetY = (canvas.height - source.height) / 2

        for (y in 0 until source.height) {
            for (x in 0 until source.width) {
                assertEquals(
                    source.getRGB(x, y),
                    canvas.getRGB(offsetX + x, offsetY + y),
                    "AppLogo pixel changed at ($x, $y)",
                )
            }
        }
        assertEquals(0, canvas.getRGB(0, 0) ushr 24, "Splash padding must stay transparent")
    }

    private fun assertSize(path: Path, width: Int, height: Int) {
        val image = path.readImage()
        assertEquals(width, image.width, "$path width")
        assertEquals(height, image.height, "$path height")
    }

    private fun Path.readImage(): BufferedImage =
        requireNotNull(ImageIO.read(toFile())) { "$this must remain a readable raster image" }

    private fun Path.readText(): String =
        String(Files.readAllBytes(this), Charsets.UTF_8)

    private fun Path.sha256(): String =
        MessageDigest.getInstance("SHA-256")
            .digest(Files.readAllBytes(this))
            .joinToString(separator = "") { byte ->
                Integer.toHexString(byte.toInt() and 0xFF).padStart(2, '0')
            }

    private companion object {
        data class ExpectedLauncher(val size: Int, val sha256: String)

        const val CANONICAL_APP_ICON_SHA256 =
            "5674c7f0280c165f261a7f0c832bb6c72d89ec377ae648d834781f348dc784df"
        const val CANONICAL_APP_LOGO_SHA256 =
            "16a4137131b2f79f627a50f64031d38a032eb38e2a0cf3fd0e390d5bd2d30d48"
        const val ADAPTIVE_FOREGROUND_SHA256 =
            "cadd842dd46cce4167a5c6ff87d9ba2ff6b6d375e2c5d9ceb83a9619f79d9fd9"

        val LEGACY_LAUNCHERS =
            mapOf(
                "mdpi" to
                    ExpectedLauncher(
                        size = 48,
                        sha256 =
                            "2b6ac63211990c536d69834a1bfe8253bf4e810d253394c31213c9ab5fcf162e",
                    ),
                "hdpi" to
                    ExpectedLauncher(
                        size = 72,
                        sha256 =
                            "713fd8e329130e489b1d3fcd034900f9ff17f6d82c97f8b8e83341f732be8b1b",
                    ),
                "xhdpi" to
                    ExpectedLauncher(
                        size = 96,
                        sha256 =
                            "9b0d64c72cea4a7a3d1b63566e7f47f292e9057394ad2a3367f5a997ee5575f5",
                    ),
                "xxhdpi" to
                    ExpectedLauncher(
                        size = 144,
                        sha256 =
                            "e8e7b2aae40494d5104fbc0d0e1f7839b8a9a082d22b4f6f41bc6338cc61592b",
                    ),
                "xxxhdpi" to
                    ExpectedLauncher(
                        size = 192,
                        sha256 =
                            "bc9a4b8a7c2baaa874b1706cd03f9ea2436c7b1fc14c1f677216794b9f8015cd",
                    ),
            )
    }
}
