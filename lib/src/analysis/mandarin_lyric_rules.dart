// Original Mandarin lyric rules and exceptions written for YinTrace (音迹).
// The examples in the comments are covered by test/fixtures/mandarin_lyric_readings.tsv
// or mandarin_lyric_ambiguities.tsv.

/// Common-word readings and word boundaries. A longer dictionary word can
/// supply a different reading, as in 便宜行事 and 士大夫.
const mandarinLyricWords = <String, List<String>>{
  '便宜': ['pian', 'yi'], // 这把便宜的伞：cheap, or taking advantage.
  '大夫': ['dai', 'fu'], // 请大夫看看我的手：a doctor.
  '差事': ['chai', 'shi'], // 一桩差事：an assignment.
  '憎恶': ['zeng', 'wu'], // 憎恶的争吵：to detest.
  '朝霞': ['zhao', 'xia'], // 朝霞烧红了船篷：morning light.
  '没入': ['mo', 'ru'], // 桥脚没入水面：to be submerged.
  '归降': ['gui', 'xiang'], // 野马终肯归降：to yield.
  '重写': ['chong', 'xie'], // 把章节重写一遍：to rewrite.
  '拆模': ['chai', 'mu'], // 城砖凝固再拆模：remove the mold.
  '称手': ['chen', 'shou'], // 称手的锤子：comfortable to handle.
  '窗前': [], // 窗前调音：locative. Both characters use their usual reading.
};

const _instrument =
    r'(?:[我你他她]的|[这那]把|[一半][天夜])?'
    r'(?:[木电]?吉他|[钢古竖]?琴|琵琶|古筝|和弦|贝斯|曲子|[新旧]曲|老歌)';
const _quantity = r'[一二两三四五六七八九十百千万几数半每这那]';
const _rowContents = r'(?:[清热眼]?泪|诗(?!人|友)|字|文字|歌词|脚印|大雁|代码)';

// Patterns are anchored at the character being read. A rule returns only
// the syllables it changes, leaving the rest of the context to the lexicon.
final _contextualReadings = <String, List<(RegExp, List<String>)>>{
  '弹': [
    // 彈著鋼琴、我彈著的舊和弦。子弹着火 still uses dan.
    (RegExp('弹[着著]的?(?:[新旧])?$_instrument'), const ['tan', 'zhe']),
    (RegExp('弹[了过起]?$_instrument'), const ['tan']),
    // 我得去听你弹得有多轻。
    (RegExp(r'弹得(?:很|太|真|多|有多|轻|响|好|慢|快|比)'), const ['tan']),
  ],
  '行': [
    // 两行清泪、一行行脚印。Groups of people use xing.
    (RegExp('(?<=$_quantity)行行$_rowContents'), const ['hang', 'hang']),
    (RegExp('(?<=$_quantity)行$_rowContents'), const ['hang']),
    (RegExp('(?<=泪(?:$_quantity|成))行\$'), const ['hang']),
    (RegExp(r'(?<=诗)行$'), const ['hang']),
    // 同行的店家 share a trade. 唱给同行的你听 can mean traveling together.
    (RegExp(r'(?<=同)行(?:的)?(?:店家|商铺|业者|竞争)'), const ['hang']),
  ],
  '重': [
    // 重弹旧曲、重重迷雾 vs. 重重地砸醒屋瓦。
    (RegExp('(?:^|(?<=[再又想要我你他她]))重弹$_instrument'), const ['chong', 'tan']),
    (RegExp(r'重重(?:心事|困难|迷雾|阻碍|险阻)'), const ['chong', 'chong']),
    (RegExp(r'重重地[敲砸摔落]'), const ['zhong', 'zhong', 'de']),
    // 有多重 asks about weight. 多重身份 uses chong.
    (RegExp(r'(?<=有多)重(?:$|[啊呀呢吧嘛]|才)'), const ['zhong']),
  ],
  '还': [
    // 还我自由、还你钥匙。The pronoun is followed by what is being returned.
    (
      RegExp(r'还[我你他她](?:们)?(?:[一两几这那把旧]|自由|钥匙|清白|公道|钱|命|书|伞|名字)'),
      const ['huan'],
    ),
  ],
  '露': [
    // 露出笑脸、露出尾巴 favor the colloquial reading in lyrics.
    // With no such cue, either reading of 露出 can be sung.
    (RegExp(r'露出[了的]?(?:笑脸|半截|尾巴|头来|一角)'), const ['lou']),
  ],
  '落': [
    // 把钥匙落在床头 (leave it behind) vs. 松针落在车站 (fall).
    (RegExp(r'(?<=把(?:钥匙|雨伞|背包|帽子|信|书|行李|钱包)|忘了)落在'), const ['la']),
    (RegExp(r'(?<=别|没)落下(?:[我你他她那这一任]|$)'), const ['la']),
    (RegExp(r'(?<=都没)落下'), const ['la']),
  ],
  '没': [
    // 一个都没落下：negation before a verb, not the word 没落 (decline).
    (RegExp(r'没落下'), const ['mei']),
  ],
  '觉': [
    // 睡一觉 vs. 不知不觉.
    (RegExp(r'(?<=睡(?:[一两三四五几半过]|了[一两三四五几半]))觉'), const ['jiao']),
  ],
  '朝': [
    // 朝阳各伸一只手、朝阳在天边升起. 朝阳 also occurs in place names.
    (RegExp(r'朝阳(?:各|照|升|(?:从|在)天边)'), const ['zhao']),
    // 一朝梦醒：once the dream has ended.
    (RegExp(r'(?<=一)朝(?:梦醒|醒来)'), const ['zhao']),
  ],
  '调': [
    // 调亮这间小屋、把快门调回旧模式、调到电台; 调走守夜人 uses diao.
    (RegExp(r'调(?:亮|暗|高|低|匀|准|稳|好)'), const ['tiao']),
    (RegExp(r'(?<=快门|旋钮|频率|音量|温度|颜色|速度)调(?:到|回|成)'), const ['tiao']),
    (RegExp(r'调到[^，。！？]{0,8}(?:电台|频道|刻度|频率)'), const ['tiao']),
  ],
  '系': [
    // 把鞋带系好、把缆绳系在柳树上、系了个结. 牵系 uses xi.
    (RegExp(r'系(?:好|紧|牢|上(?:围巾|鞋带|绳|扣)|了(?:一)?个结)'), const ['ji']),
    (RegExp(r'(?<=绳|缆|鞋带|领带|丝带|围巾|线)系(?:在|住|上)'), const ['ji']),
  ],
  '血': [
    // A colloquial amount of blood, as in 吐了口血 and 出了点血.
    (RegExp(r'(?<=(?:吐|出)了(?:一)?[口点])血'), const ['xie']),
  ],
  '着': [
    // 山石着了火 has a result complement split by 了.
    (RegExp(r'[着著]了(?:火|凉|魔)'), const ['zhao']),
  ],
  '曾': [
    // 姓曾 uses the surname reading.
    (RegExp(r'(?<=姓)曾'), const ['zeng']),
  ],
};

