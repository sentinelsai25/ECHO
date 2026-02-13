import 'dart:convert';
import 'dart:async';
import 'crypto_service.dart';
import 'compression_service.dart';
import 'gateway_service.dart';
import 'dart:typed_data';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shake/shake.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

////////////////////////////////////////////////////////////

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox("history");
  await Hive.openBox("profile");
  await Hive.openBox("settings");
  runApp(const MyApp());
}

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

////////////////////////////////////////////////////////////

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');

    notifications.initialize(
      const InitializationSettings(android: android),
    );

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'sos',
      'SOS Alerts',
      description: 'Emergency notifications',
      importance: Importance.max,
    );

    notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  @override
  Widget build(BuildContext context) {
    final profile = Hive.box("profile");
    bool registered =
        profile.get("name") != null && profile.get("phone") != null;

    return ValueListenableBuilder(
      valueListenable: Hive.box("settings").listenable(),
      builder: (context, box, _) {
        bool dark = box.get("dark", defaultValue: false);

        return MaterialApp(
          debugShowCheckedModeBanner: false,
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            brightness: Brightness.light,
            scaffoldBackgroundColor: Colors.white,
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              elevation: 0,
            ),
            bottomNavigationBarTheme: const BottomNavigationBarThemeData(
              backgroundColor: Colors.white,
            ),
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: Colors.black,
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            bottomNavigationBarTheme: const BottomNavigationBarThemeData(
              backgroundColor: Colors.black,
            ),
          ),
          home: registered ? const RescueHome() : const RegisterScreen(),
        );
      },
    );
  }
}

////////////////////////////////////////////////////////////

enum TabType { sos, alerts, profile }

class RescueHome extends StatefulWidget {
  const RescueHome({super.key});

  @override
  State<RescueHome> createState() => _RescueHomeState();
}

