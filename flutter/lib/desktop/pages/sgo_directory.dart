import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher_string.dart';
import '../../common.dart';

/// Directorio autorizado por SGO. La credencial temporal vive solo en memoria.
class SgoDirectory extends StatefulWidget {
  const SgoDirectory({super.key});
  @override
  State<SgoDirectory> createState() => _SgoDirectoryState();
}

class _SgoDirectoryState extends State<SgoDirectory> {
  static const origin = 'https://sgo.electroram.cl';
  final code = TextEditingController();
  String? token;
  String? error;
  List<dynamic> equipment = [];
  bool busy = false;
  Timer? timer;

  @override
  void dispose() {
    timer?.cancel();
    code.dispose();
    super.dispose();
  }

  Future<void> authorize() async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      final response = await http.post(Uri.parse('$origin/api/soporte/sesion'),
        headers: {'Accept': 'application/json', 'Content-Type': 'application/json'},
        body: jsonEncode({'codigo': code.text.trim()})).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw Exception('Codigo vencido, utilizado o sin permisos de administrador.');
      token = jsonDecode(response.body)['token'] as String;
      code.clear();
      await refresh();
      timer?.cancel();
      timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    final credential = token;
    if (credential == null) return;
    try {
      final response = await http.get(Uri.parse('$origin/api/soporte/equipos'),
        headers: {'Accept': 'application/json', 'Authorization': 'Bearer $credential'})
        .timeout(const Duration(seconds: 20));
      if (!mounted || token != credential) return;
      if (response.statusCode == 401 || response.statusCode == 403) {
        timer?.cancel();
        setState(() { token = null; equipment = []; error = 'Sesion vencida o permisos revocados. Vincula de nuevo con SGO.'; });
        return;
      }
      if (response.statusCode != 200) throw Exception('No se pudo consultar SGO.');
      final data = jsonDecode(response.body);
      setState(() { equipment = data['equipos'] as List<dynamic>; error = null; });
    } catch (_) {
      if (mounted && token == credential) setState(() => error = 'No se pudo actualizar el estado. Los datos pueden estar desactualizados.');
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Equipos SGO', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      if (error != null) Text(error!, style: const TextStyle(color: Colors.orange)),
      if (token == null) ...[
        const Text('Accede con tu cuenta corporativa @electroram.cl. SGO valida tu identidad, segundo factor y permisos de administrador.'),
        TextButton(onPressed: () => launchUrlString('$origin/soporte/iniciar', mode: LaunchMode.externalApplication), child: const Text('Continuar con SSO corporativo')),
        TextField(controller: code, obscureText: true, decoration: const InputDecoration(labelText: 'Codigo de vinculacion de SGO')),
        FilledButton(onPressed: busy ? null : authorize, child: Text(busy ? 'Verificando...' : 'Vincular')),
      ] else ...[
        Row(children: [
          TextButton(onPressed: refresh, child: const Text('Actualizar lista')),
          TextButton(onPressed: () { timer?.cancel(); setState(() { token = null; equipment = []; error = null; }); }, child: const Text('Cerrar sesion')),
        ]),
        const Text('Contacto reciente indica un latido en los ultimos 5 minutos; no garantiza disponibilidad remota.'),
        Expanded(child: equipment.isEmpty ? const Center(child: Text('Sin equipos enrolados en esta organizacion.')) : ListView.builder(
          itemCount: equipment.length,
          itemBuilder: (context, index) {
            final item = equipment[index];
            final id = item['rustdesk_id']?.toString() ?? '';
            return ListTile(
              leading: Icon(Icons.computer, color: item['contacto_reciente'] == true ? Colors.green : Colors.grey),
              title: Text(item['nombre']?.toString() ?? id),
              subtitle: Text('ID $id · Ultimo contacto: ${item['ultimo_contacto'] ?? 'Sin registro'}'),
              trailing: TextButton(onPressed: id.isEmpty ? null : () => connect(context, id), child: const Text('Conectar')),
            );
          },
        )),
      ],
    ]),
  );
}
