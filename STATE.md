# Где мы стоим

Обновлено 26 августа 2026. Всё, что здесь есть, — измерено; предположения помечены как таковые.

## Измеренный фронт на Qwen3-Coder-30B-A3B

| конфигурация | ток/с | перплексия | комментарий |
|---|---|---|---|
| Q6_K, только mmap | 7.26 | 2.1121 (база) | перепаковка **не влезает**: файл 24.5 ГБ при 25.5 свободных |
| **mx9** — 5 бит эксперты + все Q/K/V | 9.47 | **+3.25%** | лучшая точка под приоритет качества |
| mx1 — 4 бита | **13.38** | +7.92% | лучшая точка по скорости; разброс 2.7% при t=8 |
| mx7 — 4 бита, калиброван | 12.70 | +9.72% | хуже mx1 по обоим осям, см. про матрицу важности |

Опора: генерация упирается в полосу памяти **на 100%**. mx1 читает 1.804 ГБ на токен, и
1.804 / 72.7 мс = 24.8 ГБ/с — ровно полоса машины. Накладных расходов нет; байты переводятся в
скорость почти один к одному (R² = 0.998 на развёртке по числу активных экспертов).

**20 ток/с требуют ≤1.24 ГБ на токен — от процессора.** Квантованием это недостижимо: даже четыре
бита дают 1.80. Оговорка «от процессора» дописана 26 августа и она здесь несущая: полоса 24.8 ГБ/с
принадлежит ОЗУ, а не задаче. Байты, прочитанные картой на 131 ГБ/с, в этот бюджет не входят
вовсе. Из 1720 МБ на токен 802 МБ — статика, одинаковая на каждом токене; она уезжает на карту, и
процессору остаётся его доля экспертов. Расчёт по всем моделям — ниже, в разделе про полную схему.

Пока эта оговорка не была написана, из верной арифметики делался неверный вывод: что 20 ток/с
недостижимы вообще и спасёт только модель с втрое меньшим числом активных параметров. Величина
«байт на токен» неявно предполагает один канал памяти, и это предположение ни разу не было
названо вслух — поэтому и не проверялось.

## Байтовый бюджет других моделей (по заголовкам, до замера)

| модель | активных | байт/токен | прогноз | что съедает |
|---|---|---|---|---|
| mx1 (30B) | 8/128 | 1.804 | 13.8 | эксперты 918 МиБ |
| Coder-Next IQ3 (80B) | 10/512 | 2.200 | 11.3 | **внимание 965 МиБ** |
| Qwen3.6-35B Q6 | 8/256 | 2.766 | 9.0 | внимание 1042, голова 515 |
| Gemma 4 26B-A4B Q4 | 8/128 | 3.241 | 7.7 | внимание 1125, плотные FFN 543, **голова 748 связана с эмбеддингом** |

Размер файла скорость не определяет — определяет доля, читаемая **каждый** токен. У mx1 это 5.1%
файла, у Gemma 15.2%. Отсюда: у крупных моделей рычаг во внимании и голове, а не в экспертах.

## Открытое, по убыванию ожидаемой отдачи

> **Этот список устарел** (26 августа). Спекуляция закрыта замером, зонный KV на процессоре закрыт,
> диагноз по карте исправлен, а порядок приоритетов перевернулся: первой на карту едет **статика**,
> а самым крупным рычагом оказались не байты, а **запуски ядер** — 19.6 мс из 41. Актуальный
> список — в разделе «Состояние на 26 августа» ниже. Пункты 1–4 оставлены как запись того, что
> считалось приоритетным, и чем это оказалось.

1. **Резидентные эксперты в VRAM с параллельным счётом.** Симуляция на настоящих трассах роутера:
   доля попаданий 67–80% при ёмкости 23%, отсюда **21.8–23.4 ток/с**. Единственное, что по
   расчёту даёт 20. Политика — LFU (у LRU та же доля попаданий при вчетверо большем трафике, до
   208 МБ за токен против пропускной способности линии 177). Живое уточнение снимает сдвиг
   распределения: после смены языка набор восстанавливается за ~100 токенов.
   **Препятствия измерены:** пол встречи процессора с картой 11.6–13.0 мс (из них 8.5 — задержки
   передач); свободно 3.36 ГиБ вместо 3.8; буфер ≤256 МиБ уходит в BAR и читается со 3.1 ГБ/с.
   **Выживает при своей записи команд** — передачи в тот же буфер, что и счёт, один барьер на слой
   (48 диспатчей с забором на каждом 5.0 мс, под одним забором 1.5 мс).
2. **Спекуляция.** Единственный приём, размазывающий чтение весов по токенам, и бесплатный по
   качеству. Измерено пока +1…+4%; форк печатает долю приёмки и время черновика отдельно
   (`speculative.cpp:2675`), плюс есть `--spec-autotune`. Замер в очереди.
3. **Зонный KV.** Экономия байт измерена: 1.69× на 2048, 1.86× на 16384. Скорость — в очереди;
   прогноз +4% на 2048 и +28% на 16384.
4. **Карта после исправления диагноза.** `IQ4_KS` и `_R4` в вулкановском бэкенде отсутствуют, из-за
   чего прежние прогоны откатывались на процессор. mx10 с экспертами в `IQ4_XS` строится сейчас.

## Закрыто замерами

| ветка | чем закрыта |
|---|---|
| разреженность активаций | есть поэлементно (22% при 2.5% ошибки, подтверждает литературу), но блоков по 32 — 3e-5; оракул даёт 0.09% байт при 5% ошибки; маска перебрасывается каждый токен |
| пер-экспертная точность | ошибка плоская: медианный эксперт в пределах 1% от наименее повреждённого, порог 0.0743 одинаков во всех слоях |
| лестница битов по частоте | сдвиг распределения: набор с кода на русском забирает 24.1% против 25.0% у случайного |
| калибровка как средство спасти 4 бита | mx3 ≈ mx4 в пределах погрешности; mx7 калиброван и **хуже** mx1 |
| выходная голова в 4 битах | −5% байт за +2% перплексии |
| SER / LExI / адаптивный k | роутер плоский равномерно: top-1 ≈ 0.22, top-7 ≈ 0.92 во всех 48 слоях |
| безмодельная спекуляция | ноль порождённых черновиков либо 3 принятых из 84 |
| дешёвые черновики | IQ3-черновик дал **−22%**: приёмка обвалилась. Качество черновика важнее размера |
| большие черновики | арифметика: 1.7B на глубине 4 читает 4.1 ГБ за раунд против 2.8 у цели |
| низкоранговый хвост KV | GQA уже сжала KV вчетверо, дальше 78.96% ошибки |
| Адамар на значениях | бесполезен; на ключах вдвое уменьшает ошибку и используется |
| префилл на карте | монотонно хуже: 26.87 → 12.34 → 7.73 при ngl 0/8/16 |
| `-mqkv` | пустышка даже когда Q/K/V одного типа: 8.92 против 9.47 |
| `-muge`, `-ub`, `--no-mmap`, `--mlock` | в пределах шума 4.2% |
| `-rcache`, `-sas`, `-smgs`, `-ger`, `-gap`, `-grt`, `-mtp`, `-wb`, `-thp` | удалены, другая архитектура или требуют нескольких устройств |

