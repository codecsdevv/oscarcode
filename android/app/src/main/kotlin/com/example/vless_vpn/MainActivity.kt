package com.example.vless_vpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val requestVpn = 7001
    private var pendingResult: MethodChannel.Result? = null
    private var pendingConfig: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "vpn/control").setMethodCallHandler { call, result ->
            when (call.method) {
                "connect" -> {
                    val config = call.argument<String>("config")
                    if (config.isNullOrBlank()) {
                        result.error("bad_args", "config is required", null)
                        return@setMethodCallHandler
                    }
                    val consent = VpnService.prepare(this)   // null => разрешение уже есть
                    if (consent == null) {
                        startVpn(config)
                        result.success(true)
                    } else {
                        pendingResult = result
                        pendingConfig = config
                        @Suppress("DEPRECATION")
                        startActivityForResult(consent, requestVpn)
                    }
                }
                "disconnect" -> {
                    SingBoxVpnService.instance?.stopBox(null)
                    result.success(true)
                }
                "getStatus" -> result.success(VpnStatusHolder.status)
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "vpn/status").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                VpnStatusHolder.listener = { s, e -> sink.success(mapOf("status" to s, "error" to e)) }
                sink.success(mapOf("status" to VpnStatusHolder.status, "error" to VpnStatusHolder.error))
            }
            override fun onCancel(args: Any?) { VpnStatusHolder.listener = null }
        })
    }

    private fun startVpn(config: String) {
        val intent = Intent(this, SingBoxVpnService::class.java)
            .setAction(SingBoxVpnService.ACTION_START)
            .putExtra(SingBoxVpnService.EXTRA_CONFIG, config)
        ContextCompat.startForegroundService(this, intent)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != requestVpn) return
        val result = pendingResult
        val config = pendingConfig
        pendingResult = null
        pendingConfig = null
        if (resultCode == Activity.RESULT_OK && config != null) {
            startVpn(config)
            result?.success(true)
        } else {
            result?.error("permission_denied", "Пользователь отклонил VPN-разрешение", null)
        }
    }
}
