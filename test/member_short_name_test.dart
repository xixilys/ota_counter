import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/member_short_name.dart';

void main() {
  group('defaultMemberShortName', () {
    test('drops a leading honorific when more text follows', () {
      expect(defaultMemberShortName('小雪'), '雪');
      expect(defaultMemberShortName('小树'), '树');
      expect(defaultMemberShortName('阿岚'), '岚');
      expect(defaultMemberShortName('大野'), '野');
    });

    test('keeps a bare honorific as a name', () {
      expect(defaultMemberShortName('小'), '小');
      expect(defaultMemberShortName('大'), '大');
    });

    test('doubled names give one character', () {
      expect(defaultMemberShortName('娜娜'), '娜');
      expect(defaultMemberShortName('熊熊'), '熊');
    });

    test('mixed CJK + Latin names use the CJK part', () {
      expect(defaultMemberShortName('兔兔Miottie'), '兔');
      expect(defaultMemberShortName('浙璃Kiko'), '浙璃');
      expect(defaultMemberShortName('水堇Sumire'), '水堇');
      expect(defaultMemberShortName('班班Airuru'), '班');
      expect(defaultMemberShortName('桃菓_momoka'), '桃菓');
      expect(defaultMemberShortName('皮皮猪'), '皮');
      expect(defaultMemberShortName('夏小米'), '夏小');
    });

    test('Latin-only names keep up to four letters', () {
      expect(defaultMemberShortName('Remi'), 'Remi');
      expect(defaultMemberShortName('Liumoo'), 'Lium');
      expect(defaultMemberShortName('remi'), 'Remi');
        });

    test('never returns empty for odd input', () {
      expect(defaultMemberShortName(''), '?');
      expect(defaultMemberShortName('   '), '?');
      expect(defaultMemberShortName('·'), '·');
      expect(defaultMemberShortName('1234567'), '1234');
    });
  });

  group('resolveMemberShortName', () {
    test('configured short name wins', () {
      expect(
        resolveMemberShortName(name: '小雪', configured: '雪宝'),
        '雪宝',
      );
      expect(
        resolveMemberShortName(name: 'Remi', configured: '  R  '),
        'R',
      );
    });

    test('blank configuration falls back to the derived default', () {
      expect(resolveMemberShortName(name: '小雪', configured: ''), '雪');
      expect(resolveMemberShortName(name: '娜娜', configured: '   '), '娜');
      expect(resolveMemberShortName(name: 'Liumoo'), 'Lium');
    });

    test('normalizes long configured values to four characters', () {
      expect(normalizeMemberShortName('ABCDEF'), 'ABCD');
      expect(normalizeMemberShortName('  雪  '), '雪');
      expect(normalizeMemberShortName(''), '');
    });
  });
}
