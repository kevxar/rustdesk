import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/sgo_directory.dart';

void main() {
  testWidgets('directorio ofrece SSO corporativo sin pedir la clave de SGO',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SgoDirectory()),
    ));
    expect(find.text('Continuar con SSO corporativo'), findsOneWidget);
    expect(find.textContaining('@electroram.cl'), findsOneWidget);
    expect(find.text('Codigo de vinculacion de SGO'), findsOneWidget);
    expect(find.text('Contraseña'), findsNothing);
    expect(find.text('Nombre de usuario'), findsNothing);
    expect(find.text('Cerrar sesion'), findsNothing);
  });
}
