import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SCV Water Emulator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.cyanAccent,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Colors.cyanAccent,
          secondary: Colors.blueAccent,
          surface: Color(0xFF1E1E1E),
        ),
        sliderTheme: const SliderThemeData(
          showValueIndicator: ShowValueIndicator.onDrag,
        ),
      ),
      home: const WaterSimulatorApp(),
    );
  }
}

final kitchenActiveProvider = StateProvider<bool>((ref) => false);
final kitchenFlowRateProvider = StateProvider<double>((ref) => 65.0);

final showerActiveProvider = StateProvider<bool>((ref) => false);
final showerFlowRateProvider = StateProvider<double>((ref) => 80.0);

final bathtubActiveProvider = StateProvider<bool>((ref) => false);
final bathtubFlowRateProvider = StateProvider<double>((ref) => 120.0);

final toiletFlushingProvider = StateProvider<bool>((ref) => false);
final toiletFlushDurationProvider = StateProvider<int>((ref) => 0);
const double toiletFlushFlowRate = 1000.0;
const int toiletFlushSeconds = 5;

class WaterSimulatorApp extends ConsumerStatefulWidget {
  const WaterSimulatorApp({super.key});

  @override
  ConsumerState<WaterSimulatorApp> createState() => _WaterSimulatorAppState();
}

