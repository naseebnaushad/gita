import 'package:flutter/material.dart';

ThemeData buildTheme(Brightness brightness) {
  return ThemeData(
    brightness: brightness,
    colorSchemeSeed: const Color(0xFF3D5AFE),
    useMaterial3: true,
  );
}
