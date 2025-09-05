import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'dart:async';
import 'dart:convert';
import 'moto_lock_methods.dart';

class MotoLockHomePage extends StatefulWidget {
  @override
  _MotoLockHomePageState createState() => _MotoLockHomePageState();
}

class _MotoLockHomePageState extends State<MotoLockHomePage>
    with TickerProviderStateMixin, MotoLockMethods {
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

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  bool get isBluetoothOn => _adapterState == BluetoothAdapterState.on;

  Map<String, AnimationController> buttonAnimations = {};
  late AudioPlayer _audioPlayer;

  bool isStarterPressed = false;
  bool isAlarmActive = false;
  bool isEngineStarted = false;

  bool isStopIndicatorActive = false;

  Timer? _stopIndicatorTimer;
  Timer? _engineStopDelayTimer;

  // متغيرات التحكم الصوتي
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _lastWords = '';
  bool _voiceControlEnabled = false;
  Timer? _voiceCommandTimer;
  AnimationController? _voiceAnimationController;
  Animation<double>? _voiceAnimation;

  @override
  void initState() {
    super.initState();

    ['LOCK', 'UNLOCK', 'START', 'STOP', 'ALARM', 'STARTER'].forEach((button) {
      buttonAnimations[button] = AnimationController(
        duration: Duration(milliseconds: 150),
        vsync: this,
      );
    });

    _audioPlayer = AudioPlayer();

    _adapterState = FlutterBluePlus.adapterStateNow;
    _btStateSub = FlutterBluePlus.adapterState.listen((s) {
      if (!mounted) return;
      setState(() {
        _adapterState = s;
      });
      if (s == BluetoothAdapterState.off) {
        _showSnackBar('يجب تفعيل البلوتوث أولاً', isSuccess: false, duration: 2);
      } else if (s == BluetoothAdapterState.on) {
        _attemptAutoConnectIfEligible();
      }
    });

    // تهيئة التحكم الصوتي
    _speech = stt.SpeechToText();
    _initSpeech();

    // تهيئة أنيميشن الصوت
    _voiceAnimationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    
    _voiceAnimation = Tween(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(
        parent: _voiceAnimationController!,
        curve: Curves.easeInOut,
      ),
    );

    requestPermissions();
    loadSavedCredentials();
    loadButtonStates();
  }

  // دالة تهيئة التعرف على الصوت
  void _initSpeech() async {
    bool available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done') {
          if (mounted) {
            setState(() {
              _isListening = false;
            });
          }
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {
            _isListening = false;
          });
          _showSnackBar('خطأ في التعرف على الصوت', isSuccess: false);
        }
      },
    );
    
    if (available && mounted) {
      setState(() {
        _voiceControlEnabled = true;
      });
    }
  }

  // دالة بدء الاستماع للصوت
  void _startListening() async {
    if (!_voiceControlEnabled) {
      _showSnackBar('التحكم الصوتي غير متاح', isSuccess: false);
      return;
    }

    if (!isConnected) {
      _showSnackBar('يجب الاتصال بالجهاز أولاً', isSuccess: false);
      return;
    }

    setState(() {
      _isListening = true;
      _lastWords = '';
    });

    await _speech.listen(
      onResult: (result) {
        setState(() {
          _lastWords = result.recognizedWords;
        });
        
        // معالجة الأوامر فور التعرف عليها
        if (result.finalResult) {
          _processVoiceCommand(_lastWords);
        }
      },
      listenFor: Duration(seconds: 7),
      pauseFor: Duration(seconds: 3),
      localeId: 'ar_SA', // استخدام اللغة العربية
    );
  }

  // دالة إيقاف الاستماع للصوت
  void _stopListening() async {
    await _speech.stop();
    setState(() {
      _isListening = false;
    });
    
    // معالجة الأمر إذا كان هناك نص معترف به
    if (_lastWords.isNotEmpty) {
      _processVoiceCommand(_lastWords);
    }
  }

  // دالة معالجة الأوامر الصوتية
  void _processVoiceCommand(String command) {
    String normalizedCommand = command.trim().toLowerCase();
    
    // أمر تشغيل الموتوسيكل (سلسلة الأوامر)
    if (normalizedCommand.contains('شغلي الموتسيكل') || 
        normalizedCommand.contains('دوري الموتسيكل') ||
        normalizedCommand.contains('شغل الموتسيكل') || 
        normalizedCommand.contains('دور الموتسيكل')) {
      
      _showSnackBar('جاري تنفيذ أمر التشغيل الصوتي', isSuccess: true);
      
      // تنفيذ سلسلة الأوامر مع تأخير بينها
      Future.delayed(Duration(milliseconds: 500), () {
        sendCommand('UNLOCK'); // فتح أولاً
        _showSnackBar('تم فتح النظام', isSuccess: true);
      });
      
      Future.delayed(Duration(milliseconds: 1500), () {
        sendCommand('START'); // ثم تشغيل
        _showSnackBar('تم تشغيل النظام', isSuccess: true);
      });
      
      Future.delayed(Duration(milliseconds: 2500), () {
        // الضغط على زر المارش لمدة 7 ثواني
        if (isEngineStarted) {
          _showSnackBar('جاري تشغيل المحرك (مارش)', isSuccess: true);
          sendStarterPress();
          Future.delayed(Duration(seconds: 7), () {
            sendStarterRelease();
            _showSnackBar('تم تشغيل المحرك بنجاح', isSuccess: true);
          });
        }
      });
    }
    // أمر إيقاف الموتوسيكل
    else if (normalizedCommand.contains('ايقاف الموتسيكل') || 
             normalizedCommand.contains('أوقف الموتسيكل') ||
             normalizedCommand.contains('اطفي الموتسيكل')) {
      
      _showSnackBar('جاري إيقاف المحرك', isSuccess: true);
      sendCommand('STOP');
    }
    // أمر قفل الموتوسيكل
    else if (normalizedCommand.contains('قفل الموتسيكل') || 
             normalizedCommand.contains('أقفل الموتسيكل')) {
      
      _showSnackBar('جاري قفل الموتوسيكل', isSuccess: true);
      sendCommand('LOCK');
    }
    // إذا لم يتعرف على الأمر
    else if (normalizedCommand.isNotEmpty) {
      _showSnackBar('لم أتعرف على الأمر: $command', isSuccess: false);
    }
  }

  // شريط الحالة أسفل العنوان
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
            color: Colors.black.withAlpha(51),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: btOn ? Color.fromARGB(38, 3, 169, 244) : Color.fromARGB(38, 244, 67, 54),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  btOn ? Icons.bluetooth : Icons.bluetooth_disabled,
                  color: btOn ? Colors.lightBlueAccent : Colors.redAccent,
                  size: 18,
                ),
                SizedBox(width: 6),
                Text(
                  btOn ? 'البلوتوث مفعل' : 'البلوتوث مغلق',
                  style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isConnected ? Color.fromARGB(38, 76, 175, 80) : Color.fromARGB(38, 244, 67, 54),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    isConnected ? Icons.link : Icons.link_off,
                    color: isConnected ? Colors.greenAccent : Colors.redAccent,
                    size: 18,
                  ),
                  SizedBox(width: 6),
                  Text(
                    isConnected ? 'متصل' : 'غير متصل',
                    style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                ),
                ],
              ),
            ),
          ),
          SizedBox(width: 8),
          if (!isConnected && !isConnecting)
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                minimumSize: Size(0, 0),
              ),
              onPressed: () {
                _playClickSound();
                _attemptAutoConnectIfEligible();
              },
              icon: Icon(Icons.refresh, size: 16, color: Colors.white),
              label: Text('إعادة المحاولة', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

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

  // واجهة زر التسجيل الصوتي
  Widget _buildVoiceControlButton() {
    return Column(
      children: [
        AnimatedBuilder(
          animation: _voiceAnimationController!,
          builder: (context, child) {
            return Transform.scale(
              scale: _isListening ? _voiceAnimation!.value : 1.0,
              child: FloatingActionButton(
                onPressed: () {
                  _playClickSound();
                  if (_isListening) {
                    _stopListening();
                  } else {
                    _startListening();
                  }
                },
                backgroundColor: _isListening ? Colors.red : Colors.blue,
                child: Icon(
                  _isListening ? Icons.mic : Icons.mic_none,
                  size: 30,
                ),
              ),
            );
          },
        ),
        SizedBox(height: 10),
        Text(
          _isListening ? 'جاري الاستماع...' : 'اضغط للتحدث',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
          ),
        ),
        if (_isListening && _lastWords.isNotEmpty)
          Container(
            margin: EdgeInsets.only(top: 10),
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Color.fromARGB(76, 0, 0, 0),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _lastWords,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool showControls = isBluetoothOn;

    return Scaffold(
      backgroundColor: Color(0xFF2C3E50),
      body: SafeArea(
        child: showControls
            ? Stack(
                children: [
                  SingleChildScrollView(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        // عنوان التطبيق + شريط الحالة الجديد أسفله
                        Column(
                          children: [
                            Text(
                              'MotoLock',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.3,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            _buildStatusStrip(),
                          ],
                        ),

                        SizedBox(height: 14),

                        if (!isConnected) ...[
                          Container(
                            height: 48,
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              border: Border.all(color: Color.fromARGB(76, 255, 255, 255)),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.bluetooth, color: Colors.blue, size: 20),
                                SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: macController,
                                    style: TextStyle(color: Colors.white, fontSize: 14),
                                    decoration: InputDecoration(
                                      hintText: 'عنوان MAC',
                                      hintStyle: TextStyle(
                                          color: Color.fromARGB(178, 255, 255, 255),
                                          fontSize: 14),
                                      border: InputBorder.none,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(Icons.save, color: Colors.white, size: 20),
                                  onPressed: () {
                                    _playClickSound();
                                    saveCredentials();
                                  },
                                  padding: EdgeInsets.all(8),
                                  constraints: BoxConstraints(minWidth: 40, minHeight: 40),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: 8),
                        ],

                        SizedBox(height: 10),

                        GestureDetector(
                          onTap: () {
                            _playClickSound();
                            _showInfoDialog();
                          },
                          child: Row(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.white, width: 1.5),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(Icons.info, color: Colors.white, size: 16),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'معلومات',
                                style: TextStyle(color: Colors.white, fontSize: 14),
                              ),
                              Spacer(),
                              TextButton.icon(
                                onPressed: () async {
                                  _playClickSound();
                                  await clearCredentials();
                                },
                                icon: Icon(Icons.delete_outline,
                                    color: Colors.redAccent, size: 18),
                                label: Text('مسح البيانات',
                                    style: TextStyle(
                                        color: Colors.redAccent, fontSize: 12)),
                                style: TextButton.styleFrom(
                                    padding: EdgeInsets.symmetric(horizontal: 8)),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: 10),

                        if (!isConnected) ...[
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: isScanning
                                      ? null
                                      : () {
                                          _playClickSound();
                                          scanForDevices();
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blue,
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (isScanning) ...[
                                        SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(width: 8),
                                      ],
                                      Icon(Icons.search, color: Colors.white, size: 20),
                                    ],
                                  ),
                                ),
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: isConnecting
                                      ? null
                                      : () {
                                          _playClickSound();
                                          connectToDevice();
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (isConnecting) ...[
                                        SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(width: 8),
                                      ],
                                      Icon(Icons.link, color: Colors.white, size: 20),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ] else ...[
                          Row(
                            children: [
                              Spacer(),
                              SizedBox(
                                width: 160,
                                child: ElevatedButton(
                                  onPressed: isConnecting
                                      ? null
                                      : () {
                                          _playClickSound();
                                          disconnect();
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  child: Icon(Icons.link_off,
                                      color: Colors.white, size: 22),
                                ),
                              ),
                              Spacer(),
                            ],
                          ),
                        ],
                        SizedBox(height: 18),

                        Container(
                          height: MediaQuery.of(context).size.height * 0.48,
                          clipBehavior: Clip.none,
                          child: GridView.count(
                            crossAxisCount: 2,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 1.4,
                            clipBehavior: Clip.none,
                            physics: NeverScrollableScrollPhysics(),
                            children: [
                              _buildControlButton(
                                color: Colors.red,
                                icon: Icons.lock,
                                text: 'قفل',
                                command: 'LOCK',
                                isActive: isLocked,
                              ),
                              _buildControlButton(
                                color: Colors.green,
                                icon: Icons.lock_open,
                                text: 'فتح',
                                command: 'UNLOCK',
                                isActive: !isLocked,
                              ),
                              _buildControlButton(
                                color: Colors.blue,
                                icon: Icons.power_settings_new,
                                text: 'تشغيل',
                                command: 'START',
                                isActive: isEngineStarted,
                              ),
                              _buildControlButton(
                                color: Colors.orange,
                                icon: Icons.stop,
                                text: 'إيقاف',
                                command: 'STOP',
                                isActive: isStopIndicatorActive,
                              ),
                              _buildControlButton(
                                color: Colors.purple,
                                icon: Icons.notifications,
                                text: 'إنذار',
                                command: 'ALARM',
                                isActive: isAlarmActive,
                              ),
                              _buildStarterButton(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  // وضع زر التسجيل في الزاوية اليسرى السفلية
                  Positioned(
                    bottom: 20,
                    left: 20,
                    child: _buildVoiceControlButton(),
                  ),
                ],
              )
            : _buildBluetoothOffView(),
      ),
    );
  }

  Widget _buildBluetoothOffView() {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bluetooth_disabled, color: Colors.white70, size: 64),
            SizedBox(height: 16),
            Text(
              'البلوتوث غير مفعل',
              style: TextStyle(color: Colors.white, fontSize: 18),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              'تحتاج إلى تفعيل البلوتوث أولاً لاستخدام التطبيق',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 20),
            SizedBox(
              width: 200,
              child: ElevatedButton.icon(
                onPressed: () async {
                  _playClickSound();
                  try {
                    await FlutterBluePlus.turnOn();
                  } catch (e) {
                    _showSnackBar('تعذّر فتح تفعيل البلوتوث', isSuccess: false, duration: 2);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  padding: EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: Icon(Icons.bluetooth, color: Colors.white),
                label: Text('تفعيل البلوتوث', style: TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required Color color,
    required IconData icon,
    required String text,
    required String command,
    bool isActive = false,
  }) {
    return AnimatedBuilder(
      animation: buttonAnimations[command]!,
      builder: (context, child) {
        double scale = 1.0 + (buttonAnimations[command]!.value * 0.05);
        Color currentColor = Color.lerp(
          color,
          color.withValues(alpha: 0.7),
          buttonAnimations[command]!.value,
        )!;

        return Transform.scale(
          scale: scale,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => sendCommand(command),
            child: Container(
              decoration: BoxDecoration(
                color: currentColor,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.3),
                    blurRadius: 6,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  if (isActive)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.amber,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black26,
                              blurRadius: 2,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(icon, color: Colors.white, size: 28),
                        SizedBox(height: 8),
                        Text(
                          text,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStarterButton() {
    return AnimatedBuilder(
      animation: buttonAnimations['STARTER']!,
      builder: (context, child) {
        double scale = 1.0 + (buttonAnimations['STARTER']!.value * 0.05);
        Color baseColor = Colors.indigo;
        Color currentColor = isStarterPressed
            ? baseColor.withValues(alpha: 0.6)
            : Color.lerp(
                baseColor,
                baseColor.withValues(alpha: 0.7),
                buttonAnimations['STARTER']!.value,
              )!;

        return Transform.scale(
          scale: scale,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (_) {
              if (isEngineStarted) {
                _playButtonAnimation('STARTER');
                _playClickSound(isCritical: true);
                sendStarterPress();
              } else {
                _playClickSound();
                _showSnackBar('يجب تفعيل زر التشغيل أولاً', isSuccess: false, duration: 2);
              }
            },
            onLongPressEnd: (_) {
              if (isStarterPressed) {
                sendStarterRelease();
              }
            },
            onTap: () {
              if (!isEngineStarted) {
                _playClickSound();
                _showSnackBar('يجب تفعيل زر التشغيل أولاً', isSuccess: false, duration: 2);
              }
            },
            child: Container(
              decoration: BoxDecoration(
                color: currentColor,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: currentColor.withValues(alpha: 0.3),
                    blurRadius: 6,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.flash_on,
                      color: isStarterPressed ? Colors.amber : Colors.white,
                      size: 28,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'مارش',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Color(0xFF34495E),
          title: Text(
            'معلومات التطبيق',
            style: TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow('الإصدار:', '2.0.0'),
              _buildInfoRow('المطور:', 'MotoLock Team'),
              _buildInfoRow('البروتوكول:', 'Bluetooth BLE'),
              _buildInfoRow('الأطراف:', '12,14,25,26,27'),
              SizedBox(height: 12),
              Text(
                'التطبيق للتحكم المتقدم في الدراجة النارية\n- قفل/فتح: PIN 25\n- تشغيل: PIN 26\n- إيقاف: PIN 27 (10 ثواني)\n- إنذار: PIN 14 (وميض)\n- مارش: PIN 12 (ضغط مطول)',
                style: TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.right,
              ),
              SizedBox(height: 12),
              Text(
                'الأوامر الصوتية المدعومة:\n- "شغلي الموتسيكل" أو "دوري الموتسيكل"\n- "أوقف الموتسيكل"\n- "أقفل الموتسيكل"',
                style: TextStyle(color: Colors.blueAccent, fontSize: 14),
                textAlign: TextAlign.right,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _playClickSound();
                Navigator.of(context).pop();
              },
              child: Text(
                'موافق',
                style: TextStyle(color: Colors.blue),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: Colors.white70, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    buttonAnimations.values.forEach((controller) {
      controller.dispose();
    });
    _scanSub?.cancel();
    _valueSub?.cancel();
    _btStateSub?.cancel();
    _audioPlayer.dispose();
    _stopIndicatorTimer?.cancel();
    _engineStopDelayTimer?.cancel();
    _speech.stop();
    _voiceCommandTimer?.cancel();
    _voiceAnimationController?.dispose();
    if (connectedDevice != null) {
      try { connectedDevice!.disconnect(); } catch (_) {}
    }
    super.dispose();
  }
}