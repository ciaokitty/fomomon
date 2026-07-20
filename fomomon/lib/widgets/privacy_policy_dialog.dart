import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:http/http.dart' as http;

class PrivacyPolicyDialog extends StatefulWidget {
  const PrivacyPolicyDialog({super.key});

  @override
  State<PrivacyPolicyDialog> createState() => _PrivacyPolicyDialogState();
}

class _PrivacyPolicyDialogState extends State<PrivacyPolicyDialog> {
  String _privacyPolicyText = 'Loading...';

  @override
  void initState() {
    super.initState();
    _loadPrivacyPolicy();
  }

  Future<void> _loadPrivacyPolicy() async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://gist.githubusercontent.com/bprashanth/c639d42182d3270488f3445e9eae18ba/raw/00de2529c1831676d9976a3b2ce3a1a4362e558d/fomomon_privacy_policy.md',
        ),
      );

      if (response.statusCode == 200) {
        setState(() {
          _privacyPolicyText = response.body;
        });
      } else {
        setState(() {
          _privacyPolicyText =
              'Error loading privacy policy. Please visit our website.';
        });
      }
    } catch (e) {
      setState(() {
        _privacyPolicyText =
            'Error loading privacy policy. Please visit our website.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Privacy Policy',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                child: MarkdownBody(
                  data: _privacyPolicyText,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(
                    Theme.of(context),
                  ).copyWith(
                    p: const TextStyle(fontSize: 14),
                    h1: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    h2: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    h3: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Helper function to show privacy policy dialog
void showPrivacyPolicy(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => const PrivacyPolicyDialog(),
  );
}
