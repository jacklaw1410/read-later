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
- Parenthetical (5): plain lowercase words where a base-form note
  follows sense text, so rule 3 changes the line.
- Ordinary (3): fixed — `serendipity`, `cafe`, `water`.
- Accent (2): fixed probe order — the first two diacritic spellings
  absent from the pack that resolve through accent folding.

A word whose only sense is an abbreviation expansion is skipped: `aahs`
ships only `abbr.[軍] Armored Artillery Howitzer`, and a card that
describes AH instead of "said aah" answers the wrong question.

Pointer-only here means the gloss names a base word and carries no
Chinese of its own (7,109 headwords). The 28,151 count in the review
also counts rows that pair a pointer note with a tagged sense (e.g.
`(a-frame 的複數) [機] A型架`); those render their own sense, so the
card shows the meaning instead of resolving.

The pack's `pos` column is empty for all 770,238 headwords, so `pos`
reads — on every row below; the card's meta line shows the phonetic
only. The part of speech reaches the card from the inline tag on each
sense line and sits in front of it (`n. 速率, 速度`). Sensitive to the
rule: the tag moves, it does not disappear.

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
a. 被拋棄的, 無約束的, 恣意放蕩的
```

### abaser

- phonetic: ә'beis
- pos: —
- subtitle: abase
- card shows:

```
vt. 降低...的地位, 降低...的品格, 貶抑, 使謙卑
```

### abdicative

- phonetic: 'æbdikeit
- pos: —
- subtitle: abdicate
- card shows:

```
vt. 正式放棄
vi. 退位, 退出, 辭職
```


## Mixed-tag entries — untagged first, at most one tagged line

### ab

- phonetic: æb
- pos: —
- card shows:

```
prep. 從, 自
[計] 地址總線
```

### abaca

- phonetic: .æbә'kɑ:
- pos: —
- card shows:

```
n. 馬尼拉麻, 麻蕉
[醫] 馬尼拉麻
```

### abacterial

- phonetic: .eibæk'tiәriәl
- pos: —
- card shows:

```
a. 非細菌性的
[醫] 非細菌性的; 無細菌的
```

### abacus

- phonetic: 'æbәkәs
- pos: —
- card shows:

```
n. 算盤
```

### abandonee

- phonetic: ә.bændә'ni:
- pos: —
- card shows:

```
n. 棄物受領人, 被委付人
[經] 受領(或有權受領)被遺棄財物者
```


## Grammar parentheticals — the base-form note is dropped

### abandoning

- phonetic: —
- pos: —
- card shows:

```
v. 放棄；屈服
```

### abandons

- phonetic: əˈbændənz
- pos: —
- card shows:

```
v. 離棄; 放棄; 遺棄; 陷入
```

### abases

- phonetic: əˈbeɪsiz
- pos: —
- card shows:

```
v. 使謙卑; 使感到羞恥; 使降低（地位、身份等）; <古>降下
```

### abashes

- phonetic: əˈbæʃiz
- pos: —
- card shows:

```
v. 使羞愧, 使侷促, 使窘迫
```

### abates

- phonetic: əˈbeɪts
- pos: —
- card shows:

```
v. 減少; 減去; 降價; 撤消（訴訟）
```


## Ordinary words

### serendipity

- phonetic: ,serәn'dipiti
- pos: —
- card shows:

```
n. 偶然發現珍寶的運氣/才能, 易遇奇緣的運氣
```

### cafe

- phonetic: kɑ:'fei
- pos: —
- card shows:

```
n. 咖啡館, 酒店
```

### water

- phonetic: 'wɒ:tә
- pos: —
- card shows:

```
n. 水, 雨水, 海水, 水位, 水面, 流水
vt. 給...澆水, 供以水, 注入水, 使溼
vi. 流淚, 流口水, 加水
a. 水的, 水上的, 水生的, 含水的
```


## Accent variants — tapped spelling over the stored headword

### café

- phonetic: kɑ:'fei
- pos: —
- subtitle: cafe
- card shows:

```
n. 咖啡館, 酒店
```

### cliché

- phonetic: 'kli:ʃei
- pos: —
- subtitle: cliche
- card shows:

```
n. 陳腔濫調, 凸印版
a. 陳腐的
```

