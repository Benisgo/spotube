import 'dart:math';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

abstract class PrimitiveUtils {
  static bool containsTextInBracket(String matcher, String text) {
    final allMatches = RegExp(r"(?<=\().+?(?=\))").allMatches(matcher);
    if (allMatches.isEmpty) return false;
    return allMatches
        .map((e) => e.group(0))
        .every((match) => match?.contains(text) ?? false);
  }

  static final Random _random = Random();
  static T getRandomElement<T>(List<T> list) {
    return list[_random.nextInt(list.length)];
  }

  static const uuid = Uuid();

  static String toReadableNumber(double num) {
    if (num > 999 && num < 99999) {
      return "${(num / 1000).toStringAsFixed(0)}K";
    } else if (num > 99999 && num < 999999) {
      return "${(num / 1000).toStringAsFixed(0)}K";
    } else if (num > 999999 && num < 999999999) {
      return "${(num / 1000000).toStringAsFixed(0)}M";
    } else if (num > 999999999) {
      return "${(num / 1000000000).toStringAsFixed(0)}B";
    } else {
      return num.toStringAsFixed(0);
    }
  }

  static Future<T> raceMultiple<T>(
    Future<T> Function() inner, {
    Duration timeout = const Duration(milliseconds: 2500),
    int retryCount = 4,
  }) async {
    return Future.any(
      List.generate(retryCount, (i) {
        if (i == 0) return inner();
        return Future.delayed(
          Duration(milliseconds: timeout.inMilliseconds * i),
          inner,
        );
      }),
    );
  }

  static String toSafeFileName(String str) {
    return str.replaceAll(RegExp(r'[/\?%*:|"<>]'), ' ');
  }
}

extension SpotifyDateAddedX on DateTime {
  String toSpotifyDateAdded({DateTime? relativeTo}) {
    final now = relativeTo ?? DateTime.now();
    final difference = now.difference(this);

    if (difference.inSeconds < 60) {
      return "just now";
    }

    if (difference.inMinutes < 60) {
      final mins = difference.inMinutes;
      return "$mins ${mins == 1 ? 'minute' : 'minutes'} ago";
    }

    if (difference.inHours < 24) {
      final hours = difference.inHours;
      return "$hours ${hours == 1 ? 'hour' : 'hours'} ago";
    }

    if (difference.inDays < 7) {
      final days = difference.inDays;
      return "$days ${days == 1 ? 'day' : 'days'} ago";
    }

    if (difference.inDays < 30) {
      final weeks = (difference.inDays / 7).floor();
      final effectiveWeeks = weeks < 1 ? 1 : weeks;
      return "$effectiveWeeks ${effectiveWeeks == 1 ? 'week' : 'weeks'} ago";
    }

    return DateFormat.yMMMd().format(this);
  }
}