class _RescueHomeState extends State<RescueHome>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const String serviceId = "com.echo.rescue_mesh";

  final Strategy strategy = Strategy.P2P_CLUSTER;

  final String userId = const Uuid().v4().substring(0, 5);

  Map<String, ConnectionInfo> peers = {};
  Set<String> seen = {};
  List<Map<String, dynamic>> victims = [];

  String selectedType = "Medical Emergency";
  TabType tab = TabType.sos;

  late AnimationController glow;
  DateTime? lastSOS;
  Timer? retryTimer;
  Timer? sosCountdownTimer;
  Map<String, dynamic>? pendingSOSData;
  int countdown = 0;

  Timer? sosDelayTimer;

  ////////////////////////////////////////////////////////////

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    loadHistory();

    initMesh();

    glow =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..repeat(reverse: true);

    ShakeDetector.autoStart(onPhoneShake: sendSOS);

    GatewayService.start();
    retryTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => forwardPendingMessages(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      debugPrint("App resumed → syncing mesh");

      await forwardPendingMessages();

      for (var id in peers.keys) {
        await sendHistoryToPeer(id);
        await initMesh();
      }
    }
  }

  ////////////////////////////////////////////////////////////

  void loadHistory() {
    final box = Hive.box("history");
    victims = box.values.map((e) => Map<String, dynamic>.from(e)).toList();
    setState(() {});
  }

  Future<void> saveHistory(Map<String, dynamic> data) async {
    final box = Hive.box("history");
    await box.add(data);
  }

  Future<void> clearHistory() async {
    final box = Hive.box("history");
    await box.clear();
    setState(() => victims.clear());
  }

  Future<void> cancelSOS(String msgId) async {
    // If still in delay window
    if (pendingSOSData != null && pendingSOSData!["msgId"] == msgId) {
      sosDelayTimer?.cancel();
      pendingSOSData = null;

      setState(() {
        victims.removeWhere((v) => v["msgId"] == msgId);
      });

      return;
    }

    // If already sent → do nothing
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Cannot cancel after sending")),
    );
  }

  ////////////////////////////////////////////////////////////
  Future<void> initMesh() async {
    await Nearby().stopAllEndpoints();
    await Nearby().stopAdvertising();
    await Nearby().stopDiscovery();

    Future<void> requestPermissions() async {
      // Location (required for discovery)
      if (!await Permission.location.isGranted) {
        await Permission.location.request();
      }

      // Android 12+ Bluetooth permissions
      if (!await Permission.bluetoothScan.isGranted) {
        await Permission.bluetoothScan.request();
      }

      if (!await Permission.bluetoothConnect.isGranted) {
        await Permission.bluetoothConnect.request();
      }

      if (!await Permission.bluetoothAdvertise.isGranted) {
        await Permission.bluetoothAdvertise.request();
      }

      if (!await Permission.nearbyWifiDevices.isGranted) {
        await Permission.nearbyWifiDevices.request();
      }

      if (!await Permission.notification.isGranted) {
        await Permission.notification.request();
      }
    }

    await requestPermissions();
    Future.microtask(() => forwardPendingMessages());

    debugPrint("Starting Advertising + Discovery (Cluster Mode)");

    await Nearby().startAdvertising(
      userId,
      strategy,
      serviceId: serviceId,
      onConnectionInitiated: (id, info) => accept(id, info),
      onConnectionResult: (id, status) {
        debugPrint("Advertising status: $status");
      },
      onDisconnected: (id) async {
        peers.remove(id);

        debugPrint("Re-syncing mesh after disconnect");

        await Future.delayed(const Duration(seconds: 2));
        await initMesh(); // restart discovery
      },
    );

    await Nearby().startDiscovery(
      userId,
      strategy,
      serviceId: serviceId,
      onEndpointFound: (id, name, serviceId) async {
        debugPrint("Found device: $id");

        try {
          await Nearby().requestConnection(
            userId,
            id,
            onConnectionInitiated: (id, info) => accept(id, info),
            onConnectionResult: (id, status) {
              debugPrint("Discovery status: $status");
            },
            onDisconnected: (id) async {
              debugPrint("Disconnected: $id");
              peers.remove(id);

              await Future.delayed(const Duration(seconds: 1));
              await initMesh();
            },
          );
        } catch (e) {
          debugPrint("Connection failed: $e");
        }
      },
      onEndpointLost: (id) {
        debugPrint("Lost endpoint: $id");
      },
    );

    forwardPendingMessages();
  }

  //////////////////////////////////////////

  Future<void> notify(String type) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'sos',
        'SOS Alerts',
        importance: Importance.max,
        priority: Priority.high,
      ),
    );

    await notifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(2147483647),
      "🚨 $type",
      "Incoming emergency alert",
      details,
    );
  }

  ////////////////////////////////////////////////////////////

  void accept(String id, ConnectionInfo info) {
    Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (endid, payload) async {
        if (payload.type != PayloadType.BYTES) return;

        Uint8List bytes = payload.bytes!;

        Map<String, dynamic> data;

        try {
          String encrypted = CompressionService.decompress(bytes);
          String decrypted = CryptoService.decrypt(encrypted);
          data = jsonDecode(decrypted) as Map<String, dynamic>;

// STOP if already processed
          // If message already processed
          // If message already processed AND it's not a cancel, ignore
          if (seen.contains(data["msgId"]) && data["cancelled"] != true) {
            return;
          }

// Mark as seen
          seen.add(data["msgId"]);

// If this is a cancel message → remove it
          if (data["cancelled"] == true) {
            // Remove from UI
            setState(() {
              victims.removeWhere((v) => v["msgId"] == data["msgId"]);
            });

            // Remove from Hive history
            final box = Hive.box("history");
            for (int i = 0; i < box.length; i++) {
              Map<String, dynamic> stored =
                  Map<String, dynamic>.from(box.getAt(i));

              if (stored["msgId"] == data["msgId"]) {
                await box.deleteAt(i); // 🔥 DELETE completely
                break;
              }
            }

            // Forward cancel to other peers
            for (var p in peers.keys) {
              if (p != endid) {
                await sendWithRetry(p, payload.bytes!);
              }
            }

            return;
          }

// Notify only if not my own message
          if (data["device"] != userId) {
            await notify(data["type"]);
          }
        } catch (e) {
          debugPrint("Receive error: $e");
          return;
        }
        // If this is MY message coming back from mesh → mark delivered
        if (data["device"] == userId) {
          final box = Hive.box("history");

          for (int i = 0; i < box.length; i++) {
            Map<String, dynamic> stored =
                Map<String, dynamic>.from(box.getAt(i));

            if (stored["msgId"] == data["msgId"]) {
              stored["pending"] = false;
              await box.putAt(i, stored);

              int index =
                  victims.indexWhere((v) => v["msgId"] == data["msgId"]);

              if (index != -1) {
                victims[index]["pending"] = false;
                if (mounted) setState(() {});
              }

              break;
            }
          }
        }
        if (data["cancelled"] == true) {
          return;
        }

// Add only if message is NOT already in UI
        int existingIndex =
            victims.indexWhere((v) => v["msgId"] == data["msgId"]);

        if (existingIndex == -1) {
          // If message is NOT mine → never show pending
          if (data["device"] != userId) {
            data["pending"] = false;
          }

          if (mounted) {
            setState(() => victims.add(data));
          }
        }

        // Forward to others
        for (var p in peers.keys) {
          if (p != endid && p != id) {
            await sendWithRetry(p, bytes);
          }
        }
      },
      onPayloadTransferUpdate: (_, __) {},
    );

    peers[id] = info;

    Timer(const Duration(milliseconds: 800), () async {
      await sendHistoryToPeer(id);
      await forwardPendingMessages();
    });

    debugPrint("Accepted connection: $id");
  }

  ////////////////////////////////////////////////////////////

  Future<void> sendSOS() async {
    if (countdown > 0) return; // already counting

    countdown = 5;
    setState(() {});

    sosCountdownTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (countdown > 1) {
        countdown--;
        setState(() {});
      } else {
        timer.cancel();

        if (!mounted) return;

        setState(() {
          countdown = 0;
          tab = TabType.alerts; // 🔥 SWITCH IMMEDIATELY
        });

        if (pendingSOSData != null) {
          await actuallySendSOS(pendingSOSData!);
          pendingSOSData = null;
        }
      }
    });

    // Prepare SOS data now
    final profile = Hive.box("profile");
    Position pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.low,
        timeLimit: Duration(seconds: 3),
      ),
    );

    int battery = await Battery().batteryLevel;

    pendingSOSData = {
      "msgId": "${userId}_${DateTime.now().millisecondsSinceEpoch}",
      "device": userId,
      "type": selectedType,
      "lat": pos.latitude,
      "lng": pos.longitude,
      "battery": battery,
      "time": DateTime.now().toString(),
      "name": profile.get("name"),
      "phone": profile.get("phone"),
      "uploaded": false,
      "pending": true,
      "cancelled": false,
    };
  }

  Future<void> actuallySendSOS(Map<String, dynamic> data) async {
    // Mark seen
    seen.add(data["msgId"]);

    // Save to Hive
    await saveHistory(data);

    // Add to UI list
    if (mounted) {
      setState(() {
        victims.add(data);
      });
    }

    // Encrypt + compress
    String json = jsonEncode(data);
    String encrypted = CryptoService.encrypt(json);
    Uint8List compressed = CompressionService.compress(encrypted);

    bool delivered = false;

    for (var id in peers.keys) {
      bool result = await sendWithRetry(id, compressed);
      if (result) delivered = true;
    }

    // Update pending status
    if (delivered) {
      final box = Hive.box("history");

      for (int i = 0; i < box.length; i++) {
        Map<String, dynamic> stored = Map<String, dynamic>.from(box.getAt(i));

        if (stored["msgId"] == data["msgId"]) {
          stored["pending"] = false;
          await box.putAt(i, stored);

          int index = victims.indexWhere((v) => v["msgId"] == data["msgId"]);

          if (index != -1) {
            victims[index]["pending"] = false;
          }

          break;
        }
      }
    }

    // 🔥 SWITCH TO ALERT PAGE
    if (mounted) {}
  }

  ////////////////////////////////////////////////////////////

