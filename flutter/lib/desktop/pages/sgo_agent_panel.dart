import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../common.dart';

/// Estado y mantenimiento del agente que vincula el equipo con SGO.
///
/// El cliente nunca almacena la credencial permanente del agente. Para una
/// instalación o reparación recibe un código de un solo uso emitido por SGO,
/// descarga el instalador correspondiente y delega su ejecución a Windows con
/// elevación. El estado cotidiano se lee desde el archivo sin secretos que
/// publica el agente SYSTEM.
class SgoAgentPanel extends StatefulWidget {
  const SgoAgentPanel({super.key});

  @override
  State<SgoAgentPanel> createState() => _SgoAgentPanelState();
}

class _SgoAgentPanelState extends State<SgoAgentPanel> {
  static const _statePath = r'C:\ProgramData\SGO-ERAM\estado.json';
  static const _agentPath = r'C:\Program Files\SGO-ERAM\agente.ps1';
  static const _taskName = 'SGO-ERAM Agente';
  static const _defaultSgoUrl = 'https://sgo.electroram.cl';
  static const _clientUrl =
      'https://github.com/kevxar/rustdesk/releases/download/nightly/Electroram-Soporte-windows-x86_64.exe';
  static const _clientHashUrl = '$_clientUrl.sha256';

  Timer? _timer;
  Map<String, dynamic>? _state;
  String? _error;
  bool _busy = false;
  bool _agentTaskInstalled = false;
  bool _agentTaskNeedsRepair = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final file = File(_statePath);
      final results = await Future.wait<dynamic>([
        if (file.existsSync()) file.readAsString() else Future.value(null),
        Process.run(
          'schtasks.exe',
          const ['/Query', '/TN', _taskName],
          runInShell: false,
        ),
      ]);
      final state = results[0] is String
          ? jsonDecode(results[0] as String) as Map<String, dynamic>
          : null;
      final taskResult = results[1] as ProcessResult;
      final taskOutput = '${taskResult.stdout}\n${taskResult.stderr}'.toLowerCase();
      final taskAccessDenied = taskResult.exitCode != 0 &&
          (taskOutput.contains('access is denied') ||
              taskOutput.contains('acceso denegado'));
      final legacyAgentPresent = state != null && File(_agentPath).existsSync();
      if (!mounted) return;
      setState(() {
        _state = state;
        _agentTaskInstalled =
            taskResult.exitCode == 0 || (taskAccessDenied && legacyAgentPresent);
        _agentTaskNeedsRepair = taskAccessDenied && legacyAgentPresent;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'No se pudo leer el estado del agente.');
    }
  }

  Future<void> _synchronize() async {
    setState(() => _busy = true);
    try {
      final result = await Process.run(
        'schtasks.exe',
        const ['/Run', '/TN', _taskName],
        runInShell: false,
      );
      if (result.exitCode != 0) {
        throw Exception('Windows no pudo iniciar la tarea del agente.');
      }
      _message('Sincronización solicitada.');
      await Future<void>.delayed(const Duration(seconds: 2));
      await _refresh();
    } catch (error) {
      _message('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showInstaller() async {
    final urlController = TextEditingController(
      text: (_state?['sgo_url'] as String?) ?? _defaultSgoUrl,
    );
    final tokenController = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Instalar o reparar agente SGO'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Obtén una autorización de recuperación en TI → Equipos y pégala aquí. '
                'El código sirve para un solo equipo y caduca en una hora.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'Dirección de SGO',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tokenController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Código de enrolamiento',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
    if (accepted != true) return;

    await _installAgent(urlController.text.trim(), tokenController.text.trim());
  }

  Future<void> _updateClient() async {
    setState(() => _busy = true);
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final installer = File(
        '${Directory.systemTemp.path}\\Electroram-Soporte-$stamp.exe',
      );
      await _downloadVerifiedClient(installer);

      final escapedPath = installer.path.replaceAll("'", "''");
      final command =
          "Start-Process -FilePath '$escapedPath' -ArgumentList '--silent-install' -Verb RunAs";
      final encoded = _encodePowerShell(command);
      final process = await Process.start(
        'powershell.exe',
        ['-NoProfile', '-EncodedCommand', encoded],
        runInShell: false,
      );
      if (await process.exitCode != 0) {
        throw Exception('Windows rechazó la actualización.');
      }
      _message('Actualización iniciada. Acepta el aviso de Windows.');
    } catch (error) {
      _message('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Descarga primero la huella y luego el binario para evitar mezclar dos
  /// versiones mientras GitHub reemplaza el alias estable de la release.
  /// Cada intento usa una clave de caché propia porque ambos recursos pueden
  /// propagarse por nodos CDN distintos durante algunos segundos.
  Future<void> _downloadVerifiedClient(File installer) async {
    const attempts = 3;
    final client = http.Client();
    try {
      for (var attempt = 1; attempt <= attempts; attempt++) {
        final cacheKey = DateTime.now().microsecondsSinceEpoch.toString();
        const headers = {
          'Cache-Control': 'no-cache, no-store',
          'Pragma': 'no-cache',
        };
        final hashUri = Uri.parse(_clientHashUrl).replace(
          queryParameters: {'electroram_cache': cacheKey},
        );
        final clientUri = Uri.parse(_clientUrl).replace(
          queryParameters: {'electroram_cache': cacheKey},
        );
        final hashResponse = await client
            .get(hashUri, headers: headers)
            .timeout(const Duration(seconds: 45));
        if (hashResponse.statusCode != 200) {
          throw Exception('No se pudo descargar la huella corporativa.');
        }
        final expectedHash = utf8
            .decode(hashResponse.bodyBytes)
            .trim()
            .split(RegExp(r'\s+'))
            .first;
        if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedHash)) {
          throw Exception('La versión publicada no tiene una huella válida.');
        }

        final clientResponse = await client
            .get(clientUri, headers: headers)
            .timeout(const Duration(minutes: 5));
        if (clientResponse.statusCode != 200) {
          throw Exception('No se pudo descargar la actualización corporativa.');
        }
        await installer.writeAsBytes(clientResponse.bodyBytes, flush: true);
        final hashResult = await Process.run('powershell.exe', [
          '-NoProfile',
          '-Command',
          '(Get-FileHash -LiteralPath \$args[0] -Algorithm SHA256).Hash',
          installer.path,
        ]);
        final actualHash = '${hashResult.stdout}'.trim();
        if (hashResult.exitCode == 0 &&
            actualHash.toLowerCase() == expectedHash.toLowerCase()) {
          return;
        }
        try {
          await installer.delete();
        } catch (_) {
          // El siguiente intento sobrescribe el archivo si Windows lo retuvo.
        }
        if (attempt < attempts) {
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
    } finally {
      client.close();
    }
    throw Exception(
      'GitHub aún está propagando la nueva versión. Intenta nuevamente en un minuto.',
    );
  }

  Future<void> _installAgent(String baseUrl, String token) async {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      _message('SGO debe usar una dirección HTTPS válida.', error: true);
      return;
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      _message('El código de enrolamiento no es válido.', error: true);
      return;
    }

    setState(() => _busy = true);
    try {
      final endpoint = uri.replace(
        path: '/api/ti/equipos/instalador',
        query: null,
        fragment: null,
      );
      final response = await http
          .get(endpoint, headers: {'X-Enrollment-Token': token})
          .timeout(const Duration(seconds: 45));
      if (response.statusCode != 200) {
        throw Exception('SGO rechazó o expiró la autorización.');
      }

      final script = File(
        '${Directory.systemTemp.path}\\electroram-sgo-${DateTime.now().millisecondsSinceEpoch}.ps1',
      );
      await script.writeAsBytes(response.bodyBytes, flush: true);

      // La ruta se codifica como UTF-16LE para no interpolar datos del usuario
      // dentro de una línea de comandos de PowerShell.
      final escapedPath = script.path.replaceAll("'", "''");
      final command =
          "Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','RemoteSigned','-File','$escapedPath')";
      final encoded = _encodePowerShell(command);
      final process = await Process.start(
        'powershell.exe',
        ['-NoProfile', '-EncodedCommand', encoded],
        runInShell: false,
      );
      final exitCode = await process.exitCode;
      if (exitCode != 0) {
        throw Exception(
          'La elevación fue cancelada o Windows rechazó la instalación.',
        );
      }
      _message('Instalación iniciada. Acepta el aviso de Windows.');
    } catch (error) {
      _message('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red.shade700 : const Color(0xFF294A93),
    ));
  }

  String _encodePowerShell(String command) {
    final utf16le = command.codeUnits
        .expand((unit) => [unit & 0xff, (unit >> 8) & 0xff])
        .toList(growable: false);
    return base64Encode(utf16le);
  }

  bool _isSynchronized() {
    if (!_agentTaskInstalled) return false;
    if (_state?['latido_ok'] != true) return false;
    final lastHeartbeat = DateTime.tryParse(
      _state?['ultimo_latido_en']?.toString() ?? '',
    );
    if (lastHeartbeat == null) return false;
    final configuredInterval = int.tryParse(
          _state?['intervalo_minutos']?.toString() ?? '',
        ) ??
        60;
    final tolerance = Duration(
      minutes: configuredInterval.clamp(5, 1440).toInt() * 3 + 5,
    );
    return DateTime.now().difference(lastHeartbeat.toLocal()) <= tolerance;
  }

  String _lastSynchronization() {
    final lastHeartbeat = DateTime.tryParse(
      _state?['ultimo_latido_en']?.toString() ?? '',
    );
    if (lastHeartbeat == null) return 'Sin sincronización registrada';
    final local = lastHeartbeat.toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return 'Última sincronización: '
        '${twoDigits(local.day)}/${twoDigits(local.month)}/${local.year} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final hasState = _state != null;
    final installed = _agentTaskInstalled;
    final synchronized = _isSynchronized();
    final agentVersion = _state?['agente_version']?.toString() ?? '—';
    final availableVersion =
        _state?['agente_version_disponible']?.toString() ?? agentVersion;
    final equipmentName = _state?['equipo']?.toString().trim() ?? '';
    final rustdeskId = _state?['rustdesk_id']?.toString().trim() ?? '';
    final targetName = (_state?['hostname_objetivo'] as String?)?.trim();
    final title = !installed
        ? 'Agente SGO no instalado'
        : _agentTaskNeedsRepair
            ? 'Agente SGO requiere reparación'
        : synchronized
            ? 'Sincronizado con SGO'
            : 'SGO requiere atención';

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 10, 8, 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF162032),
        border: Border.all(color: const Color(0xFF4B77BE).withOpacity(.65)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(
              installed && synchronized
                  ? Icons.cloud_done
                  : Icons.settings_remote,
              color: installed && synchronized
                  ? Colors.green.shade700
                  : const Color(0xFF7DB7FF),
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  )),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            'Cliente v${version.isEmpty ? '1.4.9' : version} · '
            'Agente v$agentVersion/$availableVersion',
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
          ),
          if (hasState)
            Text(
              [
                if (equipmentName.isNotEmpty) equipmentName,
                if (rustdeskId.isNotEmpty) 'ID $rustdeskId',
              ].join(' · '),
              style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
            ),
          if (hasState)
            Text(
              _lastSynchronization(),
              style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
            ),
          if (_agentTaskNeedsRepair)
            const Text(
              'La instalación anterior no permite consultar ni ejecutar la tarea. Usa Reparar/actualizar para renovar sus permisos.',
              style: TextStyle(color: Color(0xFFFFC66D), fontSize: 12),
            )
          else if (hasState && !installed)
            const Text(
              'Se encontró un estado anterior, pero la tarea del agente no está registrada.',
              style: TextStyle(color: Color(0xFFFFC66D), fontSize: 12),
            ),
          if (targetName != null && targetName.isNotEmpty)
            Text('Nuevo nombre pendiente: $targetName',
                style: const TextStyle(
                  color: Color(0xFFFFC66D),
                  fontSize: 12,
                )),
          if (_error != null)
            Text(_error!, style: TextStyle(color: Colors.red.shade700)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (installed && !_agentTaskNeedsRepair)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _synchronize,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFB7D7FF),
                    side: const BorderSide(color: Color(0xFF4B77BE)),
                  ),
                  icon: const Icon(Icons.sync, size: 16),
                  label: const Text('Sincronizar'),
                ),
              TextButton(
                onPressed: _busy ? null : _showInstaller,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF7DB7FF),
                ),
                child: Text(installed ? 'Reparar/actualizar' : 'Instalar agente'),
              ),
              TextButton(
                onPressed: _busy ? null : _updateClient,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF7DB7FF),
                ),
                child: const Text('Actualizar cliente'),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
