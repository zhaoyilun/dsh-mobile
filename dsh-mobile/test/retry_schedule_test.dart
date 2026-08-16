import 'package:dsh_mobile/retry_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('retry_schedule', () {
    test('重试延迟依次为 2s / 4s / 8s', () {
      expect(retryDelayMs(1), 2000);
      expect(retryDelayMs(2), 4000);
      expect(retryDelayMs(3), 8000);
    });

    test('最多 3 次:第 4 次与越界(0/-1)返回 null', () {
      expect(maxRetryAttempts, 3);
      expect(retryDelayMs(4), isNull);
      expect(retryDelayMs(0), isNull);
      expect(retryDelayMs(-1), isNull);
    });

    test('延迟表长度与最大重试次数一致', () {
      expect(retryDelaysMs.length, maxRetryAttempts);
    });

    test('延迟严格递增(退避)', () {
      for (var i = 1; i < retryDelaysMs.length; i++) {
        expect(retryDelaysMs[i], greaterThan(retryDelaysMs[i - 1]));
      }
    });
  });
}
