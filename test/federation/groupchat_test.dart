// dsh-federation — 群聊视图解析单测（移植语义对照 client.js）
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/federation/groupchat.dart';

void main() {
  test('角色段落解析：名字：内容 → char 气泡', () {
    final out = parseAssistantText('小明：你好呀\n\n小红：大家好', ts: 1);
    expect(out.length, 2);
    expect(out[0].kind, 'char');
    expect(out[0].name, '小明');
    expect(out[1].name, '小红');
  });

  test('系统旁白 *（…）* → sys', () {
    final out = parseAssistantText('*（会议开始）*\n\n小红：大家好', ts: 2);
    expect(out[0].kind, 'sys');
    expect(out[0].text, '会议开始');
    expect(out[1].kind, 'char');
  });

  test('续行归属前角色', () {
    final out = parseAssistantText('小红：第一段\n\n继续补充内容', ts: 3);
    expect(out.length, 2);
    expect(out[1].name, '小红');
    expect(out[1].text, '继续补充内容');
  });

  test('非名字开头段落不产生气泡（跳过）', () {
    final out = parseAssistantText('**工具调用日志**', ts: 4);
    expect(out.isEmpty, true);
  });

  test('群聊流：user=owner，assistant=解析', () {
    final bubbles = groupChatBubbles([
      {'role': 'user', 'text': '大家好', 'ts': 10},
      {'role': 'assistant', 'text': '小明：欢迎\n\n小红：+1', 'ts': 11},
      {'role': 'assistant', 'text': '推理内容', 'ts': 12},
    ]);
    expect(bubbles[0].kind, 'owner');
    expect(bubbles[1].name, '小明');
    expect(bubbles[2].name, '小红');
    expect(bubbles.length, 3);
  });

  test('名称 hash 稳定（跨调用同色/同 emoji）', () {
    expect(colorOf('小明'), colorOf('小明'));
    expect(emojiOf('小红'), emojiOf('小红'));
    expect(colorOf('小明') != colorOf('小红') || emojiOf('小明') != emojiOf('小红'), true);
  });
}
