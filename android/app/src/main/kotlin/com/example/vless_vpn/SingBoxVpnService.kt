package com.example.vless_vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.nekohasekai.libbox.BoxService
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.InetSocketAddress
import java.net.NetworkInterface
import kotlin.concurrent.thread

/** Статус для Flutter (передаётся через EventChannel в MainActivity). */
object VpnStatusHolder {
    @Volatile var status: String = "disconnected"
    @Volatile var error: String? = null
    var listener: ((String, String?) -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())

    fun set(s: String, err: String? = null) {
        status = s
        error = err
        main.post { listener?.invoke(s, err) }
    }
}

/**
 * VpnService + sing-box (libbox).
 * Версия libbox: 1.11.x. Сигнатуры PlatformInterface меняются между версиями —
 * при ошибках компиляции сверяйтесь с sing-box-for-android (app/src/main/java/io/nekohasekai/sfa/bg).
 */
class SingBoxVpnService : VpnService(), PlatformInterface {

    companion object {
        const val ACTION_START = "com.example.vless_vpn.START"
        const val ACTION_STOP = "com.example.vless_vpn.STOP"
        const val EXTRA_CONFIG = "config"
        private const val TAG = "SingBoxVpn"
        private const val CHANNEL_ID = "vpn_status"
        private const val NOTIFICATION_ID = 1

        @Volatile var instance: SingBoxVpnService? = null
    }

    private var box: BoxService? = null
    private var tunPfd: ParcelFileDescriptor? = null
    private var netCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var stopping = false