const _particles = {
  '的': 'de',
  '地': 'de',
  '得': 'de',
  '了': 'le',
  '着': 'zhe',
  '著': 'zhe',
  '过': 'guo',
};

// Common verb heads for spotting a following action (真心地爱你), or a
// preceding action (引着小船). Word boundaries come from CC-CEDICT.
const _verbs =
    '爱听看唱走跑说想去来回等到写问记做打猜穿抱牵守找点花要引吸停'
    '拿推踩摸握拉捧撑拎站躺坐睡醒亮哭叹眨摇晃落沉流吹飞躲伸抵跳'
    '追靠戴带提扬揣擦埋压夹裹堆碰挡叫挂留披贴数排照朝对向'
    '知挨割剪挺立赶谈敲砸摆捡拾敞开念领变翻藏舍欠分拥送住'
    '试背和逗搂收接晒熬折拖兜眷陪洒泼偷瞧望涌含冒拽撒笑挥'
    '沿绕蹲跨探扳捂借邀弹熄举浇整抢掠学认递挑踏托调道服却吃盛吓忘';
const _objectOrEnding =
    '我的你他她它这那哪一些每谁可什把被吗呢啊呀吧了也刚正已'
    '衣头风雨雪路灯草石窗门台岸家山河海手心叶声话船伞墙桥光夜天'
    '钱茶包鱼钟种车站院盒日';
const _nounModifiers = '白灰黑红蓝青黄紫绿翠旧新薄厚淡浅深冷热小大干湿香短长空';
const _adverbs = '轻慢悄静默深好狠稳猛认真冷柔快高低紧暖软';
// 终于找着你了 and 我点着了蜡烛 favor the result reading.
const _resultZheVerbs = '点找猜引打燃烧碰摸够挨借';
final _resultAlready = RegExp(r'(?<=(?:终于|总算|好不容易|一下就|刚刚)[点找猜引打燃烧碰摸够挨借])[着著]');
final _resultThenLe = RegExp(r'[着著](?:[我你他她它]们?)?了');
final _zheLexeme = RegExp(r'[着著][火凉急迷魔陆落力色墨眼手笔重装衣床书作名称述实录有文者]');
final _liaoLexeme = RegExp(r'了(?:解|结|却|然|当|事|断|如指掌|不起|得)');
final _diLexeme = RegExp(r'(?<=[湿营土大平空场原遍各满高荒沙旱草腹盆一])地');
final _zheObject = RegExp(r'[着著](?:凉气|火[苗光把焰炉]|衣[角袖领襟]|[书文](?!名|学|刊))');
// A subject or a modal adverb followed by 得 and an action (我得走了、还得悄悄地离开).
final _deiLeft = RegExp(r'(?<=[我你他她咱仍还也就总都可必该非偏才只再真])得|(?<=[我你他她咱]们)得');
final _deiRight = RegExp(
  r'得(?:[走去来看听唱等写记把给有是做赶找回说试学留收练换带想让问帮先再多早快慢]'
  r'|小心|怎么|什么时候|亲手|亲自|悄悄|轻轻|好好)',
);

