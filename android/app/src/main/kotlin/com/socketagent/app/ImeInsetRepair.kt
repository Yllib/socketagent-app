package com.socketagent.app

import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsAnimation

/**
 * Works around flutter/flutter#191156: after leaving the app while the
 * keyboard is still animating, the engine can keep the keyboard's height as
 * the bottom inset with no keyboard on screen, so every screen sits above an
 * empty gap until the app is relaunched.
 *
 * The engine's ImeSyncDeferringInsetsCallback caches the insets when an IME
 * animation starts and re-applies that cache when it ends. Leave mid-animation
 * and the cache holds a keyboard-visible snapshot; on return Android cancels
 * the hide animation, the engine re-applies the stale snapshot, and Android
 * sends nothing newer. Resume-time refreshes run before that re-apply, which is
 * why they never held.
 *
 * This watches IME animations from the FlutterView's parent, which hears onEnd
 * before the engine does, and posts a fresh inset dispatch to run after it.
 * The dispatch takes the normal path, so the DecorView still consumes the
 * navigation bar below API 35. When the engine was right the same metrics
 * arrive again and nothing rebuilds.
 *
 * Adapted from Adiel-Sharabi/web-terminal#401. Delete once the engine fix
 * ships in the Flutter release this app builds with.
 */
internal class ImeInsetRepair private constructor(private val flutterView: View) :
    WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {

    override fun onProgress(
        insets: WindowInsets,
        runningAnimations: MutableList<WindowInsetsAnimation>,
    ): WindowInsets = insets

    override fun onEnd(animation: WindowInsetsAnimation) {
        if (animation.typeMask and WindowInsets.Type.ime() == 0) return
        flutterView.post { flutterView.requestApplyInsets() }
    }

    companion object {
        /** The engine's deferring callback exists only from API 30. */
        fun install(flutterView: View) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
            val parent = flutterView.parent as? View ?: return
            parent.setWindowInsetsAnimationCallback(ImeInsetRepair(flutterView))
        }
    }
}