    // ───────────────────────── Жизненный цикл ─────────────────────────

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG)
                if (config.isNullOrBlank()) {
                    VpnStatusHolder.set("error", "empty config")
                    stopSelf()
                } else {
                    startBox(config)
                }
            }
            ACTION_STOP -> stopBox(null)
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        // Пользователь отключил VPN из системной шторки/настроек
        stopBox(null)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    // ───────────────────────── Запуск / остановка ─────────────────────────

    private fun startBox(config: String) {
        if (box != null) return
        stopping = false
        VpnStatusHolder.set("connecting")
        startForegroundCompat()

        thread(name = "singbox-start") {
            try {
                val base = filesDir.absolutePath
                Libbox.setup(SetupOptions().also {
                    it.basePath = base
                    it.workingPath = base
                    it.tempPath = cacheDir.absolutePath
                })
                Libbox.checkConfig(config)                 // бросит исключение при кривом JSON
                val service = Libbox.newService(config, this)
                service.start()                            // внутри вызовет openTun()
                box = service
                VpnStatusHolder.set("connected")
            } catch (e: Throwable) {
                Log.e(TAG, "start failed", e)
                stopBox(e.message ?: e.javaClass.simpleName)
            }
        }
    }

    @Synchronized
    fun stopBox(error: String?) {
        if (stopping) return
        stopping = true
        VpnStatusHolder.set("disconnecting")
        thread(name = "singbox-stop") {
            try { box?.close() } catch (e: Throwable) { Log.w(TAG, "close", e) }
            box = null
            try { tunPfd?.close() } catch (_: Throwable) {}
            tunPfd = null
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            if (error != null) VpnStatusHolder.set("error", error)
            VpnStatusHolder.set("disconnected", error)
        }
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "VPN", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val openApp = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, SingBoxVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("VPN активен")
            .setContentText("Трафик идёт через защищённый туннель")
            .setSmallIcon(android.R.drawable.ic_lock_lock)   // замените на свою иконку
            .setContentIntent(openApp)
            .addAction(0, "Отключить", stopIntent)
            .setOngoing(true)
            .build()

        val type = if (Build.VERSION.SDK_INT >= 34)
            android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
    }

    // ───────────────────────── PlatformInterface ─────────────────────────

    /** Создаёт TUN через VpnService.Builder по параметрам, которые просит sing-box. */
    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val b = Builder()
            .setSession("VLESS VPN")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) b.setMetered(false)

        val v4 = options.inet4Address
        while (v4.hasNext()) { val a = v4.next(); b.addAddress(a.address(), a.prefix()) }

        var hasV6 = false
        val v6 = options.inet6Address
        while (v6.hasNext()) { val a = v6.next(); b.addAddress(a.address(), a.prefix()); hasV6 = true }

        if (options.autoRoute) {
            // DNS внутри туннеля -> защита от DNS leak
            b.addDnsServer(options.dnsServerAddress.value)

            val r4 = options.inet4RouteAddress
            if (r4.hasNext()) {
                while (r4.hasNext()) { val a = r4.next(); b.addRoute(a.address(), a.prefix()) }
            } else {
                b.addRoute("0.0.0.0", 0)
            }

            val r6 = options.inet6RouteAddress
            if (r6.hasNext()) {
                while (r6.hasNext()) { val a = r6.next(); b.addRoute(a.address(), a.prefix()) }
            } else if (hasV6) {
                b.addRoute("::", 0)
            }

            // Split tunneling по приложениям (include_package / exclude_package в конфиге)
            val inc = options.includePackage
            while (inc.hasNext()) {
                try { b.addAllowedApplication(inc.next()) } catch (_: PackageManager.NameNotFoundException) {}
            }
            val exc = options.excludePackage
            while (exc.hasNext()) {
                try { b.addDisallowedApplication(exc.next()) } catch (_: PackageManager.NameNotFoundException) {}
            }
        }

        val pfd = b.establish() ?: error("android: VpnService.Builder.establish() вернул null")
        tunPfd = pfd
        return pfd.fd
    }

    /** Сокеты sing-box к удалённому серверу должны обходить туннель. */
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun autoDetectInterfaceControl(fd: Int) { protect(fd) }

    override fun usePlatformDefaultInterfaceMonitor(): Boolean = true

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val cm = getSystemService(ConnectivityManager::class.java)

        fun push(network: Network?) {
            if (network == null) {
                listener.updateDefaultInterface("", -1, false, false)
                return
            }
            val name = cm.getLinkProperties(network)?.interfaceName ?: return
            val index = try { NetworkInterface.getByName(name)?.index } catch (_: Throwable) { null } ?: return
            val caps = cm.getNetworkCapabilities(network)
            val expensive = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
            listener.updateDefaultInterface(name, index, expensive, false)
        }

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = push(network)
            override fun onLost(network: Network) = push(null)
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = push(network)
        }
        netCallback = cb

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        val handler = Handler(Looper.getMainLooper())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            cm.registerBestMatchingNetworkCallback(request, cb, handler)
        } else {
            cm.requestNetwork(request, cb, handler)
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val cb = netCallback ?: return
        try { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(cb) } catch (_: Throwable) {}
        netCallback = null
    }

    override fun usePlatformInterfaceGetter(): Boolean = false
    override fun getInterfaces() = error("not used: usePlatformInterfaceGetter=false")

    // — определение приложения-владельца соединения (для правил по package_name) —
    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int, sourceAddress: String, sourcePort: Int,
        destinationAddress: String, destinationPort: Int
    ): Int {
        val cm = getSystemService(ConnectivityManager::class.java)
        val uid = cm.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort)
        )
        if (uid == -1) error("android: connection owner not found")
        return uid
    }

    override fun packageNameByUid(uid: Int): String =
        packageManager.getPackagesForUid(uid)?.firstOrNull() ?: error("android: package not found")

    @Suppress("DEPRECATION")
    override fun uidByPackageName(packageName: String): Int =
        try { packageManager.getPackageUid(packageName, 0) }
        catch (_: PackageManager.NameNotFoundException) { error("android: package not found") }

    // — прочее —
    override fun writeLog(message: String) { Log.d(TAG, message) }
    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun readWIFIState(): WIFIState? = null
    override fun clearDNSCache() {}
    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {}
}
