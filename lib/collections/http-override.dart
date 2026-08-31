import 'dart:io';

import 'package:spotube/services/logger/logger.dart';

/// Hosts whose TLS certificate is accepted even if it fails validation.
///
/// Matched EXACTLY or as a real subdomain (`host == "spotify.com"` or
/// `host.endsWith(".spotify.com")`) — a bare `endsWith("spotify.com")` would
/// also match lookalikes such as `evilspotify.com` or `notspotify.com`.
const allowList = [
  "spotify.com",
];

class BadCertificateAllowlistOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        final allowed = allowList.any(
          (allowedHost) =>
              host == allowedHost || host.endsWith(".$allowedHost"),
        );
        if (allowed) {
          // Surface TLS bypasses instead of silently accepting them, so a
          // broken chain on an allowlisted host is diagnosable.
          AppLogger.log.w(
            "[http-override] accepting certificate that failed validation "
            "for allowlisted host $host",
          );
        }
        return allowed;
      };
  }
}
