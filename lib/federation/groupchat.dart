// dsh-federation — 群聊视图解析（移植 dsh-groupchat-view/client.js 的段落解析语义）
// 纯函数：assistant 文本 → 气泡序列（sys 旁白 / char 角色 / 续行归属前角色）；
// 用户消息 → 群主气泡；名称/颜色/emoji 由 hash 稳定分配（与浏览器端一致）。
import 'package:flutter/material.dart';

class GcBubble {
  GcBubble({required this.kind, this.name = '', required this.text, required this.ts});
  final String kind; // 'owner' | 'char' | 'sys'
  final String name;
  final String text;
  final int ts;

  Color get color => colorOf(name);
  String get emoji => emojiOf(name);
}

const List<Color> _palette = [
  Color(0xFF4f83e0), Color(0xFFe06fae), Color(0xFFe09a3f), Color(0xFF50b06f),
  Color(0xFF9a6fe0), Color(0xFFe05a5a), Color(0xFF3fb0b8), Color(0xFFb08a3f),
];

const List<String> _emoji = ['🧔', '🦌', '💼', '🐱', '🦊', '🐻', '🦉', '🐧', '🐸', '🐺', '🦋', '🐯', '⭐', '🍀', '🎨', '🔧'];

int _hash(String s) {
  var h = 0;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0xFFFFFFFF;
  }
  return h;
}

Color colorOf(String name) => _palette[_hash(name) % _palette.length];
String emojiOf(String name) => _emoji[_hash('e$name') % _emoji.length];

bool _looksLikeName(String s) {
  if (s.isEmpty || s.length > 16) return false;
  if (RegExp(r'^[0-9.:%\-$#*>`]').hasMatch(s)) return false;
  if (RegExp(r'^\d+$').hasMatch(s)) return false;
  return RegExp(r'[\u4e00-\u9fffA-Za-z]').hasMatch(s);
}

List<GcBubble> parseAssistantText(String text, {required int ts}) {
  final out = <GcBubble>[];
  String? last;
  for (final raw in text.split(RegExp(r'\n{2,}'))) {
    final p = raw.trim();
    if (p.isEmpty) continue;
    final sys = RegExp(r'^\*[（(]([\s\S]*?)[)）]\*$').firstMatch(p);
    if (sys != null) {
      out.add(GcBubble(kind: 'sys', text: sys.group(1)!.trim(), ts: ts));
      last = null;
      continue;
    }
    final m = RegExp(r'^([^\s:：]{1,16}?)\s*[:：]\s*([\s\S]*)$').firstMatch(p);
    if (m != null && _looksLikeName(m.group(1)!)) {
      out.add(GcBubble(kind: 'char', name: m.group(1)!, text: m.group(2)!.trim(), ts: ts));
      last = m.group(1);
      continue;
    }
    if (last != null) out.add(GcBubble(kind: 'char', name: last, text: p, ts: ts));
  }
  return out;
}

/// 把会话消息序列转为群聊气泡流：用户消息=群主，assistant 文本=角色解析。
List<GcBubble> groupChatBubbles(List<Map<String, dynamic>> messages) {
  final out = <GcBubble>[];
  for (final msg in messages) {
    final role = msg['role']?.toString() ?? 'system';
    final text = msg['text']?.toString() ?? '';
    final ts = (msg['ts'] as num?)?.toInt() ?? 0;
    if (text.isEmpty) continue;
    if (role == 'user') {
      out.add(GcBubble(kind: 'owner', text: text, ts: ts));
    } else if (role == 'assistant') {
      out.addAll(parseAssistantText(text, ts: ts));
    }
  }
  return out;
}
