/// 自动重连计划(纯函数,可单测)。
///
/// 连接失败后自动重试:第 1 次等 2s、第 2 次等 4s、第 3 次等 8s,
/// 最多 3 次;全部耗尽后进入错误页,由用户手动重试。
library;

/// 第 n 次自动重试(attempt 从 1 起)前的等待毫秒。
const List<int> retryDelaysMs = [2000, 4000, 8000];

/// 自动重试最大次数(与 [retryDelaysMs] 长度一致)。
const int maxRetryAttempts = 3;

/// 返回第 [attempt] 次重试(attempt 从 1 起)前的等待毫秒;
/// attempt 越界(< 1 或超过 [maxRetryAttempts])时返回 null,表示重试已耗尽。
int? retryDelayMs(int attempt) {
  if (attempt < 1 || attempt > retryDelaysMs.length) {
    return null;
  }
  return retryDelaysMs[attempt - 1];
}
