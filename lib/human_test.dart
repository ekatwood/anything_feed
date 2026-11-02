import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HumanTestDialog extends StatefulWidget {
  final VoidCallback onSuccess;
  const HumanTestDialog({Key? key, required this.onSuccess}) : super(key: key);

  static Future<bool> isVerified() async {
    final prefs = await SharedPreferences.getInstance();
    final verifiedTime = prefs.getInt('human_verified_timestamp') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Valid for 2 hours (7,200,000 milliseconds)
    if (now - verifiedTime < 7200000) {
      return true;
    }
    return false;
  }

  @override
  State<HumanTestDialog> createState() => _HumanTestDialogState();
}

class _HumanTestDialogState extends State<HumanTestDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _error = false;
  final int num1 = 5;
  final int num2 = 3;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Human Verification'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Please solve this quick math problem to continue:'),
          const SizedBox(height: 16),
          Text('What is $num1 + $num2?', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Answer',
              errorText: _error ? 'Incorrect answer. Try again.' : null,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () async {
            final val = int.tryParse(_controller.text.trim());
            if (val == (num1 + num2)) {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setInt('human_verified_timestamp', DateTime.now().millisecondsSinceEpoch);
              Navigator.of(context).pop(true);
              widget.onSuccess();
            } else {
              setState(() {
                _error = true;
              });
            }
          },
          child: const Text('Verify'),
        ),
      ],
    );
  }
}