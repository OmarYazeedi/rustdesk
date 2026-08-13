package com.carriez.flutter_hbb

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import java.net.URL
import kotlin.concurrent.thread

/**
 * Downloads an update and hands it to the system package installer.
 *
 * Without this the update banner can only open a browser and hope the user
 * finds the download and taps it. The apk still installs through Android's own
 * installer with its usual confirmation -- nothing here installs anything
 * silently, and it could not: REQUEST_INSTALL_PACKAGES only makes the request
 * possible, and the user grants "install unknown apps" per app.
 */
object ApkInstaller {
    private const val TAG = "mApkInstaller"
    private const val AUTHORITY = "com.ihportals.app.fileprovider"

    /**
     * Fetch [url] and offer it for install. Reports progress and failure through
     * [onResult] so the UI can say what happened rather than appearing to do
     * nothing -- a download that fails silently is the worst outcome here.
     */
    fun installFromUrl(activity: Activity, url: String, onResult: (String) -> Unit) {
        // API 26+ gates installs behind a per-app setting. Send the user there
        // rather than downloading first and failing at the last step.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            try {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${activity.packageName}")
                    )
                )
                onResult("permission")
            } catch (e: Exception) {
                Log.e(TAG, "cannot open unknown-sources settings", e)
                onResult("error:${e.message}")
            }
            return
        }

        thread {
            try {
                val dir = File(activity.cacheDir, "updates").apply { mkdirs() }
                // One fixed name: updates supersede each other, and keeping the
                // old ones would quietly grow the cache with 26MB files.
                val apk = File(dir, "update.apk")
                if (apk.exists()) apk.delete()

                URL(url).openStream().use { input ->
                    apk.outputStream().use { output -> input.copyTo(output) }
                }
                // A truncated download installs as a corrupt package with a
                // confusing error, so treat a suspiciously small file as failed.
                if (apk.length() < 1_000_000) {
                    onResult("error:download incomplete (${apk.length()} bytes)")
                    return@thread
                }
                activity.runOnUiThread { launchInstaller(activity, apk, onResult) }
            } catch (e: Exception) {
                Log.e(TAG, "download failed", e)
                onResult("error:${e.message}")
            }
        }
    }

    private fun launchInstaller(context: Context, apk: File, onResult: (String) -> Unit) {
        try {
            val uri: Uri = FileProvider.getUriForFile(context, AUTHORITY, apk)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                // The installer is a separate app, so it needs read access to a
                // uri it did not create.
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            onResult("ok")
        } catch (e: Exception) {
            Log.e(TAG, "installer intent failed", e)
            onResult("error:${e.message}")
        }
    }
}
