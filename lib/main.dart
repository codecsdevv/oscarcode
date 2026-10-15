import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ctl = MethodChannel('vpn/control');
const _evt = EventChannel('vpn/status');

Color _a(Color c, double o) => c.withAlpha((o.clamp(0.0, 1.0) * 255).round());

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const AegisApp());
}

class AegisApp extends StatelessWidget {
  const AegisApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Aegis',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF22C55E),
          scaffoldBackgroundColor: const Color(0xFF0B1220),
        ),
        home: const HomeScreen(),
      );
}

// ───────────────────────── Модель сервера + парсер vless:// ─────────────────────────

class VlessServer {
  final String name, uuid, host, security, sni, fp, pbk, sid, flow, type, path, hostHeader, serviceName;
  final int port;

  const VlessServer({
    required this.name,
    required this.uuid,
    required this.host,
    required this.port,
    required this.security,
    required this.sni,
    required this.fp,
    required this.pbk,
    required this.sid,
    required this.flow,
    required this.type,
    required this.path,
    required this.hostHeader,
    required this.serviceName,
  });

  static VlessServer? parse(String raw) {
    final text = raw.trim();
    if (!text.startsWith('vless://')) return null;
    Uri uri;
    try {
      uri = Uri.parse(text);
    } catch (_) {
      return null;
    }
    if (uri.host.isEmpty || uri.userInfo.isEmpty || uri.port == 0) return null;
    final q = uri.queryParameters;
    var name = uri.fragment;
    try {
      name = Uri.decodeComponent(uri.fragment);
    } catch (_) {}
    return VlessServer(
      name: name.isEmpty ? uri.host : name,
      uuid: uri.userInfo,
      host: uri.host,
      port: uri.port,
      security: q['security'] ?? 'none',
      sni: q['sni'] ?? '',
      fp: q['fp'] ?? 'chrome',
      pbk: q['pbk'] ?? '',
      sid: q['sid'] ?? '',
      flow: q['flow'] ?? '',
      type: q['type'] ?? 'tcp',
      path: q['path'] ?? '/',
      hostHeader: q['host'] ?? '',
      serviceName: q['serviceName'] ?? '',
    );
  }

  String get protocolLabel {
    final sec = security == 'none' ? '' : ' · ${security.toUpperCase()}';
    return 'VLESS$sec';
  }

  /// Конфиг sing-box 1.11
  Map<String, dynamic> toSingBoxConfig() {
    final outbound = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': host,
      'server_port': port,
      'uuid': uuid,
      'packet_encoding': 'xudp',
    };
    if (flow.isNotEmpty) outbound['flow'] = flow;

    if (security == 'reality' || security == 'tls') {
      final tls = <String, dynamic>{
        'enabled': true,
        'server_name': sni.isNotEmpty ? sni : host,
        'utls': {'enabled': true, 'fingerprint': fp.isEmpty ? 'chrome' : fp},
      };
      if (security == 'reality') {
        tls['reality'] = {'enabled': true, 'public_key': pbk, 'short_id': sid};
      }
      outbound['tls'] = tls;
    }

    if (type == 'ws') {
      outbound['transport'] = {
        'type': 'ws',
        'path': path,
        'headers': {'Host': hostHeader.isNotEmpty ? hostHeader : (sni.isNotEmpty ? sni : host)},
      };
    } else if (type == 'grpc') {
      outbound['transport'] = {'type': 'grpc', 'service_name': serviceName};
    }

    return {
      'log': {'level': 'warn'},
      'dns': {
        'servers': [
          {'tag': 'remote', 'address': 'https://1.1.1.1/dns-query', 'detour': 'proxy'},
          {'tag': 'bootstrap', 'address': 'https://1.1.1.1/dns-query'},
        ],
        'rules': [
          {'domain': [host], 'server': 'bootstrap'},
        ],
        'final': 'remote',
        'strategy': 'ipv4_only',
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': ['172.19.0.1/30'],
          'mtu': 9000,
          'auto_route': true,
          'strict_route': true,
          'stack': 'mixed',
        },
      ],
      'outbounds': [
        outbound,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'auto_detect_interface': true,
        'final': 'proxy',
        'rules': [
          {'action': 'sniff'},
          {'protocol': 'dns', 'action': 'hijack-dns'},
        ],
      },
    };
  }
}

// ───────────────────────── Главный экран ─────────────────────────

enum VpnState { disconnected, connecting, connected, disconnecting, error }

