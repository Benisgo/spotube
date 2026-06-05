import 'package:flutter/material.dart';
import 'package:spotube/models/database/database.dart';

extension LyricsCharacterEdgeTextStyle on TextStyle {
  TextStyle withLyricsCharacterEdge(LyricsCharacterEdge edge) {
    final baseColor = color ?? Colors.white;
    final highlight = Colors.white.withValues(alpha: 0.72);
    final lowlight = Colors.black.withValues(alpha: 0.72);

    return switch (edge) {
      LyricsCharacterEdge.none => this,
      LyricsCharacterEdge.raised => copyWith(
          shadows: [
            Shadow(color: highlight, offset: const Offset(-1, -1)),
            Shadow(color: lowlight, offset: const Offset(1, 1)),
          ],
        ),
      LyricsCharacterEdge.depressed => copyWith(
          shadows: [
            Shadow(color: lowlight, offset: const Offset(-1, -1)),
            Shadow(color: highlight, offset: const Offset(1, 1)),
          ],
        ),
      LyricsCharacterEdge.dropShadow => copyWith(
          shadows: [
            Shadow(
              color: Colors.black.withValues(alpha: 0.65),
              offset: const Offset(2, 2),
              blurRadius: 2,
            ),
          ],
        ),
      LyricsCharacterEdge.outline => copyWith(
          shadows: [
            for (final offset in const [
              Offset(-1, -1),
              Offset(0, -1),
              Offset(1, -1),
              Offset(-1, 0),
              Offset(1, 0),
              Offset(-1, 1),
              Offset(0, 1),
              Offset(1, 1),
            ])
              Shadow(
                color: baseColor.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
                offset: offset,
              ),
          ],
        ),
    };
  }
}
