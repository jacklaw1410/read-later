# Gloss sample sheet — 20 headwords, rendered by the lookup path

Each card string below is the exact output of
`PackIndexStore.displayEntry(for:)` on the installed index: the three
gloss rules from `spec/dictionary-packs.md` §4 already ran. The card
shows at most 4 gloss lines, in source order.

Reproduce the list:

```bash
swift run --package-path packages/ReadLaterPacks gloss-samples pack.gz
```

Selection rule (fixed; alphabetical over the pack's headwords):

- Pointer (5): lowercase words whose gloss holds only a pointer and
  whose base word resolves to a Chinese gloss.
- Mixed-tag (5): plain lowercase words with untagged and tagged lines.
- Parenthetical (5): plain lowercase words where dropping the
  base-form note changes the text.
- Ordinary (3): fixed — `serendipity`, `cafe`, `water`.
- Accent (2): fixed probe order — the first two diacritic spellings
  absent from the pack that resolve through accent folding.

Pointer-only here means the gloss names a base word and carries no
Chinese of its own (7,109 headwords). The 28,151 count in the review
also counts rows that pair a pointer note with a tagged sense (e.g.
`(a-frame 的複數) [機] A型架`); those render their own sense, so the
card shows the meaning instead of resolving.

The pack's `pos` column is empty for all 770,238 headwords, so `pos`
reads — on every row below; the card's meta line shows the phonetic
only. The inline tags (`n.`, `vi., vt.`) that carried that signal are
stripped by rule and never appear raw.

## Pointer glosses — resolved through the base word

### a-listers

- phonetic: —
- pos: —
- subtitle: a-list
- card shows:

```
(very best) 最好的, 最優秀的, 最酷的
```

### abaculi

- phonetic: ә'bækjulәs
- pos: —
- subtitle: abaculus
- card shows:

```
鑲嵌用的小石[玻璃]磚, 嵌塊
```

### abandonedly

- phonetic: ә'bændәnd
- pos: —
- subtitle: abandoned
- card shows:

```
被拋棄的, 無約束的, 恣意放蕩的
```

### abaser

- phonetic: ә'beis
- pos: —
- subtitle: abase
- card shows:

```
降低...的地位, 降低...的品格, 貶抑, 使謙卑
```

### abdicative

- phonetic: 'æbdikeit
- pos: —
- subtitle: abdicate
- card shows:

```
正式放棄
退位, 退出, 辭職
```


## Mixed-tag entries — untagged first, at most one tagged line

### ab

- phonetic: æb
- pos: —
- card shows:

```
從, 自
[計] 地址總線
```

### abaca

- phonetic: .æbә'kɑ:
- pos: —
- card shows:

```
馬尼拉麻, 麻蕉
[醫] 馬尼拉麻
```

### abacterial

- phonetic: .eibæk'tiәriәl
- pos: —
- card shows:

```
非細菌性的
[醫] 非細菌性的; 無細菌的
```

### abacus

- phonetic: 'æbәkәs
- pos: —
- card shows:

```
算盤
```

### abandonee

- phonetic: ә.bændә'ni:
- pos: —
- card shows:

```
棄物受領人, 被委付人
[經] 受領(或有權受領)被遺棄財物者
```


## Grammar parentheticals — the base-form note is dropped

### aahhing

- phonetic: —
- pos: —
- card shows:

```
[軍] Armored Artillery Howitzer, 裝甲榴彈炮
[軍] Advanced Attack Helicopter, 先進攻擊直升機
```

### aahing

- phonetic: —
- pos: —
- card shows:

```
[軍] Armored Artillery Howitzer, 裝甲榴彈炮
[軍] Advanced Attack Helicopter, 先進攻擊直升機
```

### aahs

- phonetic: —
- pos: —
- card shows:

```
[軍] Armored Artillery Howitzer, 裝甲榴彈炮
[軍] Advanced Attack Helicopter, 先進攻擊直升機
```

### aats

- phonetic: —
- pos: —
- card shows:

```
alpha-l antitrypsin α-1抗胰蛋白酶
```

### abacos

- phonetic: —
- pos: —
- card shows:

```
Great and Little Abaco islands 大阿巴科羣島和小阿巴科羣島
```


## Ordinary words

### serendipity

- phonetic: ,serәn'dipiti
- pos: —
- card shows:

```
偶然發現珍寶的運氣/才能, 易遇奇緣的運氣
```

### cafe

- phonetic: kɑ:'fei
- pos: —
- card shows:

```
咖啡館, 酒店
```

### water

- phonetic: 'wɒ:tә
- pos: —
- card shows:

```
水, 雨水, 海水, 水位, 水面, 流水
給...澆水, 供以水, 注入水, 使溼
流淚, 流口水, 加水
水的, 水上的, 水生的, 含水的
```


## Accent variants — tapped spelling over the stored headword

### café

- phonetic: kɑ:'fei
- pos: —
- subtitle: cafe
- card shows:

```
咖啡館, 酒店
```

### cliché

- phonetic: 'kli:ʃei
- pos: —
- subtitle: cliche
- card shows:

```
陳腔濫調, 凸印版
陳腐的
```

