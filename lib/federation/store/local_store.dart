// dsh-federation — 本地历史库入口（条件导出枢纽）
// 纯模型（StoredSession/StoredMessage/historyEntriesToMessages）全平台共用；
// 实现：IO 系平台（Android/iOS/macOS/Windows/Linux）用 sqflite，
// Web 用内存实现（刷新即失，见 local_store_memory.dart 头注释）。
export 'models.dart';
export 'local_store_sqflite.dart' if (dart.library.html) 'local_store_memory.dart';
