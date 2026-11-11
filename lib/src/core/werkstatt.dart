import 'dart:io';

/// Werkstatt-Modus: nur in Builds aus dem Entwicklungs-Container
/// (`--dart-define=WERKSTATT=true`). Füllt die Einrichtung mit den Daten des
/// Mock-Backends vor und bietet Demo-Daten an. In Release-Builds immer aus.
const bool kWerkstatt = bool.fromEnvironment('WERKSTATT');

/// Zweite Installation, die die andere Person spielt: Android-Build mit
/// `--dart-define=PARTNER=true` bzw. Linux-Vorschau mit WERKSTATT_PARTNER=1.
bool get kPartner =>
    const bool.fromEnvironment('PARTNER') ||
    (!Platform.isAndroid && Platform.environment['WERKSTATT_PARTNER'] == '1');

/// Linux-Vorschau im Container (statt Android-Emulator).
bool get kDesktopPreview => kWerkstatt && Platform.isLinux;

/// Adresse des Containers: aus dem Emulator 10.0.2.2, in der Linux-Vorschau lokal.
String get kWerkstattHost => Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';
String get kWerkstattApiBase => 'http://$kWerkstattHost:8099';
const String kWerkstattOwner = 'sebastian';
const String kWerkstattPassphrase = 'werkstatt-demo';
String get kWerkstattUser => kPartner ? 'Sarah' : 'Sebastian';
String get kWerkstattToken =>
    kPartner ? 'werkstatt-sarah' : 'werkstatt-sebastian';