VpnState _parseState(String? s) {
  switch (s) {
    case 'connecting':
      return VpnState.connecting;
    case 'connected':
      return VpnState.connected;
    case 'disconnecting':
      return VpnState.disconnecting;
    case 'error':
      return VpnState.error;
    default:
      return VpnState.disconnected;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  StreamSubscription? _sub;
  Timer? _ticker;
  DateTime? _since;

  VpnState _state = VpnState.disconnected;
  String? _error;
  String _link = '';
  VlessServer? _server;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
    _loadLink();
    _sub = _evt.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _loadLink() async {
    final prefs = await SharedPreferences.getInstance();
    final link = prefs.getString('vless_link') ?? '';
    if (!mounted) return;
    setState(() {
      _link = link;
      _server = VlessServer.parse(link);
    });
  }

  Future<void> _saveLink(String link) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vless_link', link);
    if (!mounted) return;
    setState(() {
      _link = link;
      _server = VlessServer.parse(link);
    });
  }

  void _onEvent(dynamic e) {
    final m = Map<String, dynamic>.from(e as Map);
    final s = _parseState(m['status'] as String?);
    final err = m['error'] as String?;
    if (!mounted) return;
    setState(() {
      _state = s;
      if (s == VpnState.connecting) {
        _error = null;
      } else if (err != null) {
        _error = err;
      }
    });
    if (s == VpnState.connected) {
      _since ??= DateTime.now();
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (_since != null && mounted) {
          setState(() => _elapsed = DateTime.now().difference(_since!));
        }
      });
    } else if (s != VpnState.connecting) {
      _ticker?.cancel();
      _ticker = null;
      _since = null;
      if (mounted) setState(() => _elapsed = Duration.zero);
    }
  }

  Future<void> _toggle() async {
    if (_state == VpnState.connected || _state == VpnState.connecting) {
      await _ctl.invokeMethod('disconnect');
      return;
    }
    if (_state == VpnState.disconnecting) return;
    final s = _server;
    if (s == null) {
      _editLink();
      return;
    }
    setState(() {
      _error = null;
      _state = VpnState.connecting;
    });
    try {
      await _ctl.invokeMethod('connect', {'config': jsonEncode(s.toSingBoxConfig())});
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = VpnState.disconnected;
        _error = e.message ?? e.code;
      });
    }
  }

  Future<void> _editLink() async {
    final ctrl = TextEditingController(text: _link);
    String? err;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111B2E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Сервер', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Вставьте ссылку vless://', style: TextStyle(color: _a(Colors.white, 0.6))),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                minLines: 3,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: 'vless://uuid@host:443?...',
                  filled: true,
                  fillColor: _a(Colors.white, 0.06),
                  errorText: err,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final d = await Clipboard.getData('text/plain');
                        if (d?.text != null) ctrl.text = d!.text!;
                      },
                      icon: const Icon(Icons.content_paste_rounded),
                      label: const Text('Вставить'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        if (VlessServer.parse(ctrl.text) == null) {
                          setSheet(() => err = 'Неверная ссылка vless://');
                          return;
                        }
                        _saveLink(ctrl.text.trim());
                        Navigator.pop(ctx);
                      },
                      child: const Text('Сохранить'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────── UI ─────────

  Color get _color {
    switch (_state) {
      case VpnState.connected:
        return const Color(0xFF22C55E);
      case VpnState.connecting:
      case VpnState.disconnecting:
        return const Color(0xFFF5A524);
      case VpnState.error:
        return const Color(0xFFEF4444);
      case VpnState.disconnected:
        return const Color(0xFF3A4660);
    }
  }

  String get _title {
    switch (_state) {
      case VpnState.connected:
        return 'Защищено';
      case VpnState.connecting:
        return 'Подключение…';
      case VpnState.disconnecting:
        return 'Отключение…';
      case VpnState.error:
        return 'Ошибка';
      case VpnState.disconnected:
        return 'Не подключено';
    }
  }

  String _fmt(Duration d) {
    String t(int n) => n.toString().padLeft(2, '0');
    return '${t(d.inHours)}:${t(d.inMinutes % 60)}:${t(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final active = _state == VpnState.connected || _state == VpnState.connecting;
    final color = _color;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0B1220), Color(0xFF121D33)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.shield_rounded, color: _a(color, 1), size: 28),
                    const SizedBox(width: 10),
                    const Text('Aegis',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                  ],
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _toggle,
                  child: SizedBox(
                    width: 280,
                    height: 280,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (active)
                          AnimatedBuilder(
                            animation: _pulse,
                            builder: (_, __) {
                              final t = _pulse.value;
                              return Transform.scale(
                                scale: 1 + 0.4 * t,
                                child: Container(
                                  width: 210,
                                  height: 210,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _a(color, 0.28 * (1 - t)),
                                  ),
                                ),
                              );
                            },
                          ),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          width: 210,
                          height: 210,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(colors: [_a(color, 1), _a(color, 0.65)]),
                            boxShadow: [
                              BoxShadow(
                                color: _a(color, 0.5),
                                blurRadius: active ? 48 : 16,
                                spreadRadius: active ? 6 : 0,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.power_settings_new_rounded, size: 92, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(_title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  _error != null
                      ? _error!
                      : (_state == VpnState.disconnected ? 'Нажмите, чтобы подключиться' : ' '),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _a(_error != null ? const Color(0xFFEF4444) : Colors.white, 0.7)),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(child: _InfoCard(label: 'Время сессии', value: _fmt(_elapsed), icon: Icons.timer_outlined)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _InfoCard(
                        label: 'Протокол',
                        value: _server?.protocolLabel ?? '—',
                        icon: Icons.lock_outline_rounded,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: _editLink,
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _a(Colors.white, 0.06),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: _a(color, 0.2), shape: BoxShape.circle),
                          child: Icon(Icons.public_rounded, color: _a(color, 1)),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _server?.name ?? 'Добавить сервер',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _server != null ? '${_server!.host}:${_server!.port}' : 'Вставьте ссылку vless://',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: _a(Colors.white, 0.6), fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: _a(Colors.white, 0.5)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String label, value;
  final IconData icon;

  const _InfoCard({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _a(Colors.white, 0.06),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: _a(Colors.white, 0.6)),
                const SizedBox(width: 6),
                Text(label, style: TextStyle(color: _a(Colors.white, 0.6), fontSize: 12)),
              ],
            ),
            const SizedBox(height: 8),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}
