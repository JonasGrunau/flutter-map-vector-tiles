/// The labels the script suite draws, one place per script and a longer
/// one to wrap at `text-max-width`.
///
/// Pure Dart on purpose: `fonts/charset.dart` prints every character
/// used here, and `fonts/build.sh` subsets the bundled fonts to exactly
/// that set. A string added here needs a font rebuild, or it draws
/// `.notdef` boxes — which the suite's own coverage test reports.
library;

class ScriptSample {
  /// What the sample shows, for test names: "Arabic", "Thai", …
  final String script;

  /// A short place or street name in the script.
  final String name;

  /// A label long enough to wrap at a `text-max-width` of 5 em, with
  /// the break opportunities the script has: spaces in most; none in
  /// Thai, Lao, Khmer, Myanmar and Tibetan, where MapLibre does not
  /// break either; between any two ideographs or kana in Chinese and
  /// Japanese.
  final String wrapped;

  /// The lines [wrapped] is drawn in at 5 em, as the painter breaks it
  /// today.
  final List<String> lines;

  /// Whether a label along a curved line follows it glyph by glyph.
  /// Scripts whose letters change shape with their neighbours, or that
  /// the painter does not know to be safe, are drawn straight along the
  /// line's direction at the label's anchor instead.
  final bool curves;

  /// Whether the script is written right to left.
  final bool rtl;

  const ScriptSample(
    this.script,
    this.name,
    this.wrapped,
    this.lines, {
    this.curves = false,
    this.rtl = false,
  });
}

const scriptSamples = <ScriptSample>[
  // Precomposed diacritics, two of them stacked on one letter (ẵ).
  ScriptSample('Latin', 'Đà Nẵng', 'Bãi biển Mỹ Khê Đà Nẵng',
      ['Bãi biển', 'Mỹ Khê', 'Đà Nẵng'],
      curves: true),
  ScriptSample('Nordic Latin', 'Ærø Øresund', 'Øresundsbroen Ærø Færøerne',
      ['Øresundsbroen', 'Ærø', 'Færøerne'],
      curves: true),
  ScriptSample('Polish Latin', 'Śląsk', 'Województwo śląskie Łódź',
      ['Województwo', 'śląskie', 'Łódź'],
      curves: true),
  ScriptSample('Cyrillic', 'Москва', 'Улица Большая Морская',
      ['Улица', 'Большая', 'Морская'],
      curves: true),
  ScriptSample('Greek', 'Αθήνα', 'Οδός Ερμού Θεσσαλονίκη',
      ['Οδός', 'Ερμού', 'Θεσσαλονίκη'],
      curves: true),
  ScriptSample('Armenian', 'Երևան', 'Մաշտոցի պողոտա Երևան',
      ['Մաշտոցի', 'պողոտա', 'Երևան'],
      curves: true),
  ScriptSample('Georgian', 'თბილისი', 'რუსთაველის გამზირი თბილისი',
      ['რუსთაველის', 'გამზირი', 'თბილისი']),
  ScriptSample('Arabic', 'القاهرة', 'شارع الملك فهد الرياض',
      ['شارع الملك', 'فهد الرياض'],
      rtl: true),
  ScriptSample('Persian', 'اصفهان', 'خیابان انقلاب اسلامی تهران',
      ['خیابان', 'انقلاب', 'اسلامی', 'تهران'],
      rtl: true),
  ScriptSample('Urdu', 'اسلام آباد', 'شاہراہ قائداعظم لاہور',
      ['شاہراہ', 'قائداعظم', 'لاہور'],
      rtl: true),
  ScriptSample('Hebrew', 'תל אביב', 'רחוב הרצל תל אביב יפו',
      ['רחוב הרצל', 'תל אביב יפו'],
      rtl: true),
  // A conjunct (क्ष) and a pre-base matra (ि in त्रि).
  ScriptSample('Devanagari', 'क्षत्रिय', 'छत्रपति शिवाजी महाराज टर्मिनस',
      ['छत्रपति', 'शिवाजी', 'महाराज', 'टर्मिनस']),
  ScriptSample('Bengali', 'কলকাতা', 'হযরত শাহজালাল আন্তর্জাতিক বিমানবন্দর',
      ['হযরত', 'শাহজালাল', 'আন্তর্জাতিক', 'বিমানবন্দর']),
  ScriptSample('Tamil', 'சென்னை', 'அண்ணா சாலை சென்னை மாநகரம்',
      ['அண்ணா', 'சாலை', 'சென்னை', 'மாநகரம்']),
  // No spaces between words, tone marks stacked over vowels.
  ScriptSample('Thai', 'กรุงเทพมหานคร', 'ที่ว่าการอำเภอเมืองเชียงใหม่',
      ['ที่ว่าการอำเภอเมืองเชียงใหม่']),
  ScriptSample('Lao', 'ວຽງຈັນ', 'ນະຄອນຫຼວງວຽງຈັນ', ['ນະຄອນຫຼວງວຽງຈັນ']),
  ScriptSample('Khmer', 'ភ្នំពេញ', 'រាជធានីភ្នំពេញ', ['រាជធានីភ្នំពេញ']),
  ScriptSample(
      'Myanmar', 'မန္တလေး', 'ရန်ကုန်မြို့တော်ခန်းမ', ['ရန်ကုန်မြို့တော်ခန်းမ']),
  // ශ්\u200dරී: a ZWJ asks for the rakaaraansaya form.
  ScriptSample('Sinhala', 'කොළඹ', 'ශ්\u200dරී ජයවර්ධනපුර කෝට්ටේ',
      ['ශ්\u200dරී', 'ජයවර්ධනපුර', 'කෝට්ටේ']),
  // ལྷ: a subjoined consonant stacked under its head. The tsheg (་)
  // between syllables is not a place MapLibre breaks a line.
  ScriptSample(
      'Tibetan', 'ལྷ་ས', 'ལྷ་ས་གྲོང་ཁྱེར་ཆེན་མོ', ['ལྷ་ས་གྲོང་ཁྱེར་ཆེན་མོ']),
  ScriptSample('Chinese', '北京市', '北京市朝阳区建国门外大街', ['北京市朝阳', '区建国门外', '大街'],
      curves: true),
  ScriptSample('Japanese', '東京スカイツリー', '新宿駅西口バスターミナル', ['新宿駅西口', 'バスターミ', 'ナル'],
      curves: true),
  // Broken between two syllables of 세종대로: Flutter's line breaker
  // allows that in Hangul; MapLibre breaks Korean only at spaces.
  ScriptSample('Korean', '서울특별시', '서울특별시 종로구 세종대로', ['서울특별시', '종로구 세종', '대로'],
      curves: true),
];