class _WaterSimulatorAppState extends ConsumerState<WaterSimulatorApp> {
  static const _pairingCodePrefKey = 'emu_pairing_code';
  final TextEditingController _pairingCodeController = TextEditingController();
  Timer? _simulationTimer;
  Timer? _toiletCountdownTimer;
  final Random _random = Random();
  String _statusMessage = "準備就緒";
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _pairingCodeController.addListener(_onPairingCodeChanged);
    _loadSavedPairingCode();
    _startSimulationLoop();
  }

  Future<void> _loadSavedPairingCode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_pairingCodePrefKey);
    if (!mounted) return;
    setState(() {
      _pairingCodeController.text =
          (saved != null && saved.isNotEmpty) ? saved : "DEMO_01";
    });
  }

  Future<void> _onPairingCodeChanged() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pairingCodePrefKey, _pairingCodeController.text.trim());
  }

  @override
  void dispose() {
    _simulationTimer?.cancel();
    _toiletCountdownTimer?.cancel();
    _pairingCodeController.removeListener(_onPairingCodeChanged);
    _pairingCodeController.dispose();
    super.dispose();
  }

  void _startSimulationLoop() {
    _simulationTimer?.cancel();
    _simulationTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_pairingCodeController.text.trim().isEmpty) return;

      _handleToiletFlushLogic();

      final noise = 0.9 + (_random.nextDouble() * 0.2);
      final kFlow = ref.read(kitchenActiveProvider)
          ? ref.read(kitchenFlowRateProvider) * noise
          : 0.0;
      final sFlow = ref.read(showerActiveProvider)
          ? ref.read(showerFlowRateProvider) * noise
          : 0.0;
      final bFlow = ref.read(bathtubActiveProvider)
          ? ref.read(bathtubFlowRateProvider) * noise
          : 0.0;
      final tFlow = ref.read(toiletFlushingProvider) ? toiletFlushFlowRate : 0.0;

      final totalFlow = kFlow + sFlow + bFlow + tFlow;

      setState(() {
        _isSending = totalFlow > 0;
        _statusMessage = _isSending
            ? "上傳中... 總流量: ${totalFlow.toStringAsFixed(1)} mL/s"
            : "待機中 (無水流)";
      });

      if (totalFlow > 0) {
        _sendData({
          'kitchen_flow': double.parse(kFlow.toStringAsFixed(1)),
          'shower_flow': double.parse(sFlow.toStringAsFixed(1)),
          'bathtub_flow': double.parse(bFlow.toStringAsFixed(1)),
          'toilet_flow': double.parse(tFlow.toStringAsFixed(1)),
        });
      }
    });
  }

  void _handleToiletFlushLogic() {
    if (!ref.read(toiletFlushingProvider)) return;

    final remaining = ref.read(toiletFlushDurationProvider);
    if (remaining <= 0) {
      ref.read(toiletFlushingProvider.notifier).state = false;
    }
  }

  void _flushToilet() {
    if (ref.read(toiletFlushingProvider)) return;

    ref.read(toiletFlushingProvider.notifier).state = true;
    ref.read(toiletFlushDurationProvider.notifier).state = toiletFlushSeconds;

    _toiletCountdownTimer?.cancel();
    _toiletCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final remaining = ref.read(toiletFlushDurationProvider);
      if (remaining > 0) {
        ref.read(toiletFlushDurationProvider.notifier).state = remaining - 1;
      } else {
        ref.read(toiletFlushingProvider.notifier).state = false;
        timer.cancel();
      }
    });
  }

  Future<void> _sendData(Map<String, dynamic> data) async {
    final deviceId = _pairingCodeController.text.trim();
    if (deviceId.isEmpty) return;

    try {
      await FirebaseFirestore.instance
          .collection('readings')
          .doc(deviceId)
          .collection('stream')
          .add({
            ...data,
            'timestamp': FieldValue.serverTimestamp(),
          });
    } catch (e) {
      debugPrint("Error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final panelDecoration = BoxDecoration(
      color: Colors.white.withAlpha(13),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white10),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('SCV IoT 模擬器'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_isSending)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Icon(Icons.cloud_upload, color: Colors.cyanAccent),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: panelDecoration,
              child: Column(
                children: [
                  TextField(
                    controller: _pairingCodeController,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      letterSpacing: 2,
                      fontWeight: FontWeight.bold,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'DEVICE ID (配對碼)',
                      border: InputBorder.none,
                      prefixIcon: Icon(Icons.link, color: Colors.cyanAccent),
                    ),
                  ),
                  Text(
                    _statusMessage,
                    style: TextStyle(
                      color: _isSending ? Colors.cyanAccent : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            DeviceControlCard(
              name: "廚房水槽",
              icon: Icons.kitchen,
              color: Colors.orangeAccent,
              activeProvider: kitchenActiveProvider,
              flowRateProvider: kitchenFlowRateProvider,
              maxFlow: 150.0,
            ),
            DeviceControlCard(
              name: "淋浴間",
              icon: Icons.shower,
              color: Colors.blueAccent,
              activeProvider: showerActiveProvider,
              flowRateProvider: showerFlowRateProvider,
              maxFlow: 200.0,
            ),
            DeviceControlCard(
              name: "浴缸",
              icon: Icons.bathtub,
              color: Colors.purpleAccent,
              activeProvider: bathtubActiveProvider,
              flowRateProvider: bathtubFlowRateProvider,
              maxFlow: 300.0,
            ),
            _buildToiletCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildToiletCard() {
    final isFlushing = ref.watch(toiletFlushingProvider);
    final timeLeft = ref.watch(toiletFlushDurationProvider);

    return Card(
      color: isFlushing
          ? Colors.redAccent.withAlpha(51)
          : Colors.white.withAlpha(13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: isFlushing ? null : _flushToilet,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.delete_outline, size: 32),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "馬桶沖水",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  Text(isFlushing ? "沖水中... ${timeLeft}s" : "點擊沖水 (固定 1000 mL/s)"),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DeviceControlCard extends ConsumerWidget {
  final String name;
  final IconData icon;
  final Color color;
  final StateProvider<bool> activeProvider;
  final StateProvider<double> flowRateProvider;
  final double maxFlow;

  const DeviceControlCard({
    super.key,
    required this.name,
    required this.icon,
    required this.color,
    required this.activeProvider,
    required this.flowRateProvider,
    this.maxFlow = 200.0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = ref.watch(activeProvider);
    final flowRate = ref.watch(flowRateProvider);

    final bgColor = isActive ? color.withAlpha(25) : Colors.white.withAlpha(13);
    final borderColor = isActive ? color.withAlpha(128) : Colors.transparent;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, color: isActive ? color : Colors.grey),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Switch(
                value: isActive,
                thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
                  if (states.contains(WidgetState.selected)) return color;
                  return Colors.grey;
                }),
                trackColor: WidgetStateProperty.resolveWith<Color>((states) {
                  if (states.contains(WidgetState.selected)) {
                    return color.withAlpha(100);
                  }
                  return Colors.grey.withAlpha(50);
                }),
                onChanged: (val) => ref.read(activeProvider.notifier).state = val,
              ),
            ],
          ),
          if (isActive) ...[
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("流速設定"),
                Text(
                  "${flowRate.round()} mL/s",
                  style: TextStyle(color: color, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: color,
                thumbColor: color,
                inactiveTrackColor: Colors.grey.withAlpha(70),
              ),
              child: Slider(
                value: flowRate,
                min: 0,
                max: maxFlow,
                divisions: maxFlow ~/ 5,
                onChanged: (val) => ref.read(flowRateProvider.notifier).state = val,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