## Собственные ошибки, стоившие времени

- **«28% времени не память»** — из оценки 1.29 ГБ вместо настоящих 1.804. Проверка, которой не
  хватало: разделить байты на активные параметры и сравнить с самым грубым типом в файле.
- **«Coder-Next — путь к 20»** — сказано без расчёта его бюджета. Он читает 2.2 ГБ за токен.
- **«Карта бесполезна»** — замер верен, диагноз неверен: `mul_mat_id` доступен, полоса 131 ГБ/с
  (а не 37.1), запуск ядра 31 мкс (а не 160–250). Причина провала — отсутствие типов в бэкенде.
- **«4 потока лучше 8»** — стояло на разнице 5.3% при пороге шума 4.2%. При повторах t=8 быстрее
  на 7–9%.
- **«Загрузка не мешает замерам»** — мешает: те же прогоны во время докачки дали разброс 17%
  против 2.7% в тишине.

## Организационное, что съело больше всего времени

- Сторож считал «занято» по наличию процесса; демоны MSBuild висят без работы и заморозили
  очередь **на 2.5 часа** при свободной машине. Теперь компиляторы оцениваются по приросту
  процессорного времени.
- Из каталога сборки пропала `ggml.dll`; CMake считал цель готовой, обычная пересборка была
  пустышкой, а прогоны падали с `STATUS_DLL_NOT_FOUND` **без сообщения** — потеряна ночь. Теперь
  очередь проверяет запускаемость и восстанавливает библиотеки сама.
- Один зависший прогон без тайм-аута съел **13 часов**. Теперь у каждого плеча жёсткий предел.
- Несколько скриптов, каждый со своим ожиданием тишины, увидели одну тишину и стартовали вместе.
  Теперь одна очередь в одном процессе.

## Обновление 26 августа, вечер

### Измеренный фронт на 30B (без карты)

| конфигурация | ток/с | перплексия |
|---|---|---|
| Q6_K, mmap (перепаковка не влезает) | 7.26 | 2.1121 база |
| **mx9** — 5 бит эксперты и всё внимание | 9.47 | **+3.25%** |
| mx1 — 4 бита, с перепаковкой | **13.38** | +7.92% |
| mx10 — 4 бита в IQ4_XS (для карты) | не мерен | +10.5% |

### Крупная находка: движок читал весь выделенный кэш

Виды K и V брали протяжённость из `-c`, а маска обнуляла незанятое **после** чтения. При
`-c 16384` с 1408 занятыми позициями это 1610.6 МБ за токен вместо 138.4 — **в 11.6 раз лишнего**.
Учёт байтов содержал ту же ошибку, то есть движок докладывал её мне обратно, и «полка», с которой
я сравнивал, была завышена ровно так же.

Исправлено: `aim_kv_reads` переставляет протяжённость четырёх тензоров на слой по занятости, граф
по-прежнему собирается один раз, кратность 32 сохранена (дефект F16-умножения при некратной длине
свёртки). Проверка «всё или ничего»: при несогласии тензоров граф читает всё целиком — медленно и
верно, а не быстро и неверно. Арифметика инертна: диагностика логитов совпала до последней цифры.

Бюджет до и после: `-c 2048` 2.005 → 1.942 ГБ, `-c 16384` **3.414 → 1.942**. Зависимость от `-c`
исчезла.

**Чему это учит.** Ошибка была невидима по построению: маска давала верный вывод, токены
совпадали, тесты проходили. Выдала её только зависимость скорости от `-c` при одинаковом промпте —
то есть **сравнение трёх режимов одного и того же**, а не один замер.

### Карта: направление было закрыто на неверном диагнозе, теперь открыто и упирается в другое

Три числа, на которых стоял отказ, оказались неверны: `mul_mat_id` **доступен** (16 388 байт
разделяемой памяти против лимита 32 768, отключается только большая плитка), запуск ядра **31 мкс**
а не 160–250, полоса видеопамяти **131 ГБ/с** а не 37.1 — то есть карта быстрее процессора в 5.3
раза, а не в 1.5.

Настоящая причина прежнего ×0.15: **`IQ4_KS`, `IQ4_K` и все `_R*` в `ggml-vulkan.cpp` отсутствуют**,
плюс слитая операция up-gate там тоже отсутствует, а она включена по умолчанию. Один флаг
`-no-fmoe` превратил 1.68 в **9.16 ток/с**.

Схема с резидентными экспертами реализована и **верна**: 3072 слота сверены с набором на хосте,
расхождений 0; в слотах, которых устройство не считало, ровно нули; попаданий на генерации 59.7%.
Но она **в 2.6 раза медленнее** (3.89 против 9.98), и причина структурная: перепакованный
`iq4_xs_r8` карта не понимает, поэтому `--no-repack` вынужден, а перепаковка стоит +34%. Потолок
схемы при нулевых накладных расходах — 14.7 против 13.38, то есть 10%.

Развязка: в оперативной памяти держать перепакованное, в видеопамять грузить плоские байты из
отображённого файла. Тогда потолок возвращается к 20+.

### Карта считает точнее процессора

Против эталона двойной точности, те же байты, одно умножение: F16 — процессор 2.1e-4, карта
1.2e-7; Q6_K — 5.3e-3 против 9.7e-8; **IQ4_XS — 5.0e-2 против 9.4e-8** при систематическом сдвиге
масштаба 0.9953. Причина: процессорные ядра `iqk` квантуют вектор активаций, чтобы считать в целых.

Два следствия. Разделение между устройствами **улучшает** качество (целый слой на процессоре
1.11e-1, разделённый 5.87e-2). И **совпадение токенов больше не годится как гейт** — карта
расходится с процессором законно, потому что она права.

### Зонный KV закрыт

×0.46 на 2048, ×0.51 на 8192, ×0.60 на 16384 при честной экономии байт кэша в 1.86 раза. Добавленный
счёт (поворот Адамара, разбор сжатого хвоста, четыре маскированные зоны) дороже экономии. И приём
вытесняется переносом кэша в видеопамять: сокращать чтение из оперативной памяти незачем, если
читать будем из видео.

**Правило из этого:** байты переводятся в скорость один к одному, только пока приём не добавляет
вычислений. Как только добавляет — надо мерить, а не считать.

## Приоритеты после 26 августа

**Единственное живое направление — резидентные эксперты в видеопамяти с одновременным счётом.**
Реализовано, проверено (3072 слота, расхождений 0, попаданий 59.7%), упирается в несовместимость
перепаковки с вулкановским бэкендом. Расчётный потолок с развязкой — 20+ ток/с.

