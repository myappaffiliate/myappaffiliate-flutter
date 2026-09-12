// The whole integration, in one file: configure at launch, attribute an
// incoming link, identify the user, then hand the affiliate id to your billing
// layer before the purchase.
import 'package:flutter/material.dart';
import 'package:myappaffiliate_flutter/myappaffiliate_flutter.dart';

void main() {
  MyAppAffiliate.configure(
    apiKey: const String.fromEnvironment('MAA_SDK_KEY'),
    baseUrl: 'https://api.myappaffiliate.com',
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: HomePage());
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _affiliateId;

  Future<void> _applyCode() async {
    // A creator's code, typed into a field. Works with no deep link at all.
    await MyAppAffiliate.applyCode('LUMI');
    // Bind your user id — the SAME one your billing provider will report.
    await MyAppAffiliate.identify('user_123');
    final affiliateId = await MyAppAffiliate.attributedAffiliateId();
    if (mounted) setState(() => _affiliateId = affiliateId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_affiliateId == null
                ? 'Not attributed'
                : 'Attributed to $_affiliateId'),
            TextButton(onPressed: _applyCode, child: const Text('Apply code')),
          ],
        ),
      ),
    );
  }
}