// 👇 ADD HERE 👇
  void attemptForward(Uint8List compressed) {
    if (peers.isEmpty) return;
  }

  Future<bool> sendWithRetry(String endpointId, Uint8List data) async {
    try {
      await Nearby().sendBytesPayload(endpointId, data);
      return true;
    } catch (e) {
      debugPrint("Send failed to $endpointId: $e");
      return false;
    }
  }

  Future<void> sendHistoryToPeer(String peerId) async {
    final box = Hive.box("history");

    int start = box.length > 20 ? box.length - 20 : 0;

    for (int i = start; i < box.length; i++) {
      Map<String, dynamic> data = Map<String, dynamic>.from(box.getAt(i));

      if (data["cancelled"] == true) continue;

      String json = jsonEncode(data);
      String encrypted = CryptoService.encrypt(json);
      Uint8List compressed = CompressionService.compress(encrypted);

      await sendWithRetry(peerId, compressed);
    }
  }

  Future<void> forwardPendingMessages() async {
    if (peers.isEmpty) return;

    final box = Hive.box("history");

    for (int i = 0; i < box.length; i++) {
      Map<String, dynamic> data = Map<String, dynamic>.from(box.getAt(i));

      if (data["pending"] == true) {
        String json = jsonEncode(data);

        String encrypted = CryptoService.encrypt(json);
        Uint8List compressed = CompressionService.compress(encrypted);

        bool delivered = false;

        for (var id in peers.keys) {
          bool result = await sendWithRetry(id, compressed);
          if (result) {
            delivered = true;
          }
        }

        // Only clear pending if at least ONE peer got it
        if (delivered) {
          data["pending"] = false;
          await box.putAt(i, data);

          // update UI list
          int index = victims.indexWhere((v) => v["msgId"] == data["msgId"]);
          if (index != -1) {
            victims[index]["pending"] = false;
            if (mounted) setState(() {});
          }
        }
      }
    }
  }

  ////////////////////////////////////////////////////////////

  Future<void> openMap(double lat, double lng) async {
    Uri nav = Uri.parse("google.navigation:q=$lat,$lng");
    if (!await launchUrl(nav)) {
      Uri web = Uri.parse(
          "https://www.google.com/maps/search/?api=1&query=$lat,$lng");
      await launchUrl(web);
    }
  }

  ////////////////////////////////////////////////////////////

  Widget sosButton() {
    return AnimatedBuilder(
      animation: glow,
      builder: (_, __) {
        return GestureDetector(
          onTap: sendSOS,
          child: Container(
            width: 170,
            height: 170,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xff00b3ff),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xff00b3ff)
                      .withValues(alpha: (0.9 * glow.value)),
                  blurRadius: 50,
                  spreadRadius: 18,
                )
              ],
            ),
            child: const Center(
              child: Text(
                "SOS",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ),
        );
      },
    );
  }

  ////////////////////////////////////////////////////////////

  Widget sosTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xff00b3ff), width: 2),
            ),
            child: DropdownButton<String>(
              value: selectedType,
              underline: const SizedBox(),
              style: TextStyle(
                color: Theme.of(context).textTheme.bodyLarge!.color,
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
              items: const [
                DropdownMenuItem(
                    value: "Medical Emergency",
                    child: Text("Medical Emergency")),
                DropdownMenuItem(value: "Disaster", child: Text("Disaster")),
                DropdownMenuItem(
                    value: "Under Attack", child: Text("Under Attack")),
              ],
              onChanged: (v) => setState(() => selectedType = v!),
            ),
          ),
          const SizedBox(height: 45),
          if (countdown == 0)
            sosButton()
          else
            Column(
              children: [
                Text(
                  "Sending in $countdown...",
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
                const SizedBox(height: 15),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    sosCountdownTimer?.cancel();
                    countdown = 0;
                    pendingSOSData = null;
                    setState(() {});
                  },
                  child: const Text("CANCEL"),
                )
              ],
            ),
          const SizedBox(height: 15),
          const Text("Tap to send emergency alert"),
        ],
      ),
    );
  }

  ////////////////////////////////////////////////////////////

  Widget alertsTab() {
    if (victims.isEmpty) {
      return const Center(child: Text("No alerts"));
    }

    return Column(
      children: [
        TextButton(
          onPressed: clearHistory,
          child: const Text("Clear History"),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: victims.length,
            itemBuilder: (_, i) {
              final v = victims[i];
              return Card(
                margin: const EdgeInsets.all(10),
                child: ListTile(
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          v["type"],
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (v["pending"] == true)
                        const Icon(Icons.schedule,
                            color: Colors.orange, size: 18)
                      else
                        const Icon(Icons.check_circle,
                            color: Colors.green, size: 18),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("${v["name"] ?? ""} ${v["phone"] ?? ""}"),
                      Text("Battery ${v["battery"]}%"),
                      Text(v["time"]),
                      const SizedBox(height: 8),

                      // 🔥 ADD NAVIGATION BUTTON
                      if (v["lat"] != null && v["lng"] != null)
                        TextButton.icon(
                          onPressed: () => openMap(v["lat"], v["lng"]),
                          icon:
                              const Icon(Icons.navigation, color: Colors.blue),
                          label: const Text(
                            "Navigate",
                            style: TextStyle(color: Colors.blue),
                          ),
                        ),

                      if (pendingSOSData != null &&
                          v["msgId"] == pendingSOSData!["msgId"])
                        Text(
                          "Sending in $countdown...",
                          style: const TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  ////////////////////////////////////////////////////////////

  Widget profileTab() {
    final box = Hive.box("profile");
    final settings = Hive.box("settings");
    bool dark = settings.get("dark", defaultValue: false);

    final name = TextEditingController(text: box.get("name", defaultValue: ""));
    final phone =
        TextEditingController(text: box.get("phone", defaultValue: ""));

    return Padding(
      padding: const EdgeInsets.all(25),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xff00b3ff),
            ),
            child: const Icon(Icons.person, size: 40, color: Colors.white),
          ),
          const SizedBox(height: 20),
          const Text(
            "Edit Profile",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 25),
          TextField(
            controller: name,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.person),
              labelText: "Full Name",
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.phone),
              labelText: "Phone Number",
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 25),
          SizedBox(
            width: double.infinity,
            height: 55,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xff00b3ff),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () async {
                await box.put("name", name.text);
                await box.put("phone", phone.text);
                if (!mounted) return;
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text("Updated")));
              },
              child: const Text(
                "UPDATE",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 20),
          SwitchListTile(
            title: const Text(
              "Dark Mode",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            value: dark,
            onChanged: (v) async => settings.put("dark", v),
          ),
        ],
      ),
    );
  }

  ////////////////////////////////////////////////////////////

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    retryTimer?.cancel();
    glow.dispose();
    GatewayService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          "ECHO",
          style: TextStyle(
              fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: 2),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: switch (tab) {
          TabType.sos => sosTab(),
          TabType.alerts => alertsTab(),
          TabType.profile => profileTab(),
        },
      ),
      bottomNavigationBar: BottomNavigationBar(
        selectedItemColor: const Color(0xff00b3ff),
        unselectedItemColor: Colors.grey,
        currentIndex: tab.index,
        onTap: (i) => setState(() => tab = TabType.values[i]),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.warning), label: "SOS"),
          BottomNavigationBarItem(
              icon: Icon(Icons.notifications), label: "Alerts"),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: "Profile"),
        ],
      ),
    );
  }
}

////////////////////////////////////////////////////////////
/// REGISTER PAGE
////////////////////////////////////////////////////////////

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final name = TextEditingController();
  final phone = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final box = Hive.box("profile");

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          "ECHO",
          style: TextStyle(
              fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: 2),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xff00b3ff),
              ),
              child: const Icon(Icons.person, size: 45, color: Colors.white),
            ),
            const SizedBox(height: 20),
            const Text(
              "Create Your Profile",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 30),
            TextField(
              controller: name,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.person),
                labelText: "Full Name",
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.phone),
                labelText: "Phone Number",
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 25),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xff00b3ff),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () async {
                  await box.put("name", name.text);
                  await box.put("phone", phone.text);

                  if (!mounted) return;
                  Navigator.pushReplacement(
                    // ignore: use_build_context_synchronously
                    context,
                    MaterialPageRoute(builder: (_) => const RescueHome()),
                  );
                },
                child: const Text(
                  "SAVE",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}
