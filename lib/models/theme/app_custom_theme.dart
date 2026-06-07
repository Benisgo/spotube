import 'dart:convert';

import 'package:flutter/material.dart';

class AppCustomTheme {
  final bool enabled;
  final double surfaceOpacity;
  final double surfaceBlur;
  final bool useNowPlayingCoverBackground;
  final double backgroundImageOpacity;
  final double backgroundImageBlur;
  final Color accentColor;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color cardColor;
  final Color cardForegroundColor;
  final Color secondaryColor;
  final Color mutedColor;
  final Color mutedForegroundColor;
  final Color borderColor;

  const AppCustomTheme({
    required this.enabled,
    required this.surfaceOpacity,
    required this.surfaceBlur,
    required this.useNowPlayingCoverBackground,
    required this.backgroundImageOpacity,
    required this.backgroundImageBlur,
    required this.accentColor,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.cardColor,
    required this.cardForegroundColor,
    required this.secondaryColor,
    required this.mutedColor,
    required this.mutedForegroundColor,
    required this.borderColor,
  });

  factory AppCustomTheme.defaults() {
    return const AppCustomTheme(
      enabled: false,
      surfaceOpacity: 0.8,
      surfaceBlur: 10,
      useNowPlayingCoverBackground: false,
      backgroundImageOpacity: 0.22,
      backgroundImageBlur: 26,
      accentColor: Color(0xff64748b),
      backgroundColor: Color(0xff09090b),
      foregroundColor: Color(0xfffafafa),
      cardColor: Color(0xff18181b),
      cardForegroundColor: Color(0xfffafafa),
      secondaryColor: Color(0xff27272a),
      mutedColor: Color(0xff18181b),
      mutedForegroundColor: Color(0xffa1a1aa),
      borderColor: Color(0xff27272a),
    );
  }

  factory AppCustomTheme.fromJsonString(String raw) {
    return AppCustomTheme.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  factory AppCustomTheme.fromJson(Map<String, dynamic> json) {
    return AppCustomTheme(
      enabled: json['enabled'] as bool? ?? false,
      surfaceOpacity: (json['surfaceOpacity'] as num?)?.toDouble() ?? 0.8,
      surfaceBlur: (json['surfaceBlur'] as num?)?.toDouble() ?? 10,
      useNowPlayingCoverBackground:
          json['useNowPlayingCoverBackground'] as bool? ?? false,
      backgroundImageOpacity:
          (json['backgroundImageOpacity'] as num?)?.toDouble() ?? 0.22,
      backgroundImageBlur:
          (json['backgroundImageBlur'] as num?)?.toDouble() ?? 26,
      accentColor: _colorFromJson(json['accentColor'], const Color(0xff64748b)),
      backgroundColor:
          _colorFromJson(json['backgroundColor'], const Color(0xff09090b)),
      foregroundColor:
          _colorFromJson(json['foregroundColor'], const Color(0xfffafafa)),
      cardColor: _colorFromJson(json['cardColor'], const Color(0xff18181b)),
      cardForegroundColor:
          _colorFromJson(json['cardForegroundColor'], const Color(0xfffafafa)),
      secondaryColor:
          _colorFromJson(json['secondaryColor'], const Color(0xff27272a)),
      mutedColor: _colorFromJson(json['mutedColor'], const Color(0xff18181b)),
      mutedForegroundColor:
          _colorFromJson(json['mutedForegroundColor'], const Color(0xffa1a1aa)),
      borderColor: _colorFromJson(json['borderColor'], const Color(0xff27272a)),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'surfaceOpacity': surfaceOpacity,
      'surfaceBlur': surfaceBlur,
      'useNowPlayingCoverBackground': useNowPlayingCoverBackground,
      'backgroundImageOpacity': backgroundImageOpacity,
      'backgroundImageBlur': backgroundImageBlur,
      'accentColor': accentColor.toARGB32(),
      'backgroundColor': backgroundColor.toARGB32(),
      'foregroundColor': foregroundColor.toARGB32(),
      'cardColor': cardColor.toARGB32(),
      'cardForegroundColor': cardForegroundColor.toARGB32(),
      'secondaryColor': secondaryColor.toARGB32(),
      'mutedColor': mutedColor.toARGB32(),
      'mutedForegroundColor': mutedForegroundColor.toARGB32(),
      'borderColor': borderColor.toARGB32(),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  AppCustomTheme copyWith({
    bool? enabled,
    double? surfaceOpacity,
    double? surfaceBlur,
    bool? useNowPlayingCoverBackground,
    double? backgroundImageOpacity,
    double? backgroundImageBlur,
    Color? accentColor,
    Color? backgroundColor,
    Color? foregroundColor,
    Color? cardColor,
    Color? cardForegroundColor,
    Color? secondaryColor,
    Color? mutedColor,
    Color? mutedForegroundColor,
    Color? borderColor,
  }) {
    return AppCustomTheme(
      enabled: enabled ?? this.enabled,
      surfaceOpacity: surfaceOpacity ?? this.surfaceOpacity,
      surfaceBlur: surfaceBlur ?? this.surfaceBlur,
      useNowPlayingCoverBackground:
          useNowPlayingCoverBackground ?? this.useNowPlayingCoverBackground,
      backgroundImageOpacity:
          backgroundImageOpacity ?? this.backgroundImageOpacity,
      backgroundImageBlur: backgroundImageBlur ?? this.backgroundImageBlur,
      accentColor: accentColor ?? this.accentColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      foregroundColor: foregroundColor ?? this.foregroundColor,
      cardColor: cardColor ?? this.cardColor,
      cardForegroundColor: cardForegroundColor ?? this.cardForegroundColor,
      secondaryColor: secondaryColor ?? this.secondaryColor,
      mutedColor: mutedColor ?? this.mutedColor,
      mutedForegroundColor:
          mutedForegroundColor ?? this.mutedForegroundColor,
      borderColor: borderColor ?? this.borderColor,
    );
  }

  static Color _colorFromJson(Object? value, Color fallback) {
    if (value is int) return Color(value);
    if (value is String) return Color(int.parse(value));
    return fallback;
  }
}