Iterable<String> get mandarinLyricSyllables sync* {
  yield* _particles.values;
  yield* const ['dei', 'liao', 'di'];
  for (final reading in mandarinLyricWords.values) {
    yield* reading;
  }
  for (final rules in _contextualReadings.values) {
    for (final (_, reading) in rules) {
      yield* reading;
    }
  }
}

class MandarinLyricContext {
  const MandarinLyricContext(
    this.text,
    this.chars,
    this.offsets,
    this.wordStarts,
    this.wordEnds,
  );

  final String text;
  final List<String> chars;
  final List<int> offsets;
  final List<bool> wordStarts, wordEnds;

  bool _matches(RegExp pattern, int index) =>
      pattern.matchAsPrefix(text, offsets[index]) != null;

  List<String>? readingAt(int index) {
    // 降服不了 or 恫吓不了 indicates inability. At the start of a run
    // 不了 can instead politely decline (bu le).
    if (chars[index] == '了' &&
        index >= 2 &&
        chars[index - 1] == '不' &&
        _verbs.contains(chars[index - 2])) {
      return const ['liao'];
    }
    // 一地、满地 and 营地 name a place or extent. 高高地 is a modifier.
    if (chars[index] == '地' &&
        !_repeatedBefore(index) &&
        _matches(_diLexeme, index)) {
      return const ['di'];
    }
    final char = chars[index];
    final rules = _contextualReadings[char == '著' ? '着' : char];
    if (rules == null) return null;
    for (final (pattern, reading) in rules) {
      if (_matches(pattern, index)) return reading;
    }
    return null;
  }

  bool _repeatedBefore(int index) =>
      index >= 2 && chars[index - 2] == chars[index - 1];

  /// A known particle forms its own segment. When the context is inconclusive,
  /// leave the overlapping dictionary words available to the segmenter.
  String? particleAt(int index) {
    final char = chars[index];
    final particle = _particles[char];
    if (index == 0 || particle == null) return null;
    final previous = chars[index - 1];
    final atEnd = index + 1 == chars.length;
    final next = atEnd ? '' : chars[index + 1];
    final leftWord = wordEnds[index];
    final verbBefore = _verbs.contains(previous);
    final verbAfter = !atEnd && _verbs.contains(next);
    final rightWord =
        atEnd ||
        wordStarts[index + 1] ||
        verbAfter ||
        _objectOrEnding.contains(next);

    final isParticle = switch (char) {
      // 盲目 + 的 + 爱, 真的 + 确定, but 目的地 and 小马的确跑得很快.
      '的' =>
        (leftWord ||
                '我你他她它这那谁真里裡裏边面内外上下前后'.contains(previous) ||
                (verbBefore && next == '确')) &&
            rightWord &&
            !_matches(_diWord, index) &&
            (next != '确' || _matches(_queWord, index)),
      // 真心地爱你, but 心地柔软 and 写下目的地.
      '地' =>
        (_repeatedBefore(index) || !_matches(_diLexeme, index)) &&
            !_matches(_destination, index) &&
            (leftWord ||
                _adverbs.contains(previous) ||
                _repeatedBefore(index)) &&
            (verbAfter || (!atEnd && '把被'.contains(next)) || atEnd),
      // 到了 and 等到了, but 了解 and 忘不了.
      '了' =>
        rightWord &&
            (verbBefore || leftWord) &&
            previous != '不' &&
            !_matches(_liaoLexeme, index) &&
            !_matches(_neverEnding, index),
      // 穿着白衣 and 点着头, but 她的穿着, 子弹着火 and 点着了蜡烛.
      '着' || '著' =>
        (verbBefore || previous == '弹') &&
            (rightWord ||
                _nounModifiers.contains(next) ||
                _matches(_zheObject, index)) &&
            previous != '睡' &&
            (!_matches(_zheLexeme, index) || _matches(_zheObject, index)) &&
            !_matches(_attire, index) &&
            !(_resultZheVerbs.contains(previous) &&
                (atEnd ||
                    _matches(_resultAlready, index) ||
                    _matches(_resultThenLe, index))),
      // 唱过一遍, with standalone 过往 and 过来 left to the dictionary.
      '过' => verbBefore && rightWord,
      // 唱得很轻 has a complement. 我得走了 has a modal verb.
      '得' => verbBefore && !atEnd && '很太更多慌极比要像见轻响好慢快'.contains(next),
      _ => false,
    };
    if (char == '得' &&
        _matches(_deiLeft, index) &&
        _matches(_deiRight, index)) {
      return 'dei';
    }
    return isParticle ? particle : null;
  }
}

final _diWord = RegExp(r'(?<=[标中])的|(?<=目)的地|(?<=[有无])的放矢');
final _destination = RegExp(r'(?<=(?<!无)目的)地');
final _queWord = RegExp(r'的确(?:认(?!为|识|得)|切(?!开|断)|定|凿|立|实)');
final _neverEnding = RegExp(r'(?<=没完没|不了了|一了百)了');
final _attire = RegExp(r'(?<=[身的]穿)[着著]');
