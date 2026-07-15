package com.opencapture.openzcine.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState

/** Entry point for the foreground-only, phone-mediated Wear OS monitor. */
class WearMainActivity : ComponentActivity() {
    private val relayController: WearRelayController by lazy { WearRelayController(applicationContext) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
            LaunchedEffect(lifecycleState) {
                if (lifecycleState.isAtLeast(Lifecycle.State.STARTED)) {
                    relayController.start()
                } else {
                    relayController.stop()
                }
            }
            DisposableEffect(Unit) {
                onDispose { relayController.close() }
            }
            WearMonitorScreen(relayController)
        }
    }

    override fun onDestroy() {
        relayController.close()
        super.onDestroy()
    }
}
