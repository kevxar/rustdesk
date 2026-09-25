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
  static const _taskName = 'SGO-ERAM Agente';
  static const _defaultSgoUrl = 'https://sgo.electroram.cl';
  static const _clientUrl =
      'https://github.com/kevxar/rustdesk/releases/download/nightly/Electroram-Soporte-windows-x86_64.exe';
  static const _clientHashUrl = '$_clientUrl.sha256';

  Timer? _timer;
  Map<String, dynamic>? _state;
  String? _error;
  bool _busy = false;

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
      final state = file.existsSync()
          ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
          : null;
      if (!mounted) return;
      setState(() {
        _state = state;
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
      final responses = await Future.wait([
        http.get(Uri.parse(_clientUrl)).timeout(const Duration(minutes: 5)),
        http
            .get(Uri.parse(_clientHashUrl))
            .timeout(const Duration(seconds: 45)),
      ]);
      if (responses.any((response) => response.statusCode != 200)) {
        throw Exception('No se pudo descargar la actualización corporativa.');
      }
      final expectedHash = utf8
          .decode(responses[1].bodyBytes)
          .trim()
          .split(RegExp(r'\s+'))
          .first;
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedHash)) {
        throw Exception('La versión publicada no tiene una huella válida.');
      }
      await installer.writeAsBytes(responses[0].bodyBytes, flush: true);
      final hashResult = await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        '(Get-FileHash -LiteralPath \$args[0] -Algorithm SHA256).Hash',
        installer.path,
      ]);
      final actualHash = '${hashResult.stdout}'.trim();
      if (hashResult.exitCode != 0 ||
          actualHash.toLowerCase() != expectedHash.toLowerCase()) {
        throw Exception('La descarga no coincide con su SHA-256.');
      }

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
    final installed = _state != null;
    final synchronized = _isSynchronized();
    final agentVersion = _state?['agente_version']?.toString() ?? '—';
    final availableVersion =
        _state?['agente_version_disponible']?.toString() ?? agentVersion;
    final equipmentName = _state?['equipo']?.toString().trim() ?? '';
    final rustdeskId = _state?['rustdesk_id']?.toString().trim() ?? '';
    final targetName = (_state?['hostname_objetivo'] as String?)?.trim();
    final title = !installed
        ? 'Agente SGO no instalado'
        : synchronized
            ? 'Sincronizado con SGO'
            : 'SGO requiere atención';

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 10, 8, 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7FB),
        border: Border.all(color: const Color(0xFF294A93).withOpacity(.35)),
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
                  : const Color(0xFF294A93),
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            'Cliente v${version.isEmpty ? '1.4.9' : version} · '
            'Agente v$agentVersion/$availableVersion',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (installed)
            Text(
              [
                if (equipmentName.isNotEmpty) equipmentName,
                if (rustdeskId.isNotEmpty) 'ID $rustdeskId',
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (installed)
            Text(
              _lastSynchronization(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (targetName != null && targetName.isNotEmpty)
            Text('Nuevo nombre pendiente: $targetName',
                style: Theme.of(context).textTheme.bodySmall),
          if (_error != null)
            Text(_error!, style: TextStyle(color: Colors.red.shade700)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (installed)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _synchronize,
                  icon: const Icon(Icons.sync, size: 16),
                  label: const Text('Sincronizar'),
                ),
              TextButton(
                onPressed: _busy ? null : _showInstaller,
                child: Text(installed ? 'Reparar/actualizar' : 'Instalar agente'),
              ),
              TextButton(
                onPressed: _busy ? null : _updateClient,
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