**Спекуляция закрыта по цене.** Лучшее плечо 13.78 против базы 14.04 — минус 2%. Порог
окупаемости: приёмка выше 66.5% (измерено 60.9%) или черновик дешевле 18.3 мс (измерено 22.3).
Глубина не спасает: цена черновика линейна, принятое затухает геометрически — приёмка на
предсказанный токен падает 60.9% → 52.5% → 46.6% → 37.1% при глубине 2 → 3 → 4 → 6, а скорость
13.78 → 11.13 → 9.76 → 8.62. Даже при идеальной работе двух оставшихся рычагов потолок — плюс
пять-десять процентов за механизм с отбраковочным сэмплированием, вторым графом и второй моделью
в памяти. Не стоит работы.

**Разреженность активаций закрыта окончательно, с двух сторон.** Вход в блок MoE — плотный почти
гауссов вектор, оракул освобождает ноль блоков при 5% ошибки. Промежуточный `silu(gate)·up`
поэлементно **разрежен** (22% элементов при 2.5% внесённой ошибки, то есть литературные ~17%
подтверждены), но выровненных блоков по 32 — 0.003%, а жадный оракул при бюджете 5% освобождает
0.09% строк `down`. `down` — треть байт эксперта, значит это 0.03% байт. Плюс маска
перебрасывается каждый токен (Жаккар 0.1, ни одного измерения, малого более чем у 90% токенов, ни
в одном из 47 слоёв), то есть её пришлось бы считать в рантайме — дороже экономии.

### Организационное: агенты и очередь надо разграничивать по одному владельцу, а не по памяти

Разбросы 26.3% / 19.3% / 16.1% в плечах спекуляции по глубине 3/4/6 — от столкновения: очередь
гоняла `llama-cli`, а агент одновременно `llama-memex-fwd`. Оба прошли свои проверки «памяти
достаточно» **независимо**, и оба оказались правы по отдельности и неправы вместе.

Проверка по свободной памяти этого класса не ловит: два процесса по 7 и 15 ГБ на 32 ГБ машине
проходят порог каждый. Нужен **единственный владелец машины** — файл-замок, а не оценка ресурса.

## Potolok schemy s kartoj, pereschitannyj posle pochinki chtenija KV

Worth re-deriving, because the KV-read fix changed the denominator this whole design is measured
against, and the earlier estimate was made before it.

