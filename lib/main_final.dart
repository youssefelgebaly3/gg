import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'dart:convert';
import 'dart:async';

void main() {
  runApp(MotoLockApp());
}

class MotoLockApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MotoLock',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Arial',
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Arial',
        brightness: Brightness.dark,
      ),
      home: MotoLockHomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MotoLockHomePage extends StatefulWidget {
  @override
  _MotoLockHomePageState createState() => _MotoLockHomePageState();
}

class _MotoLockHomePageState extends State<MotoLockHomePage>
    with TickerProviderStateMixin {
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? writeCharacteristic;
  BluetoothCharacteristic? notifyCharacteristic;
  bool isConnected = false;
  bool isConnecting = false;
  bool isScanning = false;
  bool shouldAutoConnect = false;
  bool isLocked = false;

  final TextEditingController macController = TextEditingController();

  List<BluetoothDevice> foundDevices = [];
  List<ScanResult> scanResults = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothAdapterState>? _btStateSub;

  // متحكمات الرسوم المتحركة
  late AnimationController _animationController;
  Map<String, AnimationController> buttonAnimations = {};

  // مشغل الأصوات
  late AudioPlayer _audioPlayer;

  // حالة زر المارش (للضغط المطول)
  bool isStarterPressed = false;

  // إضافة متغيرات لحفظ حالة الأزرار
  bool isAlarmActive = false;
  bool isEngineStarted = false;

  // متغيرات التحكم الصوتي
  late SpeechToText _speechToText;
  bool _speechEnabled = false;
  bool _isListening = false;
  String _lastWords = '';
  bool _voiceControlEnabled = true;

  // مؤقتات
  Timer? _stopIndicatorTimer;
  Timer? _engineStopDelayTimer;
  Timer? _starterTimer;
  Timer? _voiceSequenceTimer;

  // حالة البلوتوث
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  // متغيرات الرسائل
  List<String> _messages = [];
  int _messageCount = 0;
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: Duration(milliseconds: 150),
      vsync: this,
    );

    // إنشاء متحكمات للأزرار
    ['LOCK', 'UNLOCK', 'START', 'STOP', 'ALARM', 'STARTER'].forEach((button) {
      buttonAnimations[button] = AnimationController(
        duration: Duration(milliseconds: 150),
        vsync: this,
      );
    });

    // تهيئة مشغل الأصوات
    _audioPlayer = AudioPlayer();

    // تهيئة التحكم الصوتي
    _speechToText = SpeechToText();

    requestPermissions();
    loadSavedCredentials();
    loadButtonStates();
    _initSpeech();
    
    // مراقبة حالة البلوتوث
    _btStateSub = FlutterBluePlus.adapterState.listen((s) {
      if (!mounted) return;
      setState(() {
        _adapterState = s;
      });
      if (s == BluetoothAdapterState.on) {
        _attemptAutoConnectIfEligible();
      }
    });
  }

  // تهيئة التحكم الصوتي
  Future<void> _initSpeech() async {
    _speechEnabled = await _speechToText.initialize();
    setState(() {});
  }

  // بدء الاستماع للصوت
  Future<void> _startListening() async {
    if (!_voiceControlEnabled || !_speechEnabled) return;

    await _speechToText.listen(
      onResult: (result) {
        setState(() {
          _lastWords = result.recognizedWords;
        });
        _processVoiceCommand(_lastWords);
      },
      listenFor: Duration(seconds: 5),
      pauseFor: Duration(seconds: 3),
      localeId: 'ar',
      onSoundLevelChange: (level) {
        // يمكن إضافة مؤشر مستوى الصوت هنا
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
      ),
    );
    setState(() {
      _isListening = true;
    });
  }

  // إيقاف الاستماع
  Future<void> _stopListening() async {
    await _speechToText.stop();
    setState(() {
      _isListening = false;
    });
  }

  // معالجة الأوامر الصوتية
  void _processVoiceCommand(String command) {
    String lowerCommand = command.toLowerCase();
    
    if (lowerCommand.contains('ذكري شغلي الموتسيكل') || 
        lowerCommand.contains('دوري الموتسيكل')) {
      _executeStartSequence();
    } else if (lowerCommand.contains('أقفل الموتسيكل')) {
      _sendCommand('LOCK');
    } else if (lowerCommand.contains('أوقف المحرك')) {
      _sendCommand('STOP');
    }
  }

  // تنفيذ تسلسل بدء التشغيل
  void _executeStartSequence() {
    if (isLocked) {
      _showMessage('يجب فتح القفل أولاً');
      return;
    }

    _showMessage('بدء تسلسل التشغيل...');
    
    // 1. فتح القفل
    _sendCommand('UNLOCK');
    
    // 2. تشغيل المحرك بعد ثانيتين
    _voiceSequenceTimer = Timer(Duration(seconds: 2), () {
      _sendCommand('START');
      
      // 3. تشغيل المارش بعد ثانيتين إضافيتين
      _voiceSequenceTimer = Timer(Duration(seconds: 2), () {
        _sendCommand('STARTER');
        
        // 4. إيقاف المارش بعد 7 ثوان
        _voiceSequenceTimer = Timer(Duration(seconds: 7), () {
          _sendCommand('STARTER');
          _showMessage('تم إكمال تسلسل التشغيل');
        });
      });
    });
  }

  // تحميل حالة الأزرار من ذاكرة الجهاز
  Future<void> loadButtonStates() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      isLocked = prefs.getBool('is_locked') ?? false;
      isAlarmActive = prefs.getBool('is_alarm_active') ?? false;
      isEngineStarted = prefs.getBool('is_engine_started') ?? false;
      _voiceControlEnabled = prefs.getBool('voice_control_enabled') ?? true;
    });
  }

  // حفظ حالة الأزرار في ذاكرة الجهاز
  Future<void> saveButtonStates() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_locked', isLocked);
    await prefs.setBool('is_alarm_active', isAlarmActive);
    await prefs.setBool('is_engine_started', isEngineStarted);
    await prefs.setBool('voice_control_enabled', _voiceControlEnabled);
  }

  // طلب الصلاحيات
  Future<void> requestPermissions() async {
    await Permission.bluetooth.request();
    await Permission.bluetoothConnect.request();
    await Permission.bluetoothScan.request();
    await Permission.location.request();
    await Permission.microphone.request();
  }

  // تحميل بيانات الاتصال المحفوظة
  Future<void> loadSavedCredentials() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? savedMac = prefs.getString('saved_mac');
    bool? autoConnect = prefs.getBool('auto_connect');
    
    if (savedMac != null) {
      macController.text = savedMac;
      shouldAutoConnect = autoConnect ?? false;
    }
  }

  // حفظ بيانات الاتصال
  Future<void> saveCredentials() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_mac', macController.text);
    await prefs.setBool('auto_connect', shouldAutoConnect);
  }

  // بدء البحث عن الأجهزة
  Future<void> startScan() async {
    if (_adapterState != BluetoothAdapterState.on) {
      _showMessage('يجب تفعيل البلوتوث أولاً');
      return;
    }

    setState(() {
      isScanning = true;
      foundDevices.clear();
    });

    try {
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;
        setState(() {
          scanResults = results;

          for (var result in results) {
            if (!foundDevices.any((d) => d.remoteId == result.device.remoteId)) {
              foundDevices.add(result.device);
            }
          }

          // فرز حسب RSSI
          foundDevices.sort((a, b) {
            final ra = scanResults
                .firstWhere(
                  (r) => r.device.remoteId == a.remoteId,
                  orElse: () => ScanResult(
                    device: a,
                    advertisementData: AdvertisementData(
                      advName: '',
                      txPowerLevel: 0,
                      appearance: 0,
                      connectable: true,
                      manufacturerData: {},
                      serviceData: {},
                      serviceUuids: [],
                    ),
                    rssi: -100,
                  ),
                )
                .rssi;
            final rb = scanResults
                .firstWhere(
                  (r) => r.device.remoteId == b.remoteId,
                  orElse: () => ScanResult(
                    device: b,
                    advertisementData: AdvertisementData(
                      advName: '',
                      txPowerLevel: 0,
                      appearance: 0,
                      connectable: true,
                      manufacturerData: {},
                      serviceData: {},
                      serviceUuids: [],
                    ),
                    rssi: -100,
                  ),
                )
                .rssi;
            return rb.compareTo(ra);
          });
        });
      });

      await FlutterBluePlus.startScan(timeout: Duration(seconds: 10));
    } catch (e) {
      _showMessage('خطأ في البحث: $e');
      setState(() {
        isScanning = false;
      });
    }
  }

  // إيقاف البحث
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    setState(() {
      isScanning = false;
    });
  }

  // الاتصال بالجهاز
  Future<void> connectToDevice() async {
    if (macController.text.isEmpty) {
      _showMessage('يرجى إدخال عنوان MAC');
      return;
    }

    setState(() {
      isConnecting = true;
    });

    try {
      // البحث عن الجهاز في القائمة
      BluetoothDevice? device;
      for (var d in foundDevices) {
        if (d.remoteId.toString() == macController.text) {
          device = d;
          break;
        }
      }

      if (device == null) {
        _showMessage('الجهاز غير موجود في القائمة');
        setState(() {
          isConnecting = false;
        });
        return;
      }

      await device.connect();
      connectedDevice = device;

      // البحث عن الخصائص المطلوبة
      List<BluetoothService> services = await device.discoverServices();
      for (BluetoothService service in services) {
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          if (characteristic.properties.write) {
            writeCharacteristic = characteristic;
          }
          if (characteristic.properties.notify) {
            notifyCharacteristic = characteristic;
            await characteristic.setNotifyValue(true);
            _valueSub = characteristic.lastValueStream.listen((value) {
              _handleReceivedData(value);
            });
          }
        }
      }

      setState(() {
        isConnected = true;
        isConnecting = false;
      });

      _showMessage('تم الاتصال بنجاح');
      await saveCredentials();

    } catch (e) {
      _showMessage('خطأ في الاتصال: $e');
      setState(() {
        isConnected = false;
        isConnecting = false;
      });
    }
  }

  // قطع الاتصال
  Future<void> disconnect() async {
    try {
      await _valueSub?.cancel();
      await connectedDevice?.disconnect();
      setState(() {
        isConnected = false;
        connectedDevice = null;
        writeCharacteristic = null;
        notifyCharacteristic = null;
      });
      _showMessage('تم قطع الاتصال');
    } catch (e) {
      _showMessage('خطأ في قطع الاتصال: $e');
    }
  }

  // إرسال أمر
  Future<void> _sendCommand(String command) async {
    if (!isConnected || writeCharacteristic == null) {
      _showMessage('غير متصل بالجهاز');
      return;
    }

    try {
      List<int> data = utf8.encode(command);
      await writeCharacteristic!.write(data);
      _showMessage('تم إرسال: $command');
    } catch (e) {
      _showMessage('خطأ في الإرسال: $e');
    }
  }

  // معالجة البيانات المستقبلة
  void _handleReceivedData(List<int> data) {
    String received = utf8.decode(data);
    _showMessage('مستقبل: $received');
  }

  // إظهار الرسالة
  void _showMessage(String message) {
    setState(() {
      _messageCount++;
      if (_messageCount > 3) {
        _messages.clear();
        _messageCount = 0;
      }
      _messages.add(message);
    });

    _messageTimer?.cancel();
    _messageTimer = Timer(Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _messages.removeAt(0);
        });
      }
    });
  }

  // محاولة إعادة الاتصال التلقائي
  void _attemptAutoConnectIfEligible() {
    if (shouldAutoConnect &&
        macController.text.isNotEmpty &&
        !isConnected &&
        !isConnecting &&
        _adapterState == BluetoothAdapterState.on) {
      Future.delayed(Duration(milliseconds: 300), () {
        if (mounted && !isConnected && !isConnecting) {
          connectToDevice();
        }
      });
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    buttonAnimations.values.forEach((controller) => controller.dispose());
    _audioPlayer.dispose();
    _scanSub?.cancel();
    _valueSub?.cancel();
    _btStateSub?.cancel();
    _stopIndicatorTimer?.cancel();
    _engineStopDelayTimer?.cancel();
    _starterTimer?.cancel();
    _voiceSequenceTimer?.cancel();
    _messageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: Color(0xFF2C3E50),
        title: Text(
          'MotoLock',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        elevation: 0,
      ),
      body: Column(
        children: [
          // شريط الحالة
          _buildStatusStrip(),
          
          // الرسائل
          if (_messages.isNotEmpty)
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(16),
              child: Column(
                children: _messages.map((msg) => Container(
                  margin: EdgeInsets.only(bottom: 8),
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Color(0xFF34495E),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    msg,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                    textDirection: TextDirection.rtl,
                  ),
                )).toList(),
              ),
            ),

          // المحتوى الرئيسي
          Expanded(
            child: _adapterState != BluetoothAdapterState.on
                ? _buildBluetoothOffScreen()
                : isConnected
                    ? _buildConnectedScreen()
                    : _buildDisconnectedScreen(),
          ),
        ],
      ),
    );
  }

  // شريط الحالة
  Widget _buildStatusStrip() {
    final bool btOn = _adapterState == BluetoothAdapterState.on;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      margin: EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: Color(0xFF223342),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // حالة البلوتوث
          Row(
            children: [
              Icon(
                btOn ? Icons.bluetooth : Icons.bluetooth_disabled,
                color: btOn ? Colors.green : Colors.red,
                size: 20,
              ),
              SizedBox(width: 8),
              Text(
                btOn ? 'بلوتوث مفعل' : 'بلوتوث مغلق',
                style: TextStyle(
                  color: btOn ? Colors.green : Colors.red,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          
          Spacer(),
          
          // حالة الاتصال
          Row(
            children: [
              Icon(
                isConnected ? Icons.link : Icons.link_off,
                color: isConnected ? Colors.green : Colors.red,
                size: 20,
              ),
              SizedBox(width: 8),
              Text(
                isConnected ? 'متصل' : 'غير متصل',
                style: TextStyle(
                  color: isConnected ? Colors.green : Colors.red,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // شاشة البلوتوث مغلق
  Widget _buildBluetoothOffScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bluetooth_disabled,
            size: 80,
            color: Colors.red,
          ),
          SizedBox(height: 20),
          Text(
            'يجب تفعيل البلوتوث أولاً',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 30),
          ElevatedButton.icon(
            onPressed: () async {
              await FlutterBluePlus.turnOn();
            },
            icon: Icon(Icons.bluetooth),
            label: Text('تفعيل البلوتوث'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 30, vertical: 15),
            ),
          ),
        ],
      ),
    );
  }

  // شاشة الاتصال
  Widget _buildConnectedScreen() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          // زر قطع الاتصال
          Center(
            child: Container(
              width: 200,
              child: ElevatedButton.icon(
                onPressed: disconnect,
                icon: Icon(Icons.link_off),
                label: Text('قطع الاتصال'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(vertical: 15),
                ),
              ),
            ),
          ),
          
          SizedBox(height: 30),
          
          // زر التحكم الصوتي
          _buildVoiceControlButton(),
          
          SizedBox(height: 30),
          
          // الأزرار الرئيسية
          _buildMainButtons(),
        ],
      ),
    );
  }

  // شاشة عدم الاتصال
  Widget _buildDisconnectedScreen() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          // حقل MAC
          TextField(
            controller: macController,
            decoration: InputDecoration(
              labelText: 'عنوان MAC',
              labelStyle: TextStyle(color: Colors.white70),
              border: OutlineInputBorder(),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white30),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.blue),
              ),
            ),
            style: TextStyle(color: Colors.white),
          ),
          
          SizedBox(height: 20),
          
          // أزرار البحث والاتصال
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isScanning ? stopScan : startScan,
                  icon: Icon(isScanning ? Icons.stop : Icons.search),
                  label: Text(isScanning ? 'إيقاف البحث' : 'بحث'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 15),
                  ),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isConnecting ? null : connectToDevice,
                  icon: Icon(Icons.link),
                  label: Text('اتصال'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 15),
                  ),
                ),
              ),
            ],
          ),
          
          SizedBox(height: 20),
          
          // قائمة الأجهزة
          if (foundDevices.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: foundDevices.length,
                itemBuilder: (context, index) {
                  final device = foundDevices[index];
                  return ListTile(
                    leading: Icon(Icons.bluetooth, color: Colors.blue),
                    title: Text(
                      device.platformName.isNotEmpty 
                          ? device.platformName 
                          : 'جهاز غير معروف',
                      style: TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      device.remoteId.toString(),
                      style: TextStyle(color: Colors.white70),
                    ),
                    onTap: () {
                      macController.text = device.remoteId.toString();
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  // زر التحكم الصوتي
  Widget _buildVoiceControlButton() {
    return Column(
      children: [
        // زر التحكم الصوتي الرئيسي
        GestureDetector(
          onTap: _voiceControlEnabled ? 
            (_isListening ? _stopListening : _startListening) : null,
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _voiceControlEnabled
                  ? (_isListening ? Colors.red : Colors.blue)
                  : Colors.grey,
              boxShadow: [
                BoxShadow(
                  color: (_isListening ? Colors.red : Colors.blue)
                      .withValues(alpha: 0.3),
                  blurRadius: 20,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: Icon(
              _isListening ? Icons.mic : Icons.mic_none,
              size: 50,
              color: Colors.white,
            ),
          ),
        ),
        
        SizedBox(height: 10),
        
        // نص الحالة
        Text(
          _isListening ? 'استمع...' : 'اضغط للتحدث',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        
        SizedBox(height: 5),
        
        // زر تفعيل/تعطيل التحكم الصوتي
        SwitchListTile(
          title: Text(
            'التحكم الصوتي',
            style: TextStyle(color: Colors.white),
          ),
          value: _voiceControlEnabled,
          onChanged: (value) {
            setState(() {
              _voiceControlEnabled = value;
            });
            saveButtonStates();
          },
          activeThumbColor: Colors.blue,
        ),
      ],
    );
  }

  // الأزرار الرئيسية
  Widget _buildMainButtons() {
    return Column(
      children: [
        // الصف الأول
        Row(
          children: [
            Expanded(child: _buildButton('LOCK', Icons.lock, Colors.red)),
            SizedBox(width: 10),
            Expanded(child: _buildButton('UNLOCK', Icons.lock_open, Colors.green)),
          ],
        ),
        
        SizedBox(height: 10),
        
        // الصف الثاني
        Row(
          children: [
            Expanded(child: _buildButton('START', Icons.play_arrow, Colors.blue)),
            SizedBox(width: 10),
            Expanded(child: _buildButton('STOP', Icons.stop, Colors.orange)),
          ],
        ),
        
        SizedBox(height: 10),
        
        // الصف الثالث
        Row(
          children: [
            Expanded(child: _buildButton('ALARM', Icons.warning, Colors.yellow)),
            SizedBox(width: 10),
            Expanded(child: _buildButton('STARTER', Icons.power_settings_new, Colors.purple)),
          ],
        ),
      ],
    );
  }

  // بناء زر
  Widget _buildButton(String command, IconData icon, Color color) {
    bool isActive = false;
    bool isDisabled = false;

    switch (command) {
      case 'LOCK':
        isActive = isLocked;
        break;
      case 'UNLOCK':
        isActive = !isLocked;
        break;
      case 'START':
        isActive = isEngineStarted;
        isDisabled = isLocked;
        break;
      case 'STOP':
        isActive = false; // مؤقت فقط
        isDisabled = isLocked;
        break;
      case 'ALARM':
        isActive = isAlarmActive;
        break;
      case 'STARTER':
        isActive = isStarterPressed;
        isDisabled = !isEngineStarted;
        break;
    }

    return GestureDetector(
      onTap: isDisabled ? null : () => _sendCommand(command),
      child: AnimatedBuilder(
        animation: buttonAnimations[command]!,
        builder: (context, child) {
          return Transform.scale(
            scale: 1.0 - (buttonAnimations[command]!.value * 0.1),
            child: Container(
              height: 80,
              decoration: BoxDecoration(
                color: isDisabled
                    ? Colors.grey.withValues(alpha: 0.3)
                    : isActive
                        ? color
                        : color.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: isActive ? color : Colors.white30,
                  width: 2,
                ),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: color.withValues(alpha: 0.5),
                          blurRadius: 10,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    color: isDisabled ? Colors.grey : Colors.white,
                    size: 30,
                  ),
                  SizedBox(height: 5),
                  Text(
                    command,
                    style: TextStyle(
                      color: isDisabled ? Colors.grey : Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (isActive && command == 'START')
                    Container(
                      margin: EdgeInsets.only(top: 5),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Colors.yellow,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}