import 'package:flutter/material.dart';

/// Kalenderfarben (kräftig genug für weiße Schrift).
const List<int> kCalendarColors = [
  0xFFE05A5A, // Rot
  0xFFF08C3A, // Orange
  0xFFD4A21E, // Senf
  0xFF5BAA5E, // Grün
  0xFF2E9C8E, // Petrol
  0xFF2A9FD6, // Himmelblau
  0xFF4A74D9, // Blau
  0xFF6A5ACD, // Indigo
  0xFF9B59B6, // Lila
  0xFFE0609A, // Pink
  0xFF8D6E63, // Braun
  0xFF78909C, // Grau
];

const List<int> kThemeColors = [
  0xFF3F7F6E, // Salbei-Petrol (Standard)
  0xFF4A74D9,
  0xFF6A5ACD,
  0xFFE0609A,
  0xFFE05A5A,
  0xFFF08C3A,
  0xFF5BAA5E,
  0xFF5D6D7E,
];

const kSundayColor = Color(0xFFD9534F);
const kSaturdayColor = Color(0xFF3F7FBF);

ThemeData buildTheme(int seed, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
      seedColor: Color(seed), brightness: brightness);
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
  );
  return base.copyWith(
    scaffoldBackgroundColor:
        brightness == Brightness.light ? const Color(0xFFFCFBF8) : null,
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor:
          brightness == Brightness.light ? const Color(0xFFFCFBF8) : null,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge
          ?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
  );
}

/// Lesbare Textfarbe auf farbigem Grund.
Color onColor(Color c) =>
    c.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;
