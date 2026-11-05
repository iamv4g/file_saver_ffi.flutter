import 'package:flutter/material.dart';

import 'open_write_screen.dart';
import 'path_location_screen.dart';
import 'save_as_screen.dart';
import 'save_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('File Saver FFI Demo')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SaveApiButton(
                  label: 'Save API',
                  screenWidget: const SaveScreen(),
                ),
                const SizedBox(height: 12),
                _SaveApiButton(
                  label: 'Save As API',
                  screenWidget: const SaveAsScreen(),
                ),
                const SizedBox(height: 12),
                _SaveApiButton(
                  label: 'Open Write API (Session)',
                  screenWidget: const OpenWriteScreen(),
                ),
                const SizedBox(height: 12),
                _SaveApiButton(
                  label: 'PathLocation (Custom Path)',
                  screenWidget: const PathLocationScreen(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SaveApiButton extends StatelessWidget {
  const _SaveApiButton({required this.label, required this.screenWidget});

  final String label;
  final Widget screenWidget;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: () {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => screenWidget));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Text(label),
      ),
    );
  }
}