/// Emoji the suite draws: a ZWJ family, a flag, a skin-tone modifier,
/// a plain symbol inside Latin text.
const emojiFamily = '👨\u200d👩\u200d👧';
const emojiFamilyUnjoined = '👨👩👧';
const emojiMan = '👨';
const emojiFlag = '🇩🇪';
const emojiThumbsSkinTone = '👍🏽';
const emojiThumbs = '👍';
const emojiInLatin = 'Café ☕';

/// The same names, precomposed and decomposed into base letters plus
/// combining marks. Drawn, each pair should look the same.
const combiningPairs = <(String, String)>[
  ('Café', 'Cafe\u0301'),
  ('Śląsk', 'S\u0301la\u0328sk'),
  ('Đà Nẵng', 'Đa\u0300 Na\u0306\u0303ng'),
];

/// Arabic with its vowel marks (harakat), and without.
const arabicVowelled = 'مُحَمَّد';
const arabicBare = 'محمد';

/// Arabic letters that all join, and the same letters kept apart by
/// zero-width non-joiners, which force their isolated forms.
const arabicJoined = 'محمد';
const arabicIsolated = 'م\u200cح\u200cم\u200cد';

/// Mixed-direction labels. [mixedRtlFirst] begins with Arabic, so it is
/// a right-to-left label holding a Latin word; [mixedLtrFirst] begins
/// with Latin and holds Hebrew between left-to-right marks.
const mixedRtlDigits = 'شارع 12';
const mixedRtlFirst = 'شارع King Fahd';
const mixedLtrFirst = 'Rue 5 \u200eתל\u200e';
const hebrewDigits = 'כביש 90';

/// Pairs for the reordering probes: a consonant alone, and with a vowel
/// sign written after it but drawn before it (or around it).
const preBaseVowels = <(String, String, String)>[
  ('Devanagari', 'क', 'कि'),
  ('Bengali', 'ক', 'কে'),
  ('Tamil', 'ச', 'செ'),
  ('Sinhala', 'ක', 'කෙ'),
  ('Myanmar', 'မ', 'မေ'),
];

/// Pairs for the stacking probes: a letter alone, and with a mark or
/// subjoined letter stacked over or under it.
const stackedMarks = <(String, String, String)>[
  ('Thai', 'ที', 'ที่'),
  ('Lao', 'ຈັ', 'ຈັ້'),
  ('Khmer', 'ភ', 'ភ្ន'),
  ('Tibetan', 'ལ', 'ལྷ'),
  ('Latin', 'ã', 'ẵ'),
];

/// Every string above, for the font subsetter.
Iterable<String> get allSampleText sync* {
  for (final s in scriptSamples) {
    yield s.name;
    yield s.wrapped;
  }
  yield* [
    emojiFamily, emojiFamilyUnjoined, emojiMan, emojiFlag, //
    emojiThumbsSkinTone, emojiThumbs, emojiInLatin,
  ];
  for (final (a, b) in combiningPairs) {
    yield a;
    yield b;
  }
  yield* [arabicVowelled, arabicBare, arabicJoined, arabicIsolated];
  yield* [mixedRtlDigits, mixedRtlFirst, mixedLtrFirst, hebrewDigits];
  for (final (_, a, b) in preBaseVowels) {
    yield a;
    yield b;
  }
  for (final (_, a, b) in stackedMarks) {
    yield a;
    yield b;
  }
}
