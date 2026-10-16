package com.opencapture.openzcine.settings

import com.opencapture.opencine.cameracontrols.MonitorLegalDocument
import com.opencapture.opencine.cameracontrols.MonitorLegalDocuments
import com.opencapture.opencine.cameracontrols.MonitorPlatformLegalNotices

private val PRIVACY_BODY =
    """
OpenZCine talks to your Nikon Z camera over Wi-Fi or USB-C. The app has no account. Automatic error reports are optional and off by default.

OpenCapture is the data controller. Privacy or deletion requests: support@opencapture.org.

Optional reliability reports
With your consent, configured builds send crash, hang and feed diagnostics, app/OS/device versions and session health counts through Sentry. Automatic reports exclude all images. No footage, screenshots, raw camera packets or GPS location are included. Sentry receives the connection IP; stored event IP and derived geography are removed. Event storage uses Germany. Some provider processing may occur internationally.
Turn reporting off in System at any time without losing app features. This clears pending SDK uploads, but does not delete reports already received. Contact us privately to request deletion. The website policy explains retention, transfers and your rights.

Reporting a problem yourself
Report a Problem sends your description and any optional reply email to OpenCapture through Sentry when you tap Send report. Technical details are included only if you choose them and can be reviewed first. You can choose up to three photos or screenshots and review or remove them before sending. Selected images are resized and re-encoded without original filenames or location metadata. Only share images you have permission to send; no images are attached automatically. This one-off submission does not enable automatic reports. Unsent reports stay privately on this phone, expire after 7 days (removed when the app next runs), wait until you leave camera Wi-Fi, and can be removed before delivery. Do not include passwords or other sensitive information in your message. You can decline the first-launch prompt and enable automatic reports later in System.

What stays on this phone
• Saved cameras, pairing profiles and the reconnect identity. Camera Wi-Fi passwords are sealed with an Android Keystore key on this phone only.
• Operator preferences such as Keep Screen Awake and the selected look.
• Imported .cube files you choose to open.
• Saved feed incident and session reports, until you delete them in System.

What never leaves the phone
• Live view, camera settings and pairing traffic stay on the local link. We do not operate a cloud.

Third parties
• Google may process permission prompts and OS diagnostics under its own policies. Play betas may send crash reports to the developer under Google terms.
• Frame.io is optional. If this build is configured and you sign in, clips you pick upload from this phone to Adobe. The token stays in on-device storage.
• Saving a clip or using the share sheet is something you start. Android or the app you pick then handles that file.
• The source is at github.com/erik-sutton95/OpenZCine.

Android may ask for location so the app can read the camera Wi-Fi name. OpenZCine does not use that permission for maps, ads, or a location history.

The full privacy policy is https://openzcine.app/privacy/
    """.trimIndent()

private val TERMS_BODY =
    """
OpenZCine is free software under the Apache License 2.0. You may use, modify, and share it under that license. The Google Play build is also subject to Google Play's Terms of Service.

This is an unofficial camera monitor and remote control. It is not affiliated with, endorsed by, or supported by Nikon. "Nikon" and "Nikon Z" are trademarks of Nikon Corporation, used only to identify the cameras the app can talk to. RED, Adobe and Frame.io belong to their owners and are named only to identify optional features.

OpenZCine remotely controls physical camera equipment. Wireless links drop, settings writes can be rejected, and the display can lag the camera's real state. Always verify the recording state, exposure and media on the camera itself. Use on productions is at your own risk.

The software is provided on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND. See LICENSE in the repository.

By using the app you agree to follow the Code of Conduct when participating in the project.

The full terms are https://openzcine.app/terms/
    """.trimIndent()

/**
 * Z's legal set (A2-27): privacy and terms are this app's own text, readable on the camera's
 * network and ending with the full web page's address (iOS twin: `MonitorLegalDocuments.z`).
 * Licenses and NOTICE are the repository's LICENSE, THIRD-PARTY-NOTICES.md and NOTICE, staged as
 * resources at build time, with the platform notices; a build missing one shows the unavailable
 * page.
 */
internal val ZLegalDocuments = MonitorLegalDocuments(
    wordmark = "OPENZCINE",
    privacy = MonitorLegalDocument.Text(PRIVACY_BODY),
    terms = MonitorLegalDocument.Text(TERMS_BODY),
    licenses = MonitorLegalDocument.bundledText(listOf(
        MonitorLegalDocument.resource("openzcine/legal/LICENSE"),
        MonitorLegalDocument.resource("openzcine/legal/THIRD-PARTY-NOTICES.md"),
        MonitorPlatformLegalNotices.text,
    )),
    notice = MonitorLegalDocument.bundledText(listOf(MonitorLegalDocument.resource("openzcine/legal/NOTICE"))),
)
