import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/page/settings_page/chksz_credential_settings.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';

const _apiKey = 'chksz_SETTINGS_TEST_ONLY';

void main() {
  testWidgets('reads lazily when the online music tab becomes active', (
    tester,
  ) async {
    final provider = _FakeCredentialProvider();

    await tester.pumpWidget(_host(provider, active: false));
    expect(provider.readCount, 0);

    await tester.pumpWidget(_host(provider, active: true));
    await tester.pump();

    expect(provider.readCount, 1);
    expect(find.textContaining('未配置'), findsOneWidget);
  });

  testWidgets('shows configured state without exposing the key', (
    tester,
  ) async {
    final provider = _FakeCredentialProvider(value: _apiKey);

    await tester.pumpWidget(_host(provider));
    await tester.pump();

    expect(find.textContaining('已配置'), findsOneWidget);
    expect(find.textContaining(_apiKey), findsNothing);
  });

  testWidgets('validates, obscures, and saves a new key', (tester) async {
    final provider = _FakeCredentialProvider();

    await tester.pumpWidget(_host(provider));
    await tester.pump();
    await tester.tap(find.text('配置'));
    await tester.pump();

    final field = find.byType(TextField);
    await tester.enterText(field, 'invalid key');
    await tester.pump();
    expect(
      tester.widget<TextField>(field).decoration?.errorText,
      'API Key 格式无效',
    );
    final invalidSave = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存'),
    );
    expect(invalidSave.onPressed, isNull);

    await tester.tap(find.byTooltip('显示 API Key'));
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isFalse);

    await tester.enterText(field, _apiKey);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(provider.value, _apiKey);
    expect(find.textContaining('已配置'), findsOneWidget);
  });

  testWidgets('requires confirmation before clearing the key', (tester) async {
    final provider = _FakeCredentialProvider(value: _apiKey);

    await tester.pumpWidget(_host(provider));
    await tester.pump();
    await tester.tap(find.byTooltip('清除 API Key'));
    await tester.pump();

    expect(find.text('清除 ChKSz API Key？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '清除'));
    await tester.pumpAndSettle();

    expect(provider.value, isNull);
    expect(find.textContaining('未配置'), findsOneWidget);
  });

  testWidgets('keeps storage failures safe and inside the dialog', (
    tester,
  ) async {
    final provider = _FakeCredentialProvider(
      writeError: const ChkszCredentialStorageException(
        operation: ChkszCredentialStorageOperation.write,
        errorCode: 5,
      ),
    );

    await tester.pumpWidget(_host(provider));
    await tester.pump();
    await tester.tap(find.text('配置'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), _apiKey);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final errorText = tester
        .widget<TextField>(find.byType(TextField))
        .decoration
        ?.errorText;
    expect(errorText, '无法安全保存 ChKSz API Key');
    expect(errorText, isNot(contains(_apiKey)));
  });
}

Widget _host(_FakeCredentialProvider provider, {bool active = true}) {
  return MaterialApp(
    home: Scaffold(
      body: Provider<ChkszCredentialProvider>.value(
        value: provider,
        child: ChkszCredentialSettings(active: active),
      ),
    ),
  );
}

final class _FakeCredentialProvider implements ChkszCredentialProvider {
  _FakeCredentialProvider({this.value, this.writeError});

  String? value;
  final Object? writeError;
  int readCount = 0;

  @override
  Future<String?> readApiKey() async {
    readCount++;
    return value;
  }

  @override
  Future<void> writeApiKey(String apiKey) async {
    final error = writeError;
    if (error != null) throw error;
    value = apiKey;
  }

  @override
  Future<void> clearApiKey() async {
    value = null;
  }
}
