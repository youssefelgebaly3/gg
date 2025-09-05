import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'dart:async';
import 'dart:convert';

// This file contains the remaining methods for the MotoLock app
// These methods will be mixed into the main state class

mixin MotoLockMethods<T extends StatefulWidget> on State<T> {
  // State variables that need to be defined in the main class
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? writeCharacteristic;
  BluetoothCharacteristic? notifyCharacteristic;
  bool isConnected = false;
  bool isConnecting = false;
  bool isScanning = false;
  bool shouldAutoConnect = false;
  bool isLocked = false;
  TextEditingController macController = TextEditingController();
  List<BluetoothDevice> foundDevices = [];
  List<ScanResult> scanResults = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothAdapterState>? _btStateSub;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  Map<String, AnimationController> buttonAnimations = {};
  late AudioPlayer _audioPlayer;
  bool isStarterPressed = false;
  bool isAlarmActive = false;
  bool isEngineStarted = false;
  bool isStopIndicatorActive = false;
  Timer? _stopIndicatorTimer;
  Timer? _engineStopDelayTimer;
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _lastWords = '';
  bool _voiceControlEnabled = false;
  Timer? _voiceCommandTimer;
  AnimationController? _voiceAnimationController;
  Animation<double>? _voiceAnimation;

  bool get isBluetoothOn => _adapterState == BluetoothAdapterState.on;

  Future<void> loadButtonStates() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      isLocked = prefs.getBool('is_locked') ?? false;
      isAlarmActive = prefs.getBool('is_alarm_active') ?? false;
      isEngineStarted = prefs.getBool('is_engine_started') ?? false;
    });
  }

  Future<void> saveButtonStates() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_locked', isLocked);
    await prefs.setBool('is_alarm_active', isAlarmActive);
    await prefs.setBool('is_engine_started', isEngineStarted);
  }

  Future<void> loadSavedCredentials() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      macController.text = prefs.getString('saved_mac') ?? '';
      shouldAutoConnect = prefs.getBool('should_auto_connect') ?? false;
    });
    _attemptAutoConnectIfEligible();
  }

  Future<void> saveCredentials() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_mac', macController.text);
    _showSnackBar('تم حفظ البيانات', isSuccess: true);
  }

  Future<void> requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
      Permission.microphone, // إضافة صلاحية الميكروفون للتحكم الصوتي
    ].request();
  }

  Future<void> scanForDevices() async {
    if (!isBluetoothOn) {
      _showSnackBar('يجب تفعيل البلوتوث أولاً', isSuccess: false, duration: 2);
      return;
    }

    setState(() {
      isScanning = true;
      foundDevices.clear();
      scanResults.clear();
    });

    try {
      List<BluetoothDevice> bondedDevices = await FlutterBluePlus.bondedDevices;
      setState(() {
        foundDevices.addAll(bondedDevices);
      });

      await FlutterBluePlus.startScan(timeout: Duration(seconds: 8));

      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        setState(() {
          scanResults = results;

          for (var result in results) {
            if (!foundDevices.any((d) => d.remoteId == result.device.remoteId)) {
              foundDevices.add(result.device);
            }
          }

          final Map<DeviceIdentifier, int> rssiById = {
            for (final r in results) r.device.remoteId: r.rssi
          };

          foundDevices.sort((a, b) {
            final rb = rssiById[b.remoteId] ?? -999;
            final ra = rssiById[a.remoteId] ?? -999;
            return rb.compareTo(ra);
          });
        });
      });

      await _showScanBottomSheet();

      await Future.delayed(Duration(seconds: 8));
      await FlutterBluePlus.stopScan();
      await _scanSub?.cancel();
      _scanSub = null;
    } catch (e) {
      _showSnackBar('فشل في البحث عن الأجهزة', isSuccess: false);
    }

    setState(() {
      isScanning = false;
    });
  }

  Future<void> clearCredentials() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_mac');
    await prefs.remove('should_auto_connect');
    await prefs.remove('is_locked');
    await prefs.remove('is_alarm_active');
    await prefs.remove('is_engine_started');
    setState(() {
      macController.clear();
      shouldAutoConnect = false;
      isLocked = false;
      isAlarmActive = false;
      isEngineStarted = false;
      isStopIndicatorActive = false;
    });
    _showSnackBar('تم مسح البيانات المحفوظة', isSuccess: true);
  }

  Future<void> _showScanBottomSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Color(0xFF34495E),
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'الأجهزة المتاحة',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold),
                    ),
                    if (isScanning)
                      Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.blue),
                          ),
                          SizedBox(width: 8),
                          Text('جاري البحث...',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 14)),
                        ],
                      ),
                  ],
                ),
                SizedBox(height: 10),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.5,
                  ),
                  child: foundDevices.isEmpty
                      ? Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Text('لا توجد أجهزة حتى الآن',
                                style: TextStyle(color: Colors.white70)),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: foundDevices.length,
                          separatorBuilder: (_, __) =>
                              Divider(color: Colors.white24, height: 1),
                          itemBuilder: (context, index) {
                            final device = foundDevices[index];
                            final deviceName = device.platformName.isNotEmpty
                                ? device.platformName
                                : 'جهاز غير معروف';
                            return ListTile(
                              dense: true,
                              title: Text(deviceName,
                                  style: TextStyle(color: Colors.white)),
                              subtitle: Text(device.remoteId.toString(),
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 14)),
                              onTap: () async {
                                _playClickSound();
                                macController.text = device.remoteId.toString();
                                try {
                                  await FlutterBluePlus.stopScan();
                                } catch (_) {}
                                if (Navigator.of(context).canPop())
                                  Navigator.of(context).pop();
                              },
                            );
                          },
                        ),
                ),
                SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () async {
                          _playClickSound();
                          try {
                            await FlutterBluePlus.stopScan();
                          } catch (_) {}
                          if (Navigator.of(context).canPop())
                            Navigator.of(context).pop();
                        },
                        child:
                            Text('إغلاق', style: TextStyle(color: Colors.blue)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> connectToDevice() async {
    if (!isBluetoothOn) {
      _showSnackBar('يجب تفعيل البلوتوث أولاً', isSuccess: false, duration: 2);
      return;
    }

    if (macController.text.isEmpty) {
      _showSnackBar('يرجى إدخال MAC Address', isSuccess: false);
      return;
    }

    setState(() {
      isConnecting = true;
    });

    try {
      BluetoothDevice? targetDevice;
      String targetMac = macController.text.toUpperCase().replaceAll(':', '');

      for (var device in foundDevices) {
        String deviceMac =
            device.remoteId.toString().toUpperCase().replaceAll(':', '');
        if (deviceMac == targetMac) {
          targetDevice = device;
          break;
        }
      }

      if (targetDevice == null) {
        targetDevice = BluetoothDevice.fromId(macController.text);
      }

      await targetDevice.connect(timeout: Duration(seconds: 15));
      List<BluetoothService> services = await targetDevice.discoverServices();

      BluetoothCharacteristic? writeChar;
      BluetoothCharacteristic? notifyChar;

      for (BluetoothService service in services) {
        for (BluetoothCharacteristic char in service.characteristics) {
          if (char.properties.write || char.properties.writeWithoutResponse) {
            writeChar = char;
          }
          if (char.properties.notify) {
            notifyChar = char;
          }
        }
        if (writeChar != null && notifyChar != null) break;
      }

      if (writeChar != null && notifyChar != null) {
        await notifyChar.setNotifyValue(true);

        _valueSub?.cancel();
        _valueSub = notifyChar.lastValueStream.listen((value) {
          if (value.isNotEmpty) {
            String response = utf8.decode(value);
            _handleDeviceResponse(response);
          }
        });

        setState(() {
          connectedDevice = targetDevice;
          writeCharacteristic = writeChar;
          notifyCharacteristic = notifyChar;
          isConnected = true;
          isConnecting = false;
        });

        await saveCredentials();
        await (await SharedPreferences.getInstance())
            .setBool('should_auto_connect', true);
        _playConnectionSound(isSuccess: true);
        _showSnackBar('تم الاتصال بنجاح', isSuccess: true);
      } else {
        throw Exception('لم يتم العثور على خصائص مناسبة');
      }
    } catch (e) {
      setState(() {
        isConnecting = false;
      });
      _playConnectionSound(isSuccess: false);

      String errorMessage = 'فشل في الاتصال';
      if (e.toString().toLowerCase().contains('bluetooth must be turned on')) {
        errorMessage = 'يجب تفعيل البلوتوث';
      } else if (e.toString().toLowerCase().contains('timeout') ||
          e.toString().toLowerCase().contains('time out')) {
        errorMessage = 'فشل في الاتصال - تأكد من قرب الجهاز';
      }
      _showSnackBar(errorMessage, isSuccess: false);
    }
  }

  void _handleDeviceResponse(String response) {
    response = response.trim();
    if (response == 'START_ENGINE_FIRST') {
      _showSnackBar('يجب الضغط على زر التشغيل أولاً', isSuccess: false, duration: 2);
    } else if (response == 'ENGINE_STOPPING') {
      setState(() { isStopIndicatorActive = true; });
    } else if (response == 'ENGINE_STOPPED') {
      _showSnackBar('تم إيقاف المحرك نهائياً', isSuccess: true, duration: 2);
      setState(() {
        isEngineStarted = false;
        isStopIndicatorActive = false;
      });
      saveButtonStates();
    } else if (response == 'LOCKED') {
      setState(() { isLocked = true; });
      saveButtonStates();
    } else if (response == 'UNLOCKED') {
      setState(() { isLocked = false; });
      saveButtonStates();
    }
  }

  Future<void> disconnect() async {
    bool? shouldDisconnect = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Color(0xFF34495E),
          title: Text(
            'تأكيد قطع الاتصال',
            style: TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
          content: Text(
            'هل أنت متأكد من قطع الاتصال مع الجهاز؟',
            style: TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          actions: [
            TextButton(
              onPressed: () {
                _playClickSound();
                Navigator.of(context).pop(false);
              },
              child: Text('إلغاء', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                _playClickSound();
                Navigator.of(context).pop(true);
              },
              child: Text('قطع الاتصال', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );

    if (shouldDisconnect == true) {
      if (connectedDevice != null) {
        try {
          await connectedDevice!.disconnect();
        } catch (_) {}
        setState(() {
          isConnected = false;
          connectedDevice = null;
          writeCharacteristic = null;
          notifyCharacteristic = null;
          isLocked = false;
          isStopIndicatorActive = false;
        });
        _valueSub?.cancel();
        _valueSub = null;
        _stopIndicatorTimer?.cancel();
        _engineStopDelayTimer?.cancel();
        _playConnectionSound(isSuccess: false);
        _showSnackBar('تم قطع الاتصال', isSuccess: true);
      }
    }
  }

  Future<void> sendCommand(String command) async {
    if (isLocked && (command == 'START' || command == 'STOP')) {
      _showSnackBar('يجب الضغط على زر فتح اولا', isSuccess: false, duration: 2);
      return;
    }
    if (!isBluetoothOn) {
      _showSnackBar('يجب تفعيل البلوتوث أولاً', isSuccess: false, duration: 2);
      return;
    }

    _playButtonAnimation(command);
    _playClickSound(isCritical: ['LOCK', 'UNLOCK', 'START', 'STOP'].contains(command));

    if (command == 'LOCK') {
      _showSnackBar('تم بنجاح تم تفعيل الوضع الامن ضد السرقة', isSuccess: true, duration: 2);
      setState(() {
        isLocked = true;
        isEngineStarted = false;
        isStopIndicatorActive = false;
      });
      _stopIndicatorTimer?.cancel();
      _engineStopDelayTimer?.cancel();
      saveButtonStates();
      if (writeCharacteristic != null && isConnected) {
        try { await writeCharacteristic!.write(utf8.encode('STOP')); } catch (_) {}
      }
    } else if (command == 'UNLOCK') {
      _showSnackBar('تم بنجاح تم الغاء الوضع الامن ضد السرقة', isSuccess: true, duration: 2);
      setState(() {
        isLocked = false;
      });
      saveButtonStates();
    } else if (command == 'START') {
      _showSnackBar('تم بنجاح تم فتح الكونتاكت', isSuccess: true, duration: 2);
      setState(() {
        isEngineStarted = true;
        isStopIndicatorActive = false;
      });
      _stopIndicatorTimer?.cancel();
      _engineStopDelayTimer?.cancel();
      saveButtonStates();
    } else if (command == 'STOP') {
      _showSnackBar('تم بنجاح جاري... إطفاء المحرك', isSuccess: true, duration: 2);
      setState(() { isStopIndicatorActive = true; });

      _stopIndicatorTimer?.cancel();
      _stopIndicatorTimer = Timer(Duration(seconds: 10), () {
        if (mounted) {
          setState(() { isStopIndicatorActive = false; });
        }
      });

      _engineStopDelayTimer?.cancel();
      _engineStopDelayTimer = Timer(Duration(seconds: 1), () {
        if (mounted) {
          setState(() { isEngineStarted = false; });
          saveButtonStates();
        }
      });
    } else if (command == 'ALARM') {
      setState(() { isAlarmActive = !isAlarmActive; });
      _showSnackBar(
        isAlarmActive ? 'تم بنجاح تفعيل وضع الانذار' : 'تم بنجاح الغاء وضع الانذار',
        isSuccess: true,
        duration: 2,
      );
      saveButtonStates();
    }

    if (writeCharacteristic != null && isConnected) {
      try {
        await writeCharacteristic!.write(utf8.encode(command));
      } catch (e) {
        _showSnackBar('فشل في إرسال الأمر', isSuccess: false, duration: 2);
      }
    } else {
      _showSnackBar('غير متصل بالجهاز', isSuccess: false, duration: 2);
    }
  }

  Future<void> sendStarterPress() async {
    if (!isEngineStarted) {
      _showSnackBar('يجب تفعيل زر التشغيل أولاً', isSuccess: false, duration: 2);
      return;
    }
    if (!isBluetoothOn) {
      _showSnackBar('يجب تفعيل البلوتوث أولاً', isSuccess: false, duration: 2);
      return;
    }

    if (writeCharacteristic != null && isConnected) {
      try {
        await writeCharacteristic!.write(utf8.encode('STARTER_PRESS'));
        setState(() {
          isStarterPressed = true;
        });
        _showSnackBar('تم بنجاح يتم تشغيل المحرك الآن', isSuccess: true, duration: 2);
      } catch (e) {
        _showSnackBar('فشل في إرسال الأمر', isSuccess: false, duration: 2);
      }
    } else {
      _showSnackBar('غير متصل بالجهاز', isSuccess: false, duration: 2);
    }
  }

  Future<void> sendStarterRelease() async {
    if (writeCharacteristic != null && isConnected) {
      try {
        await writeCharacteristic!.write(utf8.encode('STARTER_RELEASE'));
        setState(() {
          isStarterPressed = false;
        });
      } catch (e) {
        _showSnackBar('فشل في إرسال الأمر', isSuccess: false, duration: 2);
      }
    }
  }

  void _playButtonAnimation(String buttonKey) {
    if (buttonAnimations[buttonKey] != null) {
      buttonAnimations[buttonKey]!.forward().then((_) {
        buttonAnimations[buttonKey]!.reverse();
      });
    }
  }

  void _playClickSound({bool isCritical = false}) {
    if (isCritical) {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
    try {
      _audioPlayer.play(AssetSource('sounds/button_click.mp3'));
    } catch (e) {
      SystemSound.play(SystemSoundType.click);
    }
  }

  void _playConnectionSound({bool isSuccess = true}) {
    HapticFeedback.lightImpact();
    try {
      if (isSuccess) {
        SystemSound.play(SystemSoundType.alert);
      } else {
        SystemSound.play(SystemSoundType.click);
      }
    } catch (e) {
      SystemSound.play(SystemSoundType.click);
    }
  }

  void _showSnackBar(String message, {bool isSuccess = true, int duration = 2}) {
    final snackBar = SnackBar(
      content: Directionality(
        textDirection: TextDirection.rtl,
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(
                isSuccess ? Icons.check_circle : Icons.error_outline,
                color: Colors.white,
                size: 22,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 14),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
      backgroundColor: isSuccess ? Color(0xFF2E7D32) : Color(0xFFC62828),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      margin: EdgeInsets.fromLTRB(16, 0, 16, 40),
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      duration: Duration(seconds: duration),
      elevation: 4,
    );

    ScaffoldMessenger.of(context).showSnackBar(snackBar);
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
}