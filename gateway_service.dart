import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

class GatewayService {
  static Timer? _timer;
  static bool _busy = false;

  static const String serverUrl =
      "https://uncharacteristic-slimily-jonas.ngrok-free.dev/sos";

  static void start() {
    _timer?.cancel();

    _timer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_busy) return;

      final connectivity = await Connectivity().checkConnectivity();
      // ignore: unrelated_type_equality_checks
      if (connectivity == ConnectivityResult.none) return;

      await uploadPending();
    });
  }

  static Future<void> uploadPending() async {
    _busy = true;

    final box = Hive.box("history");
    if (box.isEmpty) {
      _busy = false;
      return;
    }

    for (int i = 0; i < box.length; i++) {
      final raw = box.getAt(i);
      if (raw == null) continue;

      final data = Map<String, dynamic>.from(raw);
      if (data["uploaded"] == true) continue;

      try {
        final res = await http.post(
          Uri.parse(serverUrl),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode(data),
        );

        if (res.statusCode == 200) {
          data["uploaded"] = true;
          await box.putAt(i, data);
        }
      } catch (_) {}
    }

    _busy = false;
  }

  static void stop() {
    _timer?.cancel();
  }
}
