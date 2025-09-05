import 'package:flutter/material.dart';
import 'moto_lock_home.dart';

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