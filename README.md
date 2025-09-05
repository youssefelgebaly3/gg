# MotoLock - Flutter Motorcycle Control App

A Flutter application for controlling a motorcycle via Bluetooth with voice commands support.

## Features

- **Bluetooth Control**: Connect to motorcycle via Bluetooth Low Energy (BLE)
- **Voice Commands**: Control the motorcycle using Arabic voice commands
- **Motorcycle Controls**:
  - Lock/Unlock (PIN 25)
  - Start/Stop Engine (PIN 26/27)
  - Alarm System (PIN 14)
  - Starter (PIN 12) - Long press to activate
- **Auto-connect**: Automatically reconnect to saved devices
- **Status Indicators**: Real-time status display
- **Arabic UI**: Full Arabic language support

## Voice Commands

The app supports the following Arabic voice commands:
- "شغلي الموتسيكل" or "دوري الموتسيكل" - Start motorcycle (unlock → start → starter)
- "أوقف الموتسيكل" or "اطفي الموتسيكل" - Stop motorcycle
- "أقفل الموتسيكل" - Lock motorcycle

## Dependencies

The project uses the following key dependencies:
- `flutter_blue_plus: ^1.35.7` - Bluetooth connectivity
- `speech_to_text: ^7.3.0` - Voice recognition
- `permission_handler: ^12.0.1` - Android permissions
- `shared_preferences: ^2.2.2` - Local storage
- `audioplayers: ^6.5.1` - Audio feedback

## Setup Instructions

1. **Install Flutter**: Make sure you have Flutter SDK installed and configured
2. **Clone/Download**: Get the project files
3. **Install Dependencies**: Run `flutter pub get`
4. **Android Setup**: The Android configuration is already set up with required permissions
5. **Run**: Use `flutter run` to build and run the app

## Android Permissions

The app requires the following permissions (already configured):
- `BLUETOOTH` - Basic Bluetooth access
- `BLUETOOTH_CONNECT` - Connect to Bluetooth devices
- `BLUETOOTH_SCAN` - Scan for Bluetooth devices
- `ACCESS_FINE_LOCATION` - Required for Bluetooth scanning
- `RECORD_AUDIO` - Required for voice commands

## Hardware Requirements

- Android device with Bluetooth 4.0+ (BLE support)
- Motorcycle with compatible Bluetooth module
- Microphone access for voice commands

## Usage

1. **Enable Bluetooth**: Make sure Bluetooth is enabled on your device
2. **Connect**: Enter the MAC address of your motorcycle's Bluetooth module
3. **Control**: Use the on-screen buttons or voice commands to control the motorcycle
4. **Voice Control**: Tap the microphone button and speak commands in Arabic

## Troubleshooting

### Build Issues
If you encounter build issues with `speech_to_text`:
- The project uses `speech_to_text: ^7.3.0` which is compatible with newer Flutter versions
- Make sure you're using Flutter 3.0+ and Android API 21+

### Bluetooth Issues
- Ensure Bluetooth is enabled
- Check that the motorcycle's Bluetooth module is in pairing mode
- Verify the MAC address is correct

### Voice Recognition Issues
- Grant microphone permission when prompted
- Speak clearly in Arabic
- Ensure good microphone quality

## Project Structure

```
lib/
├── main.dart              # App entry point
├── moto_lock_home.dart    # Main UI and state management
└── moto_lock_methods.dart # Business logic and Bluetooth methods
```

## Version

- **Current Version**: 2.0.0
- **Flutter SDK**: 3.0+
- **Android API**: 21+

## License

This project is for educational and personal use. Please ensure you have proper authorization before controlling any vehicle systems.