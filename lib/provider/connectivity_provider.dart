import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/services/connectivity_adapter.dart';

final connectivityProvider = StreamProvider<bool>((ref) {
  return ConnectionCheckerService.instance.onConnectivityChanged;
});
