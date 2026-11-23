import 'package:baocode/channel/account/account_api.dart';
import 'package:baocode/channel/account/sub2api_adapter.dart';
import 'package:baocode/channel/channel_setup.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_fakes.dart';

void main() {
  test(
    'Sub2API account calls the mobile-control proxy with both sessions',
    () async {
      final site = FakeSite({
        'POST /api/v1/auth/refresh': (_) => sub({
          'access_token': 'sub-access',
          'refresh_token': 'sub-refresh-next',
          'expires_in': 3600,
        }),
        'POST /api/v1/user/mobile-account/exchange': (sent) {
          expect(sent.headers['Authorization'], 'Bearer sub-access');
          return const AccountResponse(200, {
            'access_token': 'mobile-session',
            'expires_at': 4_102_444_800,
          });
        },
        'GET /api/v1/user/mobile-account/devices': (sent) {
          expect(sent.url.queryParameters, {'role': 'phone'});
          expect(sent.headers['Authorization'], 'Bearer sub-access');
          expect(sent.headers['X-Mobile-Account-Token'], 'mobile-session');
          return const AccountResponse(200, {'devices': []});
        },
      });
      final adapter = Sub2ApiAdapter(
        site: ChannelAccountSite.parse({
          'type': 'sub2api',
          'url': 'https://sub.example',
        })!,
        send: site.send,
        credential: 'sub-refresh',
      );

      final exchange = await adapter.mobileAccountRequest(
        'POST',
        '/exchange',
        json: const {},
      );
      expect(exchange.json, containsPair('access_token', 'mobile-session'));
      expect(
        adapter.credential,
        'sub-refresh-next',
        reason: 'refresh rotation from the Sub2API request is kept',
      );

      final devices = await adapter.mobileAccountRequest(
        'GET',
        '/devices?role=phone',
        mobileAccountToken: 'mobile-session',
      );
      expect(devices.json, {'devices': []});
      expect(
        site.paths,
        containsAll([
          'POST /api/v1/user/mobile-account/exchange',
          'GET /api/v1/user/mobile-account/devices',
        ]),
      );
    },
  );
}
