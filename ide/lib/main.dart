import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = IdeState();
  await state.init();
  runApp(RainbowApp(state: state));
}

class RainbowApp extends StatelessWidget {
  const RainbowApp({super.key, required this.state});

  final IdeState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rainbow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF16161E),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: Colors.white70),
        ),
      ),
      home: Shell(state: state),
    );
  }
}
