import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'dart:async';

import 'package:scv_water_emu/firebase_options.dart';

// --- 您需要_Initialize Firebase---
// 1. 請先確保您已設定 Firebase 專案並將 google-services.json (Android) / GoogleService-Info.plist (iOS) 加入
// 2. 在 pubspec.yaml 加入:
//    flutter_riverpod: ^2.5.1
//    firebase_core: ^2.27.2
//    cloud_firestore: ^4.15.10
//
// 3. 您的 main.dart 應如下所示:
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform, // 如果您使用 FlutterFire CLI
  );
  runApp(ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'SCV Water Emulator', home: WaterSimulatorApp());
  }
}
// --- Firebase 結束 ---

// --- 定義水流速率 (mL/秒) ---
const double kitchenSinkFlow = 65.0;
const double showerFlow = 65.0;
const double bathtubFlow = 65.0;
const double toiletFlushFlow = 1000.0; // 假設沖 5 秒
const int toiletFlushDuration = 5; // 沖水持續秒數
// ---

// --- 狀態管理 (Riverpod) ---
// 廚房
final kitchenSinkProvider = StateProvider<bool>((ref) => false);
// 衛浴
final showerProvider = StateProvider<bool>((ref) => false);
final bathtubProvider = StateProvider<bool>((ref) => false);
final toiletFlushingProvider = StateProvider<bool>((ref) => false); // 是否正在沖馬桶
final toiletFlushTimerProvider = StateProvider<int>((ref) => 0); // 沖水剩餘秒數
// ---

class WaterSimulatorApp extends ConsumerStatefulWidget {
  const WaterSimulatorApp({super.key});

  @override
  _WaterSimulatorAppState createState() => _WaterSimulatorAppState();
}

class _WaterSimulatorAppState extends ConsumerState<WaterSimulatorApp> {
  final TextEditingController _pairingCodeController = TextEditingController();
  Timer? _simulationTimer;
  String _statusMessage = "尚未連線";

  @override
  void initState() {
    super.initState();
    // 啟動每秒一次的模擬計時器
    _startSimulationLoop();
  }

  @override
  void dispose() {
    _simulationTimer?.cancel();
    _pairingCodeController.dispose();
    super.dispose();
  }

  void _startSimulationLoop() {
    _simulationTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (_pairingCodeController.text.isEmpty) {
        setState(() {
          _statusMessage = "請輸入配對號碼";
        });
        return; // 沒有配對碼，不傳送
      }

      // 檢查是否正在沖馬桶
      _handleToiletFlush();

      // 讀取目前所有裝置的狀態
      final isKitchenSinkOn = ref.read(kitchenSinkProvider);
      final isShowerOn = ref.read(showerProvider);
      final isBathtubOn = ref.read(bathtubProvider);
      final isToiletFlushing = ref.read(toiletFlushingProvider);

      // --- 計算總水量 (疊加) ---
      double kitchenTotalML = 0;
      if (isKitchenSinkOn) {
        kitchenTotalML += kitchenSinkFlow;
      }

      double restroomTotalML = 0;
      if (isShowerOn) {
        restroomTotalML += showerFlow;
      }
      if (isBathtubOn) {
        restroomTotalML += bathtubFlow;
      }
      if (isToiletFlushing) {
        restroomTotalML += toiletFlushFlow;
      }
      // ---

      setState(() {
        _statusMessage =
            "傳送中... (廚房: ${kitchenTotalML}mL/s, 衛浴: ${restroomTotalML}mL/s)";
      });

      // --- 傳送資料到 Firebase ---
      if (kitchenTotalML > 0) {
        _sendData("KITCHEN", kitchenTotalML);
      }
      if (restroomTotalML > 0) {
        _sendData("RESTROOM", restroomTotalML);
      }
      // ---
    });
  }

  // 處理馬桶沖水計時
  void _handleToiletFlush() {
    if (ref.read(toiletFlushingProvider)) {
      int remaining = ref.read(toiletFlushTimerProvider);
      if (remaining > 0) {
        ref.read(toiletFlushTimerProvider.notifier).state = remaining - 1;
      } else {
        // 沖水結束
        ref.read(toiletFlushingProvider.notifier).state = false;
      }
    }
  }

  // 觸發沖馬桶
  void _flushToilet() {
    if (!ref.read(toiletFlushingProvider)) {
      ref.read(toiletFlushingProvider.notifier).state = true;
      ref.read(toiletFlushTimerProvider.notifier).state = toiletFlushDuration;
    }
  }

  // 傳送資料
  Future<void> _sendData(String location, double amountML) async {
    final pairingCode = _pairingCodeController.text;
    if (pairingCode.isEmpty) return;

    try {
      // 這會在 'channels' 集合中找到 {pairingCode} 文件，
      // 並在底下的 'logs' 子集合中新增一筆資料
      await FirebaseFirestore.instance
          .collection('channels')
          .doc(pairingCode)
          .collection('logs')
          .add({
            'location': location,
            'amountML': amountML,
            'timestamp': FieldValue.serverTimestamp(), // 使用伺服器時間
          });
    } catch (e) {
      // 實際應用中應處理錯誤
      print("Firebase 傳送失敗: $e");
      setState(() {
        _statusMessage = "錯誤：傳送失敗";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 監聽馬桶剩餘秒數以更新 UI
    final toiletTimeLeft = ref.watch(toiletFlushTimerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('App 1 - 用水模擬器'),
        backgroundColor: Colors.blueGrey[800],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- 配對區 ---
            TextField(
              controller: _pairingCodeController,
              decoration: InputDecoration(
                labelText: '輸入 App 2 的配對號碼',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                prefixIcon: Icon(Icons.link),
              ),
              keyboardType: TextInputType.number,
            ),
            SizedBox(height: 12),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
            SizedBox(height: 24),

            // --- 廚房區 ---
            _buildSectionHeader('廚房 (Kitchen)'),
            _buildWaterControlTile(
              title: '廚房水槽',
              icon: Icons.kitchen,
              provider: kitchenSinkProvider,
            ),

            SizedBox(height: 24),

            // --- 衛浴區 ---
            _buildSectionHeader('衛浴 (Restroom)'),
            _buildWaterControlTile(
              title: '淋浴',
              icon: Icons.shower,
              provider: showerProvider,
            ),
            _buildWaterControlTile(
              title: '浴缸',
              icon: Icons.bathtub,
              provider: bathtubProvider,
            ),
            SizedBox(height: 12),
            ElevatedButton.icon(
              icon: Icon(Icons.water_drop),
              label: Text(
                ref.watch(toiletFlushingProvider)
                    ? '沖水中... (${toiletTimeLeft}s)'
                    : '沖馬桶',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: ref.watch(toiletFlushingProvider)
                    ? Colors.redAccent
                    : Colors.blue,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: ref.watch(toiletFlushingProvider)
                  ? null
                  : _flushToilet,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: Colors.blueGrey[700],
        ),
      ),
    );
  }

  Widget _buildWaterControlTile({
    required String title,
    required IconData icon,
    required StateProvider<bool> provider,
  }) {
    // 使用 Consumer 來重建這個小組件
    return Consumer(
      builder: (context, ref, child) {
        final isOn = ref.watch(provider);
        return Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: SwitchListTile(
            title: Text(title, style: TextStyle(fontWeight: FontWeight.w500)),
            secondary: Icon(icon, color: isOn ? Colors.blue : Colors.grey),
            value: isOn,
            onChanged: (bool value) {
              ref.read(provider.notifier).state = value;
            },
            activeThumbColor: Colors.blueAccent,
          ),
        );
      },
    );
  }
}