Per token at -c 2048 the engine reads 1.804 GB, and that number is trusted: 1.804 GB / 72.7 ms is
exactly 24.8 GB/s, the machine's measured bandwidth. Experts are about 1.5 GB of it. The card
currently holds 768 experts, 1.93 GB, and the resident-set simulation on real router traces gives a
59.7% hit rate at that capacity.

    CPU keeps          ~0.9 GB / 24.8 GB/s  =  36 ms
    card takes         ~0.9 GB / 131 GB/s   =  6.9 ms   (hidden under the CPU's 36)
    rendezvous          48 layers x 177 us  =  8.5 ms   (measured floor 11.6-13.0 ms)
    -------------------------------------------------------------
    together                                  ~45-49 ms  =  20-22 tok/s

Against the 14.04 tok/s baseline that is the target the user asked for, so the design is worth
finishing rather than replacing.

Two things this makes explicit that were not before:

The rendezvous is not overhead to be tuned away, it is a quarter of the result. The GPU's own
compute (6.9 ms) is smaller than the cost of handing the answer back (8.5-13 ms). Small transfers
here are latency-bound - a 16 KiB round trip costs 177 us regardless of size - and the per-layer
sync cannot be batched away, because layer L+1 needs layer L's combined output. Forty-eight
rendezvous is structural for this model. So effort spent shrinking the per-layer handoff pays as
much as effort spent enlarging the resident set.

And the hit rate matters less than it looks. Going from 59.7% to 70% moves the CPU's share from
0.9 to 0.75 GB, which is 36 -> 30 ms, about 2 tok/s. Going from a 13 ms rendezvous to 8.5 ms is
worth about the same. They are the same size of lever, and the second one is not currently being
worked on.

## KV na karte - eto ne dopolnenie k razdeleniju ekspertov, eto bolshij rychag

Geometry from the file rather than from memory: 48 layers, 32 query heads, 4 KV heads, head_dim
128. Grouped-query attention makes the cache small per token - 96.0 KB for K and V together across
all 48 layers - but it is read in full on every generated token, so its cost scales with how much
context is actually occupied:

    occupied   cache     read on CPU     read on card
      2048    192 MB        7.6 ms          1.4 ms
      8192    768 MB       30.2 ms          5.7 ms
     16384   1536 MB       60.5 ms         11.5 ms
     32768   3072 MB      121.0 ms         22.9 ms

At 16k occupied the cache costs more per token on the CPU than the entire token costs today. That
is the regime this model is actually for - Coder, with a long file in context - and it is not the
regime any benchmark here has measured: generating 256 tokens from a short prompt fills about 300
slots no matter what -c says, which is why the measured budget at -c 16384 was 1.942 GB rather than
the 3.0 GB a full cache implies. Every speed number in this project is a short-context number.

So the ordering changes. The expert split moves roughly 0.9 GB per token onto the card and buys
about 6 tok/s. Moving a filled 16k cache buys 49 ms per token, and at 32k it buys 98 ms. The
largest remaining lever is the one the user named first.

Two consequences that were not obvious before:

The card cannot hold the cache while the CPU computes attention - reading it back per layer would
cost more than it saves - so KV in VRAM implies attention on the card as well. That is not extra
work so much as a different boundary: the card owns attention and its share of the experts, the
CPU owns the rest of the experts, and the per-layer rendezvous already being built is the same
rendezvous. The design does not fork, it widens.

And zoning reverses sign. Zoned KV measured 0.46-0.60x on the CPU and was closed as a loss, because
it trades bytes for compute and the CPU had no compute to spare. The card has 131 GB/s against a
job that will not fill it, so the same trade is nearly free there - and zoning is what makes 32k
fit at all: 3072 MB exact does not fit beside 1930 MB of experts in 3.98 GB, 1723 MB zoned does.
A technique closed on one processor is not closed on the other.

## Chto na samom dele chitaetsja na tokjen - i pochemu ocherjod byla nepravilnaja

Measured off the file, not estimated. Per generated token mx1 reads:

    vnimanie (48 sloev, celikom)      510.4 MB    30%
    golova output.weight              243.4 MB    14%
    marshrutizator ffn_gate_inp        48.0 MB     3%
    ------------------------------------------
    statika, odna i ta zhe kazhdyj raz 801.8 MB    47%
    eksperty (8 iz 128 na sloj)       911.6 MB    53%
                                     ---------
                                     1713.5 MB  (izmereno 1.804 GB - raznica eto KV i normy)

token_embd is another 243.4 MB in the file but only one row of it is read, so it stays in RAM.

The static half is the better thing to put on the card, and by a wide margin:

    802 MB VRAM  ->  26 ms/token saved, no policy, no prediction, no eviction, no churn
   1930 MB VRAM  ->  18 ms/token saved, and the entire resident-set machinery

Twice the VRAM for less benefit. This was not visible while the experts were the subject: they are
the biggest thing in the file (14.6 GB of 15.3) and it is easy to read that as "the experts are the
cost". They are not. Only 8 of 128 are touched per layer, which takes 14.6 GB of storage down to
911 MB of traffic - while attention is small in the file and read in full every single time.

Storage size and traffic are different quantities, and the resident-set work has been optimising
the one that is 53% of the problem while ignoring the one that is 47% and free of policy.

A second correction, of my own earlier claim: mx1 needs no requantisation for this. Its tensors are
IQ4_XS (23), Q8_0 (8) and Q6_K (14), and all three are supported by the Vulkan backend - 25, 45 and
21 mentions in ggml-vulkan.cpp. IQ4_KS (144) appears zero times, but mx1 does not contain it; that
type was in the mx1r recipe, not this file. The types blocker applies to the repacked _R8 forms
only, which is exactly what the repack-exclusion work removes for the expert tensors.

## Pereschitannyj plan, po ubyvaniju otdachi na megabajt VRAM

VRAM is 3980 MB usable. Attention weights and the KV cache have to travel together - splitting them
would put the projections on the card and the KQ product on the CPU, three rendezvous per layer
instead of one - so the boundary is: the card owns the whole attention block, the head and the
router; the CPU owns most of the experts.

    statika (vnimanie + golova + marshrutizator)   802 MB
    KV pri 16k zanjatogo konteksta                1536 MB
    ostajotsja na populjarnyh ekspertov           1642 MB   (~690 shtuk, ~11%)

Expected, against today's numbers:

    korotkij kontekst   72.7 ms  ->  ~41 ms   =  ~24 tok/s
    16k zanjato        133.2 ms  ->  ~52 ms   =  ~19 tok/s

The second line is the one that matters for a coding model, and today it is 7.5 tok/s.

## Raspisanie odnogo sloja, i gde processor prostaivaet

The plan is only worth what its schedule allows, so this is the per-layer timeline rather than a
sum of bandwidths. Layer order is attention, then router, then the MoE - and each stage needs the
previous one's output, which bounds what can overlap.

    card:  attention (weights 10.6 MB + KV 32 MB at 16k)   ~0.35 ms
    CPU:   idle
    ---- rendezvous: hidden state to the CPU
    card:  its share of the experts                        ~0.03 ms
    CPU:   its share of the experts                        ~0.34 ms
    ---- rendezvous: partial sums combined

Over 48 layers: attention 17 ms with the CPU idle, experts 16.5 ms with both busy, rendezvous about
10 ms. Roughly 43 ms per token, 23 tok/s, at 16k occupied context where today's figure is 7.5.

The 17 ms of CPU idle is structural and should not be optimised away by guessing. The obvious
overlap - let the CPU start its experts for layer L while the card does attention for layer L -
does not exist, because the router that picks those experts runs after attention. And the other
obvious one, running layer L+1's attention early, needs layer L's output. Sequential dependencies
are what they are.

What this does say is that attention and the KV cache must land on the same processor. Splitting
them - projections on the card, the KQ product on the CPU - turns one rendezvous per layer into
three, and a rendezvous costs 177 us regardless of size. Three per layer over 48 layers is 25 ms,
which is larger than the entire attention stage being moved.

So the build order follows the schedule, not the byte counts:
  1. attention + head + router onto the card, weights uploaded once, no residency policy at all
  2. the KV cache onto the card, because attention there without it is the split that costs 25 ms
  3. the resident expert set into whatever VRAM is left
Step 1 is the largest single win, needs no policy, and is the least code.

## Proverka plana do ego napisanija

The boundary in 8.41 - card takes attention, head, router and the KV cache, CPU keeps the experts -
turns out to be expressible with a flag the fork already has:

    -ngl 99 -ot "exps=CPU"

So the premise is measurable now rather than after the module exists. This does not change what
gets built: the user asked for our engine, not the fork, and the module still has to be written
there. It changes when we learn whether the plan is right - before writing it instead of after.

The habit worth keeping: before building a mechanism, look for an existing flag that expresses the
same boundary badly. A slow, awkward version of the right split answers the question the fast
version was going to be built to answer, and it answers it tonight.

One arm doubles as a test of something else we needed to know: whether -rtr respects -ot placement.
If it repacks only host-resident tensors, that is the experts-only boundary the repack parameter is
being built for, and the parameter is a convenience. If it repacks everything and the device
tensors break - none of the _R8 forms exist in the Vulkan backend - the parameter is load-bearing.

## Podderzhka Gemma 4 i Qwen3.6 35B v nashem dvizhke: chto realno stoit

The engine is written for one architecture and refuses the rest politely rather than crashing.
Adding these two is not one task, it is two very different ones.

Gemma 4 26B-A4B - tractable, roughly 600-900 lines:
  - sliding window of 1024 on 25 of 30 layers, with the windowed KQ mask that implies
  - head_count_kv stored per layer as an array (8 on windowed layers, 2 on full ones)
  - two head_dims, 512 on full layers and 256 on windowed ones, each with its own rope base
    (1e6 and 1e4) and its own rope dimension count
  - ffn_gate_up_exps is a single fused tensor, not the separate gate and up this engine assumes
  - separate .scale tensors for ffn_down_exps and ffn_gate_inp
  - a dense FFN in every layer alongside the MoE, not instead of it
  - extra norms: post_attention_norm, ffn_norm, post_ffw_norm, post_ffw_norm_1/_2,
    pre_ffw_norm_2, layer_output_scale
  - no output.weight at all: the head is tied to token_embd

Qwen3.6 35B-A3B - substantially larger, and not a variation on anything present:
  30 of its 40 layers are not attention. They carry ssm_conv1d, ssm_a, ssm_alpha, ssm_beta, ssm_dt,
  ssm_norm and ssm_out with attn_qkv and attn_gate - a gated delta-net, a different sequence-mixing
  primitive with a fixed-size recurrent state. Only 10 layers have attn_k and a KV cache. It also
  has shared experts (ffn_*_shexp in all 40 layers), which are always active and belong to the
  static traffic rather than the expert traffic.

So the split that gets the user a real speedup soonest: Gemma into the engine, and the 35B
optimised through the fork now. The fork supports both architectures already (GEMMA4 appears 32
times in src/llama.cpp, qwen35 8 times), and its -ot flag expresses exactly the boundary this whole
plan is built on:

    -ngl 99 -ot "exps=CPU"

That is the static half plus the KV cache on the card and the experts on the host - the same split
the module is being written to do, available today for models the engine cannot load. It is worth
measuring on all three before deciding how much engine work each model deserves.

## Predskazuemost vybora ekspertov: zamer, a ne dogadka

The proposal was to give each expert a probability of use over the next 5-10 tokens, keep the most
probable resident, and refresh periodically. Measured on the real router trace (47 layers, 2190
tokens, top-8 of 128) rather than argued about.

Persistence, share of a token's experts that also appear k tokens later, against a 6.25% random
floor:

    k=1  47.8%    k=2  37.6%    k=3  40.3%    k=5  49.5%    k=10 42.1%    k=20 52.3%

It does not decay with k - 20 tokens out is higher than 2. So this is not short-range momentum, it
is a stable preference across a stretch of context, which is the better of the two possibilities
for a resident set: the set does not need refreshing as often as the proposal assumed.

Window coverage - the union of the last W tokens' selections against the next 10 tokens' needs:

    W=8   85.0%, holding 23.3 experts of 128     W=32  94.4%, holding 36.2
    W=16  91.3%, holding 29.5                    W=64  96.8%, holding 44.1

Three policies at equal capacity C per layer, window 32, refreshed every 4 tokens:

       C     LFU    recency-weighted    oracle
       8   54.2%        55.3%           65.3%
      16   76.2%        77.4%           91.0%
      24   87.0%        88.1%           99.7%
      32   91.8%        92.4%          100.0%

Two conclusions, and the second is the one that matters.

The proposal works but the version this trace can express - weight recent selections more heavily -
is worth about one point over plain LFU. Consistent across every capacity, and free, so take it;
but it is not the win.

The oracle says roughly fifteen more points are available at C=16. That gap is not capacity and it
is not the workload being unpredictable - it is the predictor. And the proposal's strong form is
exactly the thing that should close it: rank by the router's probability mass rather than by how
often an expert crossed into the top-8. An expert sitting consistently ninth by probability never
earns a count, yet it is precisely the one about to enter the top-8. That could not be tested here
because this trace stores selections only, with no distributions - so the next step is to re-record
it with full router output.

Practical effect on the 30B: the VRAM left for experts after the static half and the KV cache is
1642 MB, which is C≈14 per layer, so about 73-76% hits - materially better than the 59.7% every
earlier estimate in this file was built on.

## Sostojanie na 26 avgusta, vecher

Idjot sejchas:
  - perezamer treh modelej (30B, Gemma 4 26B, Qwen3.6 35B), tri povtora, posle pochinki $P/$p
  - perezapis trassy marshrutizatora s polnymi raspredelenijami (MOE_TRACE_PROBS)
  - potok arhitektur: chitaet fork po gemma4 i qwen35moe, dolozhit do koda
  - potok karty: parametr perepakovki, zatem statika na kartu

Zakryto zamerom, ne otkryvat zanovo:
  - spekuljacija: luchshee plecho 13.78 protiv bazy 14.04. Zagrjaznjonnye plechi pereměrjat ne
    nuzhno - zagrjaznenie mozhet tolko zanizit, a luchshij povtor kazhdogo nizhe bazy.
  - chtenie KV: bylo pereChitanie v 11.6 raza, ispravleno aim_kv_reads, bjudzhet 3.414 -> 1.942 GB
  - zonnyj KV na CPU: 0.46-0.60x. Na karte znak menjaetsja - schjot tam pochti besplatnyj.
  - marshrutizator v f16: 1.4% bjudzheta na CPU, a po novomu planu on celikom uezzhaet na kartu,
    tak chto voprosa bolshe net. Nedopisannyj mx1r udaljon.

Otkryto i vazhno, po ubyvaniju:
  1. statika na kartu - 802 MB daet 26 ms/tok na 30B, bez vsjakoj politiki. Randevu s"est 8.5 ms
     iz nih (48 sloev po 177 us na kruguju poezdku), chistymi ~17.5 ms.
  2. KV na kartu - pri 16k zanjatogo konteksta 60.5 ms na CPU protiv 11.5 na karte
  3. rang po verojatnostnoj masse - orakul obeshchaet +15 punktov k 76.2% pri C=16
  4. Gemma i 35B v nash dvizhok
  5. Coder-Next: 38.68 GB pri 31.9 GB OZU - fajl zhivjot na diske, vopros v dole strannichnogo kesha

Moi oshibki za vecher, chtoby ne povtorjat:
  - schital, chto eksperty - glavnaja cena, potomu chto oni 14.6 GB iz 15.3. Trafik i razmer
    hranenija - raznye velichiny; statika okazalas 47%.
  - vse zamery proekta byli korotkokontekstnymi i nikto etogo ne zametil
  - chital head_count_kv kak skaljar: pereocenil kesh Gemma v 14 raz, 35B v 4 raza
  - postavil nevernyj diagnoz odnovremennomu vyvodu v odin fajl i uspel vpisat ego v kod
  - povtoril kollisiju $P/$p, kotoraja uzhe stoila odnogo svipa

## Coder-Next: chto s nim delat, po chestnym cifram

Both quantisations are on disk. Recomputed after fixing the tensor-size method (see METHODS 46 -
the first pass reported this model's static half as 5119 MB and 88% of traffic, which was an
artefact of padding, not a measurement).

                        statika    eksperty   na tokjen   potolok CPU   fajl
    IQ3_XXS            1762 MB     491 MB     2253 MB      11.3 tok/s   26.5 GB
    IQ4_XS             2152 MB     667 MB     2819 MB       9.0 tok/s   38.7 GB

It is a hybrid like the 35B: 36 of its 48 layers are SSM with no KV cache, so the cache is only
384 MB at 16k occupied - the smallest of any model here despite being the largest model.

The RAM objection to the 4-bit file is weaker than it looks. 38.7 GB against 31.9 GB of RAM means
it cannot be resident, but it does not need to be: only 667 MB of experts are read per token, out
of 24576 experts (512 per layer, 10 used). The persistence measurement on the 30B says the working
set is about a quarter of a layer's experts; at the same ratio here that is roughly 2.7 GB of hot
experts, which the page cache holds comfortably. What kills a model on mmap is scattered reads
across the whole file, and this router does not scatter.

So the answer is not "3-bit because 4-bit does not fit". Both are runnable. The real difference is
the ceiling - 11.3 against 9.0 tok/s - and that the 3-bit's static half (1762 MB) leaves 1834 MB of
VRAM for experts against the 4-bit's 1444 MB. Whether that is worth the quality drop from iq3_xxs
and iq2_s experts is a quality question, and the error ladder says iq3 costs 15.86% against iq4's
7.60%, which is a large step. Worth measuring both rather than deciding on the file size.

## Polnaja shema: statika + populjarnye eksperty na karte, ostalnye na CPU

Computed in memex/plan_speed.py from the measured terms: 24.8 GB/s host, 131 GB/s device, 177 us
per rendezvous, 31 us per dispatch, and the hit rates from the router trace (C experts per layer:
8->54%, 16->76%, 24->87%, 32->92%, capped at 96% because the trace never showed better).

                       korotkij kontekst        16k zanjato       protiv bazy
    Qwen 30B           24.2 tok/s  (26/sloj)    18.1              1.8x / 2.3x
    Gemma 4 26B        28.9        (19/sloj)    26.4              3.2x
    Qwen3.6 35B        22.8        (19/sloj)    21.2              2.6x
    Coder-Next 3bit    22.8        (44/sloj)    21.6              2.1x

The target is met everywhere except the 30B at long context.

The breakdown is the interesting part. For the 30B at short context:

    vnimanie   5.2 ms      MoE  6.0      golova 2.2      randevu 8.5      ZAPUSKI 19.3
                                                                          total 41.3

Kernel dispatches are the largest single term - larger than attention, the MoE and the head
combined. With the rendezvous, 27.8 ms of 41.3 is overhead rather than data movement. Once the
weights are on the card the bottleneck stops being bandwidth and becomes launch count, which
inverts the priority list: fusing operations into fewer kernels is worth more than fitting more
experts into VRAM. Halving the dispatch count takes the 30B from 41.3 ms to 31.6, or 31.6 tok/s.

The honest caveat: 13 dispatches per layer is an estimate, not a measurement, and it is the least
reliable term in the model. The 31 us per dispatch, the 177 us rendezvous and both bandwidths are
measured. The dispatch count has to be read off the actual graph, and that is the first thing to
check once the card path runs - if it is 20 rather than 13, the 30B lands at 32 ms of overhead and
the whole ranking changes.

Gemma comes out best for two reasons at once: its static share is 67% rather than 47%, and its
sliding window on 25 of 30 layers keeps the cache at 520 MB even at 16k.

## Zapuski jader: samyj vazhnyj neizmerennyj chlen, i on ne to, chem kazhetsja

The plan estimated 13 dispatches per layer. Counted off the actual graph body in build_step
(memex-fwd.cpp:1279), our engine creates 43 node-producing ops per layer: 7 mul_mat, 5 add, 4 cont,
4 cpy, 4 mul, 3 mul_mat_id, 2 rope_multi, 2 get_rows, soft_max_ext, soft_max, top_k, top_k_thresh,
repeat, step, cont_2d.

At 31 us each that is 64.0 ms per token of launch cost alone - more than the entire token costs on
the CPU today. Taken at face value the whole card plan is a loss rather than a 1.8x win.

It should not be taken at face value, for two reasons, and the difference between them is the
difference between the plan working and not.

First: only the card's share of the graph becomes a Vulkan dispatch. Under the planned boundary the
card runs attention, the head, the router and its slice of the experts - roughly 15-18 of those 43
nodes. The CPU's nodes cost CPU time, which is already counted in the bandwidth term.

Second, and this is the one that actually decides it: the 31 us figure was measured as the
latency of a single kernel, launch to completion. That is not the same quantity as the marginal
cost of the fifteenth kernel in a command buffer that was submitted once. Dispatches inside one
submit pipeline on the GPU; if the marginal cost is 5 us rather than 31, fifteen nodes per layer
cost 3.6 ms instead of 22.3, and the plan's numbers stand. If it really is 31 us serial, the plan
needs the graph fused down to a handful of nodes per layer before it is worth anything.

So the next measurement is not another arm of the speed table. It is: submit N identical small
kernels in one command buffer, sweep N, and read the slope. The slope is the marginal dispatch
cost, and it is the term the entire design now rests on. The intercept is the submit-and-fence
cost, which is the rendezvous term measured independently.

Until that slope is known, every tok/s figure in the section above is conditional on an assumption
I have now shown was picked out of the air.

## Cena dispatcha izmerena: 27.24 mks, i chto iz etogo sleduet

The hope was 5 us. Measured (examples/memex-vkdisp, sweep over node count, fitted slope):

    zavisimaja cepochka   27.24 mks/uzel, svobodnyj chlen 17.4 mks
    nezavisimye uzly      26.83 mks/uzel, svobodnyj chlen 21.2 mks
    otnoshenie            1.02x

Independent nodes cost the same as a dependent chain, so nothing is being serialised by the data
dependency - the launch itself is the cost, and parallelism does not help. Only fewer nodes help.
The slope is essentially the 31 us round-trip figure, so dispatches inside one command buffer do
NOT pipeline in any way that matters here.

The intercept is 17.4 us, not 177. That does not contradict the rendezvous measurement, it locates
it: 177 us is host-side coordination - worker thread wakeup, mutex, condition variable - and only
17.4 us of it is the submit and fence. Worth knowing, because the two are reduced by different
means: fewer submits helps the 17.4, a leaner handoff helps the 177.

Effect on the plan: 15 card-side nodes per layer x 48 layers x 27.24 us = 19.6 ms per token on
launches alone, against the 19.3 ms the plan assumed with 13 nodes at 31 us. The estimate survives
by coincidence - two wrong numbers cancelling - but it is now measured rather than guessed.

That makes launches the largest single term, 19.6 ms of about 41. Fusing the per-layer graph from
15 nodes to 8 saves 9.1 ms and takes the 30B from 24 to 31 tok/s. That is a bigger lever than any
amount of extra VRAM for experts, and it is now the first job.

## Gde nasha shema obgonjaet vygruzku celyh sloev

    kontekst 2048, baza 13.3 tok/s        kontekst 16384, baza 7.8 tok/s
    VRAM    celye sloi   nashe            VRAM    celye sloi   nashe
    2000    13.2         19.5             2000     8.0         ne vlezaet
    3980    13.1         24.1             3980     8.4         18.0
    8000    12.9         23.8             8000     9.0         19.2
    16000   12.5         23.6             16000   10.8         19.1

    perelom: 1000 MB = 6.5% modeli pri 2k,  2350 MB = 15.2% pri 16k

The threshold exists and it is low - we are past it with room to spare at 3980 MB, which is 26% of
the model. But the flatness of the whole-layer column is the real finding: it barely beats the CPU
baseline at any VRAM size, and at short context it is actually slightly worse.

The reason is one number. A layer offloaded whole must hold all 128 of its experts, because the
router may pick any of them, and it reads 8. Bytes read per token per byte resident:

    celyj sloj                317 MB rezidentno, 29.7 MB chitaetsja   0.09
    nashi populjarnye eksperty                                        0.27
    nasha statika             802 MB rezidentno, 802 MB chitaetsja    1.00

Static is the only thing that scores 1.0: every resident byte is read on every token. Whole-layer
offload spends VRAM on experts it will never read, and that is why more VRAM does not help it.

So the threshold is not really about card size. It is about the point at which there is enough room
for the static half, after which you stop paying for bytes nobody reads.

## Gemma 4 i Qwen3.6 v nashem dvizhke: chto sdelano i chto vyjasnilos

Both graphs are built - per-layer HParams (LayerGeom: ATTN / ATTN_SWA / DELTA_NET), widened Graph
and Cache, build_gemma4_step and build_qwen35_step, delta-net state in the Generator, and
--decode-check for the carried state. Not compiled yet: the machine is held by measurements.

**The find that matters beyond these two models: ggml_mul_multi_add.** The MoE tail written the
obvious way - multiply by routing weights, add eight slices, fold Gemma's ffn_down_exps.scale by
hand through repeat_4d/get_rows/mul - is 11 nodes. The fused op is 1, bit-identical, forming
s = w[j]*scale[id[j]] once per slot and accumulating from slot zero upward. Across Gemma's 30
layers that is ~300 nodes, about 8.2 ms per token at 27.24 us.

And it is a correctness improvement, not only a speed one: cparams.fused_mmad defaults to true, so
the llama_decode we compare against already takes that path. A comparison against a route the
reference does not take proves less than it looks.

**Node counts as built are far above what the card plan assumes.** Gemma ~39 per layer (~1170
total), Qwen3.6 ~38 on delta-net layers and ~40 on attention (~1530). Our own qwen3moe layer is 43.
The plan is priced at 15 device-side nodes per layer. Those are not the same quantity - most nodes
will stay on the CPU - but the device-side split has never been counted, and at 27.24 us the
difference between 15 and 39 is 31 ms per token on Gemma alone.

What an aggressively fused MoE layer can be, counting the irreducible work: norm (fused rms+mul),
qkv (1 if fused, else 3), rope q and k (2), kq / softmax / kqv (3), output projection (1), residual
(1), ffn norm (1), router matmul + softmax + top_k (3), up/gate/down as mul_mat_id (3, or 1 fused),
mul_multi_add (1), residual (1). That is 15-18, so the plan's 15 is reachable but only with the
fusions actually taken. We are at 43.

**Dead code found in ggml:** the plain-C fallback for GGML_OP_DELTA_NET indexes g and beta as
[head][token]; the iqk kernel that actually runs indexes them [token][head], which is what the
permuted views produce. The fallback is the transpose of the real thing and never executes on this
machine. Also, q and k are L2-normalised in the graph and the iqk kernel relies on that - it takes
a bare dot product with no renormalisation, unlike the fallback.

**Interface change other code must know about:** Cache::k[il] and Cache::v[il] are now null on
layers with no KV cache - 30 of Qwen3.6's 40 - and Cache::bytes() is a per-layer sum rather than
n_layer * 2 * n_ctx * d_kv * 2. Any memory accounting that assumed uniform layers is wrong now.

## Cena raboty s kartoj, razlozhennaja: submit, ustrojstvo, zapis komand

Two independent methods, agreeing:

    vkQueueSubmit          24.1 mks/uzel    raznost naklonov paketnogo i pouzlovogo rezhimov
    ispolnenie na GPU      2.2-3.5          metki GGML_VK_PERF_LOGGER, podgonka mean(N)=D+gap/N
    zapis komand na hoste  0.06-0.93        naklon processornogo vremeni processa po N

So both routes we were weighing are closed by measurement rather than opinion. An own command
buffer would target host recording, measured at under a microsecond per node. A persistent kernel
would target device execution, measured at 3 us per node out of a 41 ms token. Neither pays.

**The 27.24 us figure was an artefact of the probe, and the cause is proven.** ggml's Vulkan backend
picks submit points by `mul_mat_bytes >= total_mat_mul_bytes / 40` (ggml-vulkan.cpp:10353). The
probe's graph was a chain of adds with no matmul at all, so the threshold was zero and `0 >= 0` held
at every node: it timed 64 graphs of one node each, not one graph of 64. The proof is two graphs
differing by one row of an 8-element matrix - a 32-byte src[0] gives 32/40 = 0 and submits per node
(27.05 us/node), a 64-byte one gives 1 and batches (3.27 us/node).

Worth keeping as a lesson in its own right: the synthetic probe was built to isolate one cost and
its very simplicity - no matmul, because matmuls would have added bandwidth to the thing being
timed - is what triggered a different code path from the real workload. Removing everything
irrelevant removed the thing that made the measurement representative.

**Where the real cost is: submit granularity, not node count.** The same threshold means a graph of
N matmuls gets a submit every ceil(N/40) nodes - which is every node for any N up to forty:

    matumnozhenij   vsego mks   mks/uzel
             8         185.4      23.17
            15         244.6      16.30
            45         322.4       7.16
           240         803.8       3.35

A 15-node layer graph costs 245 us. Over 48 layers that is 11.7 ms per token. The same 720 nodes
handed over as one graph cost about 2 ms. So the card module must submit one graph per token, not
one per layer - and the current fork/join design does exactly the wrong thing, calling
graph_compute per layer. That is a 9.5 ms design constraint, and it was invisible until now.

**Nothing overlaps on the device, ever.** ggml_vk_sync_buffers (ggml-vulkan.cpp:1728) is a full
pipeline barrier over all shader and transfer reads and writes, and every op wrapper calls it before
its dispatch unconditionally, without checking whether the tensors overlap. Chain versus fan-out in
batched mode measures 1.003x. Any design that assumed two independent dispatches could run together
is wrong.

**Fusing is not unconditionally good.** Below 64 KiB per node it wins 2-3x; above about 4 MiB it
loses - 32 chained 1-MiB adds beat one 32-MiB add by 1.8x, because the fused version's working set
leaves the card's 16 MB cache. So fuse the small stuff and leave the big matmuls alone.

**Correction to my own reading:** the 17.4 us intercept looked small because the submit was inside
the slope, not outside it. The real floor for a graph_compute ending in a fence is about 59 us with
a single node in it - much closer to the independently measured 177 us rendezvous than 17 us was.

## Granica prohodit po sloju, a ne po uzlam - i pochemu eto ne ochevidno

Counting the graph gave a reassuring number and a dangerous one in the same breath.

Reassuring: of Gemma's 39 nodes per layer, only **11 are device candidates** - four attention
projections, two KV-cache matmuls, the dense FFN's fused up-gate and its down, the router, and the
two expert ops. The card plan's budget of 15 device-side nodes per layer is not blown; the 39 was a
host-side total. Model totals: Gemma 1176 nodes of which 330 are weight- or cache-bound, Qwen3.6
1604 of which 550.

Dangerous: those 11 are **interleaved** with the other 28. Cutting the graph wherever the device
nodes are would cross the CPU/GPU boundary about twenty times per layer.

A crossing costs 177 us of host-side coordination, measured independently of any GPU work. So:

    po uzlam        ~20 peresechenij/sloj x 48 = 960  x 177 us = 170 ms   absurd
    po blokam        ~4                    x 48 = 192  x 177 us =  34 ms   dorozhe vsego vyigrysha
    po sloju            1                  x 48 =  48  x 177 us = 8.5 ms   bjudzhet plana

Which means the 28 host-side nodes - norms, ropes, softmaxes, almost no bytes in them - must run on
the card as well. On the device they cost about 3 us each, so 28 x 3 x 48 = 4.0 ms for Gemma,
against the 26 ms of extra crossings that keeping them host-side would cost.

The lesson is the one worth carrying: **cheap in bytes is not cheap in place.** These nodes were
never going to be worth moving on their own merits - they move almost nothing - but leaving them
behind creates a boundary, and the boundary costs forty times what the work does. The unit of
placement is not the operation, it is the cut.

So the boundary is: the card runs the entire layer graph except the CPU's slice of the experts. One
handoff per layer. The 11-versus-28 split stops mattering, which is the point.

Consequence to design in now rather than discover later: Qwen3.6's delta-net layers carry recurrent
state that ggml_delta_net reads and writes - 2.20 MB per layer, 65.9 MB for all thirty. If those
layers run on the card, the state lives there and is updated in place. It must never be mirrored to
the host per token.

## Otkrytyj vopros: 11.1 tok/s protiv bazy 14.04, mashina byla tihoj

The three-model table gave mx1 at 10.87-11.12 tok/s with a 15.8% spread, on a machine with no
compiler running, 24.3 GB free and 0.5 GB of page file in use. The run itself is healthy: model
loads at 15.365 GiB, all 337 tensors repack, prompt eval 32.65 tok/s, eval 89.90 ms/token.

That is 20% below the 14.04 measured cleanly earlier today at a 2.0% spread, and 89.90 ms implies
2.23 GB per token against the 1.72 GB the file accounts for. So either something regressed or the
two numbers are not comparable.

Two candidates, and they are cheap to separate:

  - The arms differ: 14.04 was measured with -n 256, this table uses -n 192. A shorter generation
    puts more of the run into warm-up, but 27% is far more than that should buy.
  - Our patches to the fork touch the decode path of this exact model. build_qwen3.cpp changes only
    a callback label, which is free, and the additions to llama-build-context.cpp are gated behind
    MEMEX_SHARED_EXPERTS and MEMEX_CACHE_BONUS. But llama.cpp gained 135 lines and llama-build-
    context.cpp 160, and I have not verified that none of them costs anything when their flags are
    off.

The test is one run of mx1 with spec_study's exact arguments (-n 256), against this table's (-n
192), on the same binary. Until that is done, 11.1 is not reported as a result and 14.04 is not
assumed to still hold. Both numbers are suspect in different ways, which is exactly the situation
the spread flag exists to make visible rather than paper over.

## Popravka: submit ne na kazhdom uzle, a na kazhdom matumnozhenii

I put 17.4 ms/token on the board for submit cost, from 15 nodes x 48 layers x 24.1 us. That was
wrong twice over.

Only MUL_MAT and MUL_MAT_ID add to mul_mat_bytes, so nodes that are not matmuls never trigger the
byte rule. And the threshold doubles after each of the first three submits (submit_count < 3).
Measured on a chain of 15 matmuls, submits land at nodes 1, 2, 4, 7, 10, 13, 15 - seven, not
fifteen. A real layer has 5-7 matmuls among its ~15 nodes, so 5-7 submits per Vulkan split, and the
item is **6-8 ms per token, not 17.4**.

Still the largest single line, still worth the sweep, but the plan carries the measured number when
it arrives rather than my estimate.

## Vtoraja cel evristiki otpravok, kotoruju ja propustil

I read the submit rule as one thing - batching to overlap host recording with device execution.
There is a second clause, `almost_ready`, and its consumer is ggml_vk_wait_for_fence
(ggml-vulkan.cpp:1166): the host does `waitForFences` on the almost-ready fence while most of the
graph runs, and only busy-spins with YIELD over the tail.

So that submit is not there to batch work. It is there to give the host something to **sleep** on.
Remove it and the host spins through the entire graph - and on this machine the host is not idle
during that time, it is running the CPU's share of the experts on eight threads. Buying one fewer
submit costs a core that was doing the work the whole design is built to overlap.

The general shape, worth keeping: a piece of code can have two purposes, and the second is often
visible only from its consumer rather than from the code itself or its comment. The comment here
describes the batching purpose accurately and does not mention the sleeping one at all.

A third constraint from the same place: the min(100 MB, ...) cap bounds how long a single submission
runs, and Windows kills a kernel at about 2 s. Turning the byte rule fully off removes that bound
and the failure mode is a device-lost, not a slow run. So the sweep prefers a small divisor to zero.

## Tablica trjoh modelej ot 26 avgusta: vybroshena celikom

Every arm above the 4.2% noise floor, the last one at 103.6%:

    30B mx1, rtr     10.87  (15.8%)    Gemma rtr    6.23  (28.3%)
    30B mx1, mmap    10.38  ( 7.6%)    Gemma mmap   5.39  (35.0%)
    35B Q6_K, mmap    5.04  (103.6%, 2.73/4.43/7.95)

Not reported as results. The cause was an external build - a different project compiling on this
machine for part of the evening - plus a harness that slept a fixed fifteen seconds between
replicates instead of waiting for the system to settle after a 16 GB process exits.

Worth keeping the row for the 35B: a 103.6% spread is not noise, it is a measurement of something
else entirely, and printing it as 5.04 tok/s without the spread would have been a plausible number
with nothing behind it. The flag earned its keep on this table more than anywhere else.

What the table would have said if it had held: the byte-budget ceilings are 14.7, 9.8 and 8.9 tok/s
for the 30B, Gemma and the 35B respectively. Any measured value materially below those is either
contention or a real inefficiency, and until the machine is quiet the two cannot be told apart.

## Plan, zadannyj polzovatelem 26 avgusta pozdno vecherom

  1. Coder-Next: zapustit v 3 bitah, zatem v 4, i optimizirovat
  2. Predskazanie ekspertov: dообuchit marshrutizator - kesh po tokenam i to, kakie eksperty
     ponadobjatsja na distancii, a ne tolko na sledujushchem shage
  3. DeepSeek - reshenie posle, i osnovanie nazvano verno: malo aktivnyh parametrov pri bolshom
     chisle postojannyh, to est imenno ta forma, pod kotoruju nasha shema i stroitsja

Punkt 2 - eto prjamoj udar v izmerennyj razryv. Pri 16 ekspertah na sloj obychnaja politika berjot
76.2% popadanij, orakul so znaniem sledujushchih chetyrjoh tokenov - 91.0%. Pjatnadcat punktov ne v
emkosti i ne v nepredskazuemosti nagruzki, a v kachestve predskazatelja.

Chto dlja etogo nuzhno i chego net: v trasse lezhat tolko sami vybory top-8, bez raspredelenij.
Rang po verojatnostnoj masse - imenno ta versija idei, kotoraja dolzhna razryv zakryvat, potomu chto
ekspert, stabilno zanimajushchij devjatoe mesto po verojatnosti, schjotchika popadanij ne nabiraet
nikogda, a vhodit v top-8 pervym. Zapis trassy s MOE_TRACE_PROBS postavlena v ochered; bez nejo ni
obuchit predskazatel, ni proverit ego nelzja.
