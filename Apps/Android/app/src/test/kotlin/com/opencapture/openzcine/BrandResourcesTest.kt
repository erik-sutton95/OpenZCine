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
    fun splashUsesSolidSystemHoldAndFullBleedComposeLogo() {
        val canonicalLogo =
            repositoryRoot.resolve("ios/Runner/Assets.xcassets/AppLogo.imageset/AppLogo.png")
        assertEquals(CANONICAL_APP_LOGO_SHA256, canonicalLogo.sha256())
        assertSize(canonicalLogo, width = 512, height = 512)

        // Compose splash marks: edge-to-edge AppLogo so RoundedCornerShape
        // actually rounds the logo (not the transparent padding of the old
        // system splash icon).
        val composeLogo =
            repositoryRoot.resolve(
                "Apps/Android/app/src/main/res/drawable-xxxhdpi/openzcine_app_logo.png",
            )
        assertContentEquals(
            Files.readAllBytes(canonicalLogo),
            Files.readAllBytes(composeLogo),
            "Compose splash logo must remain the byte-exact canonical AppLogo",
        )

        // System SplashScreen is solid-only (transparent icon) — no second logo.
        val theme =
            repositoryRoot.resolve("Apps/Android/app/src/main/res/values/themes.xml").readText()
        assertTrue(theme.contains("parent=\"Theme.SplashScreen\""))
        assertTrue(theme.contains("@drawable/openzcine_splash_empty"))
        assertTrue(theme.contains("postSplashScreenTheme"))
        assertTrue(
            !theme.contains("@drawable/openzcine_splash_icon"),
            "System splash must not flash the padded square logo",
        )
    }

    @Test
    fun wearResourcesStayDerivedFromTheCanonicalIconAndLogo() {
        val canonicalIcon =
            repositoryRoot.resolve(
                "ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
            )
        val canonicalLogo =
            repositoryRoot.resolve("ios/Runner/Assets.xcassets/AppLogo.imageset/AppLogo.png")
        assertEquals(CANONICAL_APP_ICON_SHA256, canonicalIcon.sha256())
        assertEquals(CANONICAL_APP_LOGO_SHA256, canonicalLogo.sha256())

        val resources = repositoryRoot.resolve("Apps/Android/wear/src/main/res")
        WEAR_LAUNCHERS.forEach { (density, expected) ->
            val launcher = resources.resolve("mipmap-$density/ic_launcher.png")
            assertSize(launcher, width = expected.size, height = expected.size)
            assertEquals(expected.sha256, launcher.sha256())
        }
        WEAR_LOGOS.forEach { (density, expected) ->
            val logo = resources.resolve("drawable-$density/openzcine_app_logo.png")
            assertSize(logo, width = expected.size, height = expected.size)
            assertEquals(expected.sha256, logo.sha256())
        }
        assertContentEquals(
            Files.readAllBytes(canonicalLogo),
            Files.readAllBytes(resources.resolve("drawable-xxxhdpi/openzcine_app_logo.png")),
            "The full-density Wear launch logo must remain the byte-exact canonical AppLogo",
        )
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

        val WEAR_LAUNCHERS =
            mapOf(
                "mdpi" to
                    ExpectedLauncher(
                        size = 48,
                        sha256 =
                            "d8aaab574cc730fc6add64215dd7be4d4c9e3c75704b52c49cbcebfaeeeced5d",
                    ),
                "hdpi" to
                    ExpectedLauncher(
                        size = 72,
                        sha256 =
                            "0ff2860b418b38546e9e6627d87e158b23d41546ed86bf63ca0e10b23067a073",
                    ),
                "xhdpi" to
                    ExpectedLauncher(
                        size = 96,
                        sha256 =
                            "0d523de01cc22fb2abbc36abf5b98c0c5c820851e13fd9b26edc4107d5635612",
                    ),
                "xxhdpi" to
                    ExpectedLauncher(
                        size = 144,
                        sha256 =
                            "486a604bc32e9b31799b86961600e3cd5e1dabffb9ae519e526d3a8f1750b3f5",
                    ),
                "xxxhdpi" to
                    ExpectedLauncher(
                        size = 192,
                        sha256 =
                            "6eb852523ea1f7721552aa1bfb3bf69bd443a4a3ca71e1be84b8ce943fdc8516",
                    ),
            )

        val WEAR_LOGOS =
            mapOf(
                "mdpi" to
                    ExpectedLauncher(
                        size = 128,
                        sha256 =
                            "f159ce3e65b10d074c83bfa98253abf9d77f3a68588a317fab758d8dab542ff2",
                    ),
                "hdpi" to
                    ExpectedLauncher(
                        size = 192,
                        sha256 =
                            "97dee875a152217f52fe63f41417271cbe1d8afba28c8be9944683196267528a",
                    ),
                "xhdpi" to
                    ExpectedLauncher(
                        size = 256,
                        sha256 =
                            "64fd85f34a682d6c46cfa40c97e62bc63ac296ef5fa4ff79e8a5f8ef8697a469",
                    ),
                "xxhdpi" to
                    ExpectedLauncher(
                        size = 384,
                        sha256 =
                            "4b7227009da915b66e1e829f10451ed48e2e94794a5e4c3d42ff3195076c85e5",
                    ),
                "xxxhdpi" to
                    ExpectedLauncher(
                        size = 512,
                        sha256 = CANONICAL_APP_LOGO_SHA256,
                    ),
            )
    }
}
