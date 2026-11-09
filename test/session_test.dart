import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/chatgpt/chatgpt_plan.dart';
import 'package:langchain_core/chat_models.dart';

Map<String, dynamic> record(String name, {bool expired = true}) => {
  'client_id': 'opaque-$name',
  'subject': name,
  'email': '$name@example.test',
  'access_token': 'old-access-$name',
  'refresh_token': 'old-refresh-$name',
  'id_token': 'not-a-real-token',
  'scopes': ['chatgpt.tokens.use.direct'],
  'expires_at':
      DateTime.now().millisecondsSinceEpoch + (expired ? -1000 : 999999),
  'model': 'catalog-model-$name',
};
Map<String, dynamic> rotated(String name) => {
  'access_token': 'new-access-$name',
  'refresh_token': 'new-refresh-$name',
  'token_type': 'Bearer',
  'expires_in': 3600,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'malformed protected credentials fail closed in memory without deleting the record',
    () async {
      final corrupted = jsonEncode({
        'enabled': true,
        'active_id': 'old',
        'accounts': [
          {'client_id': 'x', 'subject': null},
        ],
      });
      var reads = 0;
      final plan = ChatGptPlan.testProtectedStore(() async {
        reads++;
        return corrupted;
      });
      await expectLater(plan.initialize(), throwsA(anything));
      expect(plan.enabled, false);
      expect(plan.active, isNull);
      expect(plan.accounts, isEmpty);
      expect(reads, 1);
      expect(plan.initializationError, isNotNull);
    },
  );
  test(
    'parallel calls refresh once and persist rotating token before using it',
    () async {
      var refreshCount = 0;
      var catalogCount = 0;
      var writes = <Map<String, dynamic>>[];
      final pending = Completer<Map<String, dynamic>>();
      final plan = ChatGptPlan.testClient(
        records: [record('A')],
        persist: (value) async {
          writes.add(jsonDecode(value));
        },
        transport: (url, bearer, form) async {
          if (form?['grant_type'] == 'refresh_token') {
            refreshCount++;
            expect(form!['client_id'], 'opaque-A');
            expect(form.containsKey('scope'), false);
            return pending.future;
          }
          expect(bearer, 'new-access-A');
          catalogCount++;
          return {'models': []};
        },
      );
      final one = plan.models(), two = plan.models();
      await Future<void>.delayed(Duration.zero);
      expect(refreshCount, 1);
      pending.complete(rotated('A'));
      await Future.wait([one, two]);
      expect(catalogCount, 2);
      expect(plan.active!.data['refresh_token'], 'new-refresh-A');
      expect(
        (writes.last['accounts'] as List).single['refresh_token'],
        'new-refresh-A',
      );
    },
  );
  test(
    'logout during refresh never resurrects tokens or emits catalog request',
    () async {
      var catalogCount = 0;
      final pending = Completer<Map<String, dynamic>>();
      final plan = ChatGptPlan.testClient(
        records: [record('A')],
        transport: (url, bearer, form) async {
          if (form?['grant_type'] == 'refresh_token') return pending.future;
          if (url.endsWith('/revoke')) return {};
          catalogCount++;
          return {'models': []};
        },
      );
      final future = expectLater(plan.models(), throwsA(anything));
      await Future<void>.delayed(Duration.zero);
      await plan.signOut();
      pending.complete(rotated('A'));
      await future;
      expect(catalogCount, 0);
      expect(plan.active!.signedIn, false);
      expect(plan.active!.data.containsKey('refresh_token'), false);
    },
  );
  test(
    'account switch retains rotated credentials for original registration but never sends its history as new account',
    () async {
      var catalogCount = 0;
      final pending = Completer<Map<String, dynamic>>();
      final plan = ChatGptPlan.testClient(
        records: [record('A'), record('B', expired: false)],
        transport: (url, bearer, form) async {
          if (form?['grant_type'] == 'refresh_token') return pending.future;
          catalogCount++;
          return {'models': []};
        },
      );
      final original = plan.active!;
      final future = expectLater(plan.models(), throwsA(anything));
      await Future<void>.delayed(Duration.zero);
      await plan.selectAccount(plan.accounts.last.id);
      pending.complete(rotated('A'));
      await future;
      expect(catalogCount, 0);
      expect(original.data['refresh_token'], 'new-refresh-A');
      expect(plan.active!.data['refresh_token'], 'old-refresh-B');
      // Stale request snapshot is rejected before creating any inference client.
      await expectLater(
        plan.generate([
          ChatMessage.humanText('A private history'),
        ], expectedAccountId: original.id).toList(),
        throwsA(anything),
      );
    },
  );
  test(
    'catalog keeps server order and display names and only visible models',
    () async {
      final plan = ChatGptPlan.testClient(
        records: [record('A', expired: false)],
        transport: (url, bearer, form) async => {
          'models': [
            {
              'slug': 'second',
              'display_name': 'Shown second',
              'visibility': 'list',
            },
            {'slug': 'hidden', 'visibility': 'hidden'},
            {
              'slug': 'first',
              'display_name': 'Shown first',
              'visibility': 'list',
            },
          ],
        },
      );
      final list = await plan.models();
      expect(list.map((m) => m['slug']), ['second', 'first']);
      expect(list.first['name'], 'Shown second');
    },
  );
  test(
    'failed request keeps tokens and retry can refresh successfully',
    () async {
      var refreshCount = 0;
      final plan = ChatGptPlan.testClient(
        records: [record('A')],
        transport: (url, bearer, form) async {
          if (form?['grant_type'] == 'refresh_token') {
            refreshCount++;
            if (refreshCount == 1)
              throw const FormatException('temporary transport failure');
            return rotated('A');
          }
          return {'models': []};
        },
      );
      await expectLater(plan.models(), throwsA(anything));
      expect(plan.active!.data['refresh_token'], 'old-refresh-A');
      await plan.models();
      expect(refreshCount, 2);
    },
  );
}
