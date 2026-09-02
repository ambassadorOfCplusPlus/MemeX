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

## Dva istochnika predskazanija proverены i zakryty

Measured on the real router trace, 47 layers, 2190 tokens, top-8 of 128.

**The previous layer, within the same token: no signal at all.** Layer L's choices predict layer
L+1's at **6.0%** against a 6.25% random floor. The same layer one token earlier predicts at 48.2%.

This closes the most valuable idea available, so it is worth being precise about what was lost.
Every other predictor forecasts across tokens, so the earliest it can act is one token ahead. If a
layer had predicted the next layer, the prefetch could have started mid-token with 47 layers of
runway - a scheduling problem instead of a prediction problem. It does not.

But the negative result explains the shape of the whole task: the signal lives **inside a layer
across time**, not across layers. There is no global topic state propagating through the model;
each router decides on its own layer's features. Which is exactly why a predictor must be
per-model, and within a model per-layer - an expert index means a different thing in every layer,
and pooling them does not add data, it destroys the structure.

**Co-occurrence exists but is thin.** Experts travel in groups at a lift of 1.33 over independence.
Folding that into the frequency score buys +0.4 to +1.0 points:

       C    chastota   + sovmestnost    orakul
       8       54.2%          54.4%      65.3%
      16       76.2%          76.6%      91.0%
      32       91.8%          92.8%     100.0%

So the fifteen-point gap at C=16 survives both. What remains is ranking by the router's own
probability mass - the one version of the idea that needs the distributions, because an expert
sitting ninth by probability never earns a count and is exactly the one about to enter the top-8.
The trace recording is queued; nothing can be trained or checked without it.

## Regressija podtverzhdena: perepakovka poterjala pochti vsju cennost

First clean table in a day - every spread under the 4.2% floor, drift across rounds 2.3%, so the
machine held still. (That the drift is now small is itself the confirmation that the neighbouring
build was what wrecked the earlier tables.)

    n=256, rtr    12.95  (3.4%)      n=256, mmap   12.32  (3.7%)
    n=192, rtr    12.99  (2.4%)      n=192, mmap   12.45  (2.0%)

Two answers:

**The -n argument is not the cause.** 256 against 192 gives 12.95 and 12.99 - 0.3% apart. That
hypothesis is dead, and with it the hope that the two numbers were simply incomparable.

**There is a real regression: 12.97 against a clean 14.04, i.e. -7.6%.** And it sits where the
suspicion pointed: repacking now buys **+4.3%** (12.97 over 12.39) where it used to buy about +34%.

So the fault is in the repack path, and our own patches are the prime suspect - `repack_only`,
`repack_exclude`, and the new allocation with `padded_need` at 64-byte alignment, all added to
llama.cpp for the selective-repack work. The suspect list is short and the test is a bisect:
build with the allocation change reverted and compare.

Worth noting what made this findable. Three things had to be fixed before the measurement could say
anything: the $P/$p collision that silently killed replicates 2 and 3, the fixed sleep that let a
16 GB process's cleanup overlap the next replicate, and the neighbouring project's builds. Each was
diagnosed wrongly at least once. The number 12.97 was available all along; what was missing was a
machine quiet enough to read it.

## Gemma 4 v nashem dvizhke: gde ona lomaetsja, izmereno 27 avgusta

Both graphs compiled for the first time (the machine was held by measurements when they were
written). Gemma 4 runs end to end and its answer is wrong, and the fault is now located to a
single stage rather than described as "the numbers disagree".

### Chto izmereno

12-token prompt, `--probe all --decode-check 6`, `--no-repack`, t=8, per-layer comparison under
the reference's own node names:

    prefil, logity poslednego tokena   L2 414.33%   luchshij token: etalon '-', nash ' is'
    dekod, 6 shagov                    0 iz 6 sovpali, hudshij L2 420.92% na shage 0

1100-token prompt (the window-crossing arm), same binary:

    prefil, logity                     L2 386.91% pri ref-ubatch 512 (token SOVPAL)
                                       L2 264.37% pri ref-ubatch 1100 (token razoshjolsja)
    dekod, 4 shaga                     1 iz 4 sovpali

The 1100-token arm is **not** a second finding. Its first layer is already wrong, so nothing it
says about the 1024 window can be read - which is the whole reason the short arm had to run
first, and the reason it is worth writing down that for one evening it did not: the short arm's
prompt reached the engine unquoted and every word after "The" was rejected as a flag, so the
only Gemma data anyone had was the long arm's.

### Gde imenno, po stadijam vnutri odnogo bloka vnimanija

Probing the reference's intra-attention names on layers 0 and 1 puts the boundary between two
adjacent nodes:

    attn_norm-0        33792 znachenij   L2 0.0000%   max |d| 0.00000
    Qcur-0             49152             L2 0.0000%   max |d| 0.00000
    Kcur-0             24576             L2 0.0000%   max |d| 0.00000
    Vcur-0             24576             L2 0.0000%   max |d| 0.00000
    Qcur_normed-0      49152             L2 0.0000%   max |d| 0.00000
    Qcur_roped-0       49152             L2 0.0000%   max |d| 0.00000
    Kcur_normed-0      24576             L2 0.0000%   max |d| 0.00000
    Kcur_roped-0       24576             L2 0.0000%   max |d| 0.00000
    ---------------------------------------------------------------- vsjo vyshe BITOVO ravno
    kqv_out-0          33792             L2 217.66%   max |d| 69.34
    attn_out-0         33792             L2 147.95%   max |d| 471.24

Bit-identical, not "close": zero to the last digit on eight consecutive tensors. That is a much
stronger statement than a small L2 and it closes a long list of candidates outright.

**Zakryto etimi nuljami** (each was a live hypothesis before the run, and several were the
obvious first guesses):

  - the per-layer geometry. Layer 0 is a windowed layer, and it reads head_dim 256, 8 kv heads
    and rope base 1e4 - if it were falling back to the model-level 512 / 2 / 1e6, Qcur and Kcur
    could not be bit-equal. The `LayerGeom` table is being read and used.
  - q_norm and k_norm, both their weights and their placement relative to rope and to the
    per-head reshape.
  - the embedding scale sqrt(2816), attn_norm, and the whole path from token ids to Q/K/V.
  - the raw V projection, and `Vcur = Kcur` sharing on the five layers without attn_v (layer 0
    is not one of them, but Vcur-0 being exact rules out the projection itself).
  - the MoE tail entirely - the fused `ffn_gate_up_exps`, GELU against SiLU, the
    `ffn_down_exps.scale` fold - all of it is downstream of a block that is already wrong.
  - the sliding window. Every query in a 12-token prompt sees position 0, so the 1024 boundary
    is never approached and the windowed mask equals the causal one.

**Chto ostalos**, all between the rope and the output projection: the KQ product against the
cached K, the mask and the 1.0 softmax scale, the unweighted rms_norm on V, the cached V read,
or the `attn_output` matmul. A second probe pass over `kq`, `kq_soft_max_ext` and
`kqv_merged_cont` splits those four ways and is queued behind another job on the machine.

### Chto uzhe ispravleno po doroge (ne po dogadke - po ishodniku forka)

**Router scale.** `ffn_gate_inp.scale` as it sits in the file is not the tensor the reference's
graph sees: `llm_scale_gate_inp_s` (llama.cpp:3805, called from :4868) walks every gemma4 layer
at LOAD time and multiplies that vector in place by 1/sqrt(n_embd) = 1/53.066. Reading the
weight straight out of the gguf leaves the router logits 53x too large; softmax then collapses
onto the top expert, top-k picks the same eight (scaling is monotone) and the renormalised
weights come out near one-hot instead of a mixture. Nothing about the shapes, the names or the
generated text betrays it. Now applied to the router's normalised input in the graph.

This one is worth generalising: **a weight can be transformed between the file and the graph,
and reading the file correctly is then not enough.** Our engine reads tensors by name from the
same `llama_model` the reference uses, which makes it easy to assume the values match. They do -
until the reference edits one in place after loading. `llm_scale_gate_inp_s` is the only such
edit for these two architectures; it was found by grepping every `GEMMA4` mention outside the
graph builder, which is the check that should run for any new architecture.

**Odno imja - dva raznyh tenzora.** See METHODS 61. `attn_out` is pre-residual on the 25 layers
that go through `build_std_attention` and post-residual on the 5 that do not, so the probe was
reporting the residual as an error on 25 layers of 30 - 100-500% of pure artefact sitting on top
of whatever the real fault was.

**`--ref-ubatch`.** n_ubatch defaults to 512, so an 1100-token prompt makes `llama_decode` run
three micro-batches and capture one of them: 512 rows against our 1100, and the comparison
correctly refuses all 120 nodes on size. Forcing one micro-batch is what makes `--probe all`
mean anything at that length. It also shows the reference is not self-identical across
batchings - 386.91% against 264.37% on the same prompt - which is worth remembering before
treating any single reference number as ground truth to four digits.

### Osnastka, kotoraja portila sobstvennye rezultaty

Three defects in the harness, all of which produced confident wrong verdicts rather than errors:

  - `Start-Process -PassThru` returns an EMPTY ExitCode unless `.Handle` is read first, and
    `$null -ne 0` is true, so a successful build reported `sborka upala` and gave back a lock it
    had waited 5.5 minutes for. METHODS 60, with the three-way reproduction.
  - `ggml.dll` and `llama.dll` vanished from `build/bin/Release` for the third time in this
    project while cmake reported the target up to date and MSBuild printed its link line anyway.
    Every run died with -1073741515 before printing anything. METHODS 62 - including the cheap
    repair (delete the three `link.*` tlogs, twelve seconds, no recompilation) and the reason
    building only the example hid it.
  - engine exit 2 means "it ran and the numbers disagree" - a result. The harness read it as a
    broken step and paid for a duplicate three-minute 1100-token run.

## Otmena: regressii net, i moj porog shuma byl ne o tom

The regression I reported hours ago does not exist. A/B against a rebuilt upstream binary, one
session, four arms, three replicates interleaved with alternating direction:

    upstream 8337e4c, rtr    12.35  (3.6%)      upstream, mmap   11.59  (4.0%)
    memex, rtr               12.21  (2.3%)      memex, mmap      11.20  (13.5% - not a result)

Our patches cost **-1.1%** on the arm at issue, inside the noise floor. Both binaries repack the
same 337 tensors into the same types and emit the same text.

Every suspect I named was unreachable code. The new contiguous 64-byte-aligned allocation runs only
when mmap survives, and mmap survives only when a repack filter is set - and the filter can only be
set through `llama_model_params`, which `common/common.cpp` never touches. There is no CLI flag, so
`llama-cli` cannot enter that branch at all. With plain `-rtr` the fork runs upstream's loop
verbatim.

### Dva vyvoda protiv menja, i vtoroj huzhe

**The 14.04 baseline does not reproduce.** The same upstream commit, rebuilt today, measures 12.35.
And one unchanged post-patch binary has scored 11.99, 13.38, 12.95 and 12.21 across sessions - an
**11.6% range between sessions with clean spreads inside each one**. The effect I was chasing
(7.6%) is smaller than the session-to-session variation of identical code. I spent the day comparing
today's numbers against yesterday's and calling the difference a result.

**"Repacking used to buy +34%" was arithmetically impossible and I never checked it.** Repacking
does not change bytes read: iq4_xs->iq4_xs_r8, q8_0->q8_0_r8, q6_K->q6_k_r4 are all the same size.
mx1 reads 1721 MB per token; at the measured 24.8 GB/s that is a 14.7 tok/s ceiling. +34% over the
mmap arm (11.59) would need 15.5 tok/s, i.e. 28.7 GB/s - above the machine's memory bandwidth.
Repacking's real worth here, measured on both binaries: **6.6% upstream, 9.0% ours**.

So there was nothing to fix, nothing was traded away to keep selective repacking, and the
"regression confirmed by measurement" I wrote into this file was a comparison between two different
machine states.

### Chto ostajotsja vernym

The clean within-session table from 07:56 stands as a within-session table: 12.95 rtr against 12.32
mmap, spreads 3.4% and 3.7%. What does not stand is comparing either number to 14.04.

### Gde Gemma na samom dele lomaetsja: eto ne nash graf

The bisection finished. Probing the reference's own intra-attention node names at layer 0, on the
12-token prompt, gives ten consecutive tensors that are **bit-identical** - exactly zero, not
small - and then one node that is not:

    attn_norm-0, Qcur-0, Kcur-0, Vcur-0, Qcur_normed-0, Kcur_normed-0,
    Qcur_roped-0, Kcur_roped-0, kq-0, kq_soft_max_ext-0     L2 0.0000%, max |d| 0.00000
    kqv_merged_cont-0                                        L2 139.95%, max |d| 16.07
    kqv_out-0                                                L2 217.66%, max |d| 69.34

`kq_soft_max_ext` being exact is the load-bearing line: it means Q, the cached K, the GQA head
mapping, the windowed mask and the 1.0 attention scale are all right, to the last bit. The first
divergence is `kqv` - the single node that reads the V cache - with the other operand proven
equal.

**The fault is in the fork, in the arm we chose to compare against.** `cache.v_trans` is
`!flash_attn`, so with `flash_attn = false` the V store goes through
`v_cur = ggml_transpose(v_cur)` into a `[n_tokens, n_embd_v_gqa]` view. Every architecture but one
hands that code a 2-D V and it is correct. gemma4 hands it a **3-D** V, because the unweighted V
rms_norm needs the per-head shape; `ggml_transpose` swaps only ne0 and ne1, and `ggml_cpy`
between mismatched shapes is a flat linear-index copy, so the cache is written in an order the
read view does not expect. With `flash_attn = true` the store is a flat `view_1d` and the FA read
has matching strides, and the pair agrees.

One quantitative corroboration worth keeping, because it was available before any extra run:
a permutation of a vector's entries leaves the norm alone and destroys the correlation, so
two vectors that are permutations of one another sit at a relative L2 of exactly sqrt(2) =
141.42%. The measured `kqv_merged_cont-0` is **139.95%** - within one percent of that, and
not near any value a wrong scale or a missing normalisation would produce. The report line
now prints both RMS values beside the error for this reason (METHODS 11): a ratio near 1.0
with a large L2 says "same size, pointing elsewhere", which is a permutation, and a ratio
far from 1.0 says a scale is missing. Those are different bugs and L2 alone cannot separate
them.

`--ref-fa` now picks the reference's arm. The A/B - same prompt, same binary, one flag - is what
turns this from a strong reading of the source into a measurement, and it is queued. Until it
runs, this is a diagnosis and not a result.

**What it already changes regardless of the A/B:** every Gemma number in the section above was
measured against a reference that is wrong in that configuration, so none of them describes our
engine's accuracy. The 414% and the 0-of-6 tokens are not evidence about our graph. And the same
question now hangs over any perplexity or token-match number this project has ever taken for
gemma4 with `-fa off`, which is the flag METHODS recommends on this CPU.

### Pochemu ggml.dll ischezala: nazvano po spisku processov

METHODS 64 names it; METHODS 62 described how MSBuild fails to notice a missing link output and named no cause.
The cause is another participant running

    cmake --build build --target ggml --config Release -j 4 --clean-first

without the machine lock. That is `master.ps1`'s own `EnsureBinaries` repair, written after the
first time the dll vanished. `--clean-first` deletes the target's outputs, so two agents each
detecting "binaries missing" and each running the documented repair delete each other's
artefacts; one of my links died with LNK1181 on a `ggml.lib` that was removed while it was being
read. Twenty-three of ggml's twenty-seven objects were gone by the time this was caught, so the
machine then spent half an hour rebuilding what had been there.

Two fixes, and they need each other: the repair must take the lock (rule 40, with a participant
nobody enrolled), and it must be as narrow as the fault - deleting three `link.*` tlogs and
relinking takes twelve seconds against `--clean-first`'s half hour, and the objects were never
the problem.

### A/B podtverdil: etalon byl nepraven, a nash blok vnimanija tochen do bita

Same binary, same 12-token prompt, one flag changed. `--ref-fa` makes the reference run flash
attention, which is the arm in which its gemma4 V cache is stored and read consistently.

    arm                       prefil, logity   luchshij token   dekod 6 shagov
    flash_attn off (bylo)     L2 414.33%       RAZOSHLIS        0 iz 6
    flash_attn on  (--ref-fa) L2  10.54%       SOVPAL           3 iz 6

And at layer 0, with the reference in its working arm, ELEVEN consecutive tensors are exactly
zero - the whole attention block now, not just its front half:

    attn_norm-0, Qcur-0, Kcur-0, Vcur-0, Qcur_normed-0, Qcur_roped-0,
    Kcur_normed-0, Kcur_roped-0, kqv_out-0, attn_out-0, ffn_norm_2-0
                                          L2 0.0000%, max |d| 0.00000

`kqv_out-0` and `attn_out-0` were 217.66% and 147.95% against the broken arm and are 0.0000%
against the working one. Our gemma4 attention - the windowed geometry, the 1.0 scale, the
unweighted V rms_norm, the V-from-K sharing, the per-layer rope base, the KV cache layout - is
byte-for-byte the reference's. Nothing in it needs changing.

**What remains is a second and much smaller fault, and it is now localised too.** The first
non-zero line is `ffn_moe_combined-0` at **17.11%**, with rms 20.65637 against 20.65505 - the two
answers are the same size, so this is not a missing scale. Everything upstream of it, including
`ffn_norm_2-0` (the MoE's own input), is exact. So the fault is inside layer 0's feed-forward:
the dense half, the router, the experts, or the `fused_rms_rms_add` that joins the two halves.
A probe under the reference's own name for the routed half (`ffn_moe_weighted`, which our
`ffn_moe_out` never matched, so the routed half has never actually been compared) plus one for
the dense half's input (`ffn_norm_1`) splits that four ways, and is queued.

Downstream the error stays bounded rather than exploding - prefill logits 10.54%, decode steps
7.3-36.1% - and the generated text is now sensible (" Tokyo. The capital of France"), which is
what a single arithmetic difference in one sub-block looks like rather than a wiring fault.

**The router-scale fix is in this binary**, so the 17% is what is left AFTER correcting
`ffn_gate_inp.scale` for `llm_scale_gate_inp_s`. Whether that fix helped cannot be read off these
numbers alone - there is no before/after pair for it on the working reference arm - and that is
worth one arm later.

## Pervoe polozhitelnoe chislo puti cherez kartu

Golova (output.weight, 243 MB) na karte, ostalnoe na processore, mx1, prompt_2000, --gen 192:

    processor      12.12 tok/s
    karta          12.61 tok/s     +4.0%,  golova stoit 6.343 ms/tokjen na karte

First time in this project the card has paid on a real model. The head is 243 MB - the smaller part
of the static half, which is 802 MB in total - so this is a fraction of the available lever.

Note the head's measured cost: 6.343 ms against 243 MB / 131 GB/s = 1.9 ms of pure bandwidth. The
difference is the handoff, and it means the transfer and rendezvous around a single once-per-token
tensor cost more than reading it. That is consistent with the measured 177 us per crossing but worth
watching as more of the static half moves: the crossings do not grow with the bytes moved, so
attention (510 MB across 48 layers) will amortise them far better than the head does.

### Pochemu 0.45-0.50% L2 na vyhodah sloev - eto ne oshibka karty

The reference is the fork's own CPU path, and its iqk kernels quantise the activation vector: on one
mul_mat_id against a double-precision reference the CPU measured 5.0e-2 and Vulkan 9.4e-8. So a
half-percent difference between our card path and the CPU reference says "the card computes
differently from the CPU", not "the card computes wrongly" - and by the only measurement we have of
both against ground truth, differently means more accurately.

This matters for how the verification is read. A card path that matched the CPU reference to 1e-7
would be suspicious, not reassuring: it would mean we had reproduced the CPU's activation
quantisation. What must be checked instead is that the difference does not grow with depth - that is
the signature of reassociation compounding, which this project has already been burned by (2.5e-8 at
layer 1 becoming 1.6% by layer 47). Here l_out-23 is 0.4564% and l_out-24 is 0.5024%, so it is
growing slowly; the next thing to look at is the same figure at layer 47.

## Ochered modelej, zadana vladelcem 27 avgusta

    1. Qwen3-Coder-30B   dovesti do konca, DOLOZHIT CIFRY
    2. Gemma 4 26B       razobrat tem zhe sposobom
    3. Qwen3.6 35B
    4. Coder-Next        3 bita, zatem 4

Gemma snjata s raboty na punkte 1, no ne broshena: chto po nej uzhe iskljucheno - v
`D:\MemeX\results\gemma4_state.md` i v kommentarii u `build_gemma4_step`. Rashodimost na
`attn_out-0` (L2 147.95%), to est vnutri pervogo bloka vnimanija, do vsjakogo MoE, pri neaktivnom
okne. Proverено i verno: masshtab vnimanija (f_attn_scale = 1.0) i poslojnaja geometrija (sloj 0 -
ATTN_SWA, head_dim 256, baza povorota 1e4, 8 KV-golov). Ostalos tri kandidata: rms_norm na V bez
vesa, mesto q_norm/k_norm otnositelno povorota, i privjazka samogo zonda - esli on ukazyvaet ne na
tu tochku, chto u etalona, to rashoditsja sravnenie, a ne graf.

### Chto schitaetsja "do konca" dlja punkta 1

Ne "statika na karte", a vsjo chetyre chasti zamysla vmeste:

    vsja statika na karte            802 MB: vnimanie 510 + golova 243 + marshrutizator 48
    rezidentnye eksperty rjadom      ostatok VRAM, ~26 na sloj, po simuljacii 88% popadanij
    parallelnyj schjot CPU i karty   odno randevu na sloj, ne na uzel i ne na blok
    obnovlenie nabora vtorym potokom bez ostanovki generacii, s bjudzhetom prodvizhenij

I zamer oboih plech v odnoj sessii vperemezhku - potomu chto porog shuma 4.2% vnutrisessionnyj, a
odin neizmennyj binarnik za sutki daval 11.99 / 13.38 / 12.95 / 12.21.

Sostojanie na moment zapisi: golova na karte daet +4.0% (12.12 -> 12.61). Eto odna tret pervoj
chasti iz chetyrjoh.

## Rost rashozhdenija s glubinoj: ne nash, i karta drejfuet menshe

The static-on-card path showed L2 growing monotonically with depth - 0.4667% at layer 42, 0.9954% at
layer 46, logits 2.58-6.91% - while 6 of 6 generated tokens matched the reference. That is exactly
the signature of the float-reassociation bug this project already had once (2.5e-8 at layer 1
becoming 1.6% by layer 47, with every token still matching), so it could not be waved through.

A CPU-versus-card comparison cannot settle it: growing divergence is equally consistent with "the
card is more accurate at every layer and the CPU's own error accumulates" and with "our split
reassociates sums and *our* error accumulates". The measurement that separates them is the growth
rate of each path measured separately:

    processor   pervaja polovina sloev 3.7867%   vtoraja 5.2035%   otnoshenie 1.37
    karta       pervaja polovina       3.8461%   vtoraja 4.9745%   otnoshenie 1.29

**Both paths drift with depth, and the card drifts less.** So the growth is inherent to the
computation, not introduced by us, and the widening gap between the two paths is the two error
sources accumulating at different rates. If our folding were reassociating, the card's ratio would
be the *higher* of the two; it is the lower.

Worth keeping as a method: when a difference between two implementations grows with depth, comparing
them to each other tells you nothing about which one is drifting. Measure the growth rate of each
against a common reference. The sign of the difference in growth rates is the answer, and it is
cheap - the same probes, one extra pass.

## Chistyj zamer shemy na 30B: +25% ot svjazki statiki i ekspertov

Two rounds, four arms, order counterbalanced (round 1 forward, round 2 reversed), one discarded
warm-up load, machine quiet. Round means across all four arms: **12.61 and 12.64 - a 0.2% drift**,
the steadiest conditions this project has had.

                     raund 1   raund 2   razbros
    processor         11.99     11.96     0.3%
    statika           12.76     12.76     0.0%
    statika+eksperty  14.71     15.32     4.1%
    tolko eksperty    10.96     10.51     4.2%

So the scheme works and is worth **about +25%** over the CPU-only path (~15.0 against ~11.98).
Before the readback fix the same combination measured 5.74, so that one fix - a 16.9 KB read at
22 MB/s through a BAR-mapped buffer, 0.758 ms per layer - was worth a factor of 2.6.

### Chasti ne skladyvajutsja po otdelnosti, i eto glavnyj vyvod

`exp` alone is **10.5-11.0, i.e. worse than CPU-only**, and it has the *higher* hit rate (87.0%
against 71.6%) because without static on the card all of VRAM goes to experts. The expert split only
pays on top of static:

    statika odna        +6.5%
    eksperty odni       -10%
    vmeste              +25%

Without static on the card the CPU still computes attention every layer, so the expert split adds
crossings while removing nothing from the critical path. This retroactively explains why earlier
"experts on the card" attempts measured 0.93x and were closed as a failure: those measurements were
correct and the conclusion drawn from them was not - the configuration being measured was the one
where the technique cannot work.

Worth keeping as a caution: **a technique that fails in isolation may be the second half of one that
works.** Closing it on its own evidence is exactly right as a measurement and exactly wrong as a
decision, unless the pairing was tried.

### Chto ostajotsja do 20+

15.0 tok/s is 66.7 ms/token. The target needs 50 ms. The instrumented figures account for 32.5 ms
(sloi 29-30 + golova 2.4), so **about 34 ms is unaccounted** - twice the 17 ms that would close the
gap to the target. Two candidates: the CPU blocking on the card instead of computing in parallel
(max() becoming a sum), or more than one crossing per layer at 177 us each. The measurement that
separates them is the time the CPU thread spends blocked at the join, next to the layer time already
printed.

## Gde na samom dele uhodit vremja na karte: uzly, a ne bajty

Instrumented, and it kills both of my candidates:

    peresechenij     49,0 na tokjen = 1,02 na sloj
    na peresechenie  0,603 ms = podjom 0,003 + ustrojstvo 0,470 + zabor 0,130
    na tokjen        29,56 ms
    zaborov cherez otobrazhenie 0

One crossing per layer, exactly as designed - so "extra crossings" is dead. And 0,470 of the 0,603
is the device computing, not the host waiting - so "the CPU blocks instead of computing in parallel"
is dead too. I had proposed both; neither was it.

**What it is instead.** Attention for one layer is ~10,6 MB of weights plus its KV slice; at
131 GB/s that is 0,081 ms. Measured 0,470 - the card runs about **six times slower than its own
bandwidth allows**, so it is not bandwidth-bound. The layer graph is 29 nodes and a dispatch costs
7,2 us, giving 0,21 ms of pure launch per layer against 0,08 of bandwidth. Node count explains most
of the gap; bytes explain almost none of it.

This inverts the design assumption the whole plan was built on. The byte budget was the right lens
while everything ran on the CPU, where bytes and time convert at 1:1 (R^2 = 0,998). On the card that
conversion does not hold: the same bytes cost six times longer because they arrive through many
small kernels. **The unit of cost changed when the processor changed, and the analysis did not.**

Consequence for the target: 15,2-15,7 tok/s is ~65 ms; 20+ needs 50. Halving nodes per layer saves
roughly 5 ms, which reaches ~16,5 and not 20. So node count is necessary and not sufficient, and the
next thing to establish is what the remaining 0,26 ms per crossing is made of - a few genuinely
bandwidth-bound kernels would mean cutting nodes is the wrong hill.

## Predskazanie oprovergnuto: slijanie hvosta MoE dajot nol

Three rounds, interleaved, round means 15,16 / 15,18 / 15,25 - drift 0,6%:

    baza          15,20 tok/s   razbros 1,8%   n=3
    so slijaniem  15,19         1,6%           n=3

I predicted 7,4 ms and 16,5-17 tok/s. The measured difference is **0,01 tok/s**, i.e. nothing.

The mechanism is identifiable and the error was mine, in a specific way worth naming. I took a
measured number - the layer graph is 29 nodes, a dispatch costs 7,2 us - and multiplied, without
asking **how many of those 29 nodes run on the device at all**. The MoE tail combines the card's
partial sum with the CPU's, so it executes host-side; cutting its eight nodes cannot touch the
0,470 ms the card spends. The quantity was measured correctly and attributed wrongly.

By the earlier per-layer count on Gemma, the device runs about 11 of 39 nodes. So the ceiling of
"cut nodes" is roughly a third of what I promised, and the barrier and device-occupancy levers -
each measured at about 6,4 ms - are now the larger ones.

**The change stays in regardless.** It is a correctness fix, not an optimisation: bit-identical, and
it is the spelling the reference actually runs (`fused_mmad` defaults true, so the hand-written chain
was the one that did *not* match `llama_decode`). It simply buys no speed.

Method note: this is the third prediction written down before measuring and then refuted - the
scheduler-contention idea, the promotions-blocking idea, and now this one. All three would have been
"plausible optimisations we applied and moved on from" without the prediction step. Writing the
expected number first is what turns a null result into information.

## Dva bjudzheta uzlov, kotorye byli slozheny v odin - i cena uzla v kazhdom

Zadanie stavilo rychag tak: "graf sloja iz 29 uzlov, rezhem hvost MoE s vosmi do odnogo,
poluchaem okolo 7.4 ms i 15.0 -> 16.5-17". V etom odnom predlozhenii slozheny dve raznye
velichiny, i posle scheta oni okazalis raznymi na poriadok.

    graf sloja NA KARTE (gpu_static.cpp)   29 uzlov, iz nih 19 dispatchej   7.2 us za dispatch
    hvost MoE NA HOSTE (build_step)        8 uzlov iz ~27 real'nyh na sloj  MENSHE 1 us za uzel

**Iz 29 uzlov grafa sloja dispatchej tolko 19.** `ggml_vk_is_empty` (ggml-vulkan.cpp:10333)
vozvrashchaet true dlja NONE / RESHAPE / VIEW / PERMUTE / TRANSPOSE, i graph_compute takoj uzel
propuskaet celikom - v grafe sloja shest reshape i chetyre view. Naklon 7.2 us izmerjalsja na
udalenii devjati NASTOJASHCHIH uzlov, znachit eto cena dispatcha, i 29 x 7.2 zavyshaet chlen
zapuska pochti vdvoe. Predskazanie 19/10 bylo zapisano do progona i sovpalo tochno.

**Hvost MoE k etim 29 otnoshenija ne imeet vovse** - eto uzly hosta. Zamer:

    base tok/s    15.20 (razbros 1.8%, n=3)      base sloj ms  29.65 (0.9%)
    new  tok/s    15.19 (razbros 1.6%, n=3)      new  sloj ms  29.69 (1.0%)
    raundy 15.16 / 15.18 / 15.25, kontrolnyj etalon 8.57 / 8.60
    -------------------------------------------------------------
    -0.1%, to est nol

Rezalos 336 nastojashchih hostovyh uzlov na tokjen (7 na sloj x 48). Iz razbrosa 1.7% verhnjaja
granica effekta okolo 1.1 ms, znachit **hostovyj uzel pri n_tokens=1 stoit menshe mikrosekundy**.
Protiv 7.2 us za dispatch na karte eto raznica na poriadok - i imenno ona ob'jasnjaet, pochemu
odna i ta zhe pravka "minus sem uzlov" v odnom bjudzhete rychag, a v drugom nichto.

"sloj ms" ne dvinulsja, i eto plecho, kotoroe OBJAZANO ne dvigatsja pri hostovoj pravke
(pravilo 69). Vmeste s pobitovym sovpadeniem dvuh binarnikov vopros zakryt.

Pravka ostavlena v dereve, potomu chto ona ne pro skorost: `cparams.fused_mmad` po umolchaniju
true (llama.cpp:7728) i llm_build_moe_ffn beryot ggml_mul_multi_add
(llama-build-context.cpp:1822), tak chto vosmiuzlovaja cepochka byla napisaniem, kotorogo
llama_decode ne vypolnjaet.

## Graf sloja, uzel za uzlom: rezat tam bolshe nechego, i eto poschitano

     #  op                        dispatch   zavisit ot     bajty
     1  FUSED_RMS_NORM attn_norm     da      vhod           8 KB
     2  MUL_MAT wq                   da      1              4.46 MB
     3  MUL_MAT wk                   da      1  (ne ot 2)   1.11 MB
     4  MUL_MAT wv                   da      1  (ne ot 3)   1.11 MB
     5  RESHAPE q                    NET
     6  FUSED_RMS_NORM q_norm        da      2              ~0
     7  ROPE q                       da      6              ~0
     8  RESHAPE k                    NET
     9  FUSED_RMS_NORM k_norm        da      3  (ne ot 7)   ~0
    10  ROPE k                       da      9              ~0
    11-14 RESHAPE Kc, Vc; VIEW kdst, vdst   NET
    15  CPY Kc -> kdst               da      10             1 KB
    16  CPY Vc -> vdst               da      4  (ne ot 15)  1 KB
    17-19 RESHAPE Q; VIEW K, V       NET
    20  MUL_MAT kq                   da      15, 7          kesh K
    21  SOFT_MAX_EXT                 da      20             ~0
    22  MUL_MAT kqv                  da      21, 16         kesh V
    23  RESHAPE kqv                  NET
    24  MUL_MAT wo                   da      22             4.46 MB
    25  ADD ffn_inp                  da      24             8 KB
    26  FUSED_RMS_NORM ffn_norm      da      25             8 KB
    27  MUL_MAT router               da      26             1.05 MB
    28  CONCAT (ffn_inp, xf)         da      25, 26         16 KB
    29  CONCAT (.., rl)              da      28, 27         17 KB

Pjat dispatchej nesut 97% bajt, chetyrnadcat ne nesut pochti nichego i platjat te zhe 7.2 us.
Estestvennyj vyvod "znachit rezhem chetyrnadcat" ne prohodit, i po kazhdomu est prichina:

  - **QKV odnim matumnozheniem (3 -> 1): nevozmozhno.** wq lezhit v iq4_xs, a wk i wv v q8_0;
    skleit v odin tenzor mozhno tolko odnotipnye. Eto ne voprós usilija.
  - **Rope na q i k odnim uzlom (2 -> 1):** trebuet, chtoby q i k lezhali sploshnjakom posle
    svoih raznyh norm; sklejka - eto lishnij uzel, i vyigrysha net.
  - **Dva concat v konce (2 -> 1):** edinstvennyj realnyj. Esli ne otdavat hostu `xf`, a dat
    emu poschitat ffn-normu samomu (okolo 2 us na 2048 chisel), ostajotsja odin concat. Minus
    odin dispatch, pljus odin uzel hosta, kotoryj po zameru vyshe stoit menshe mikrosekundy.
  - Normy q/k, zapisi v kesh, softmax, ostatochnoe slozhenie - nesokratimy.

**Potolok rezki: 19 -> 18 dispatchej, okolo 0.35 ms na tokjen, 0.5%.** Napravlenie zakryto ne
"malo obeshchaet", a poschitano.

## Razlozhenie peresechenija, perepisannoe

    podjom                        0.003 ms     0.1 ms/tokjen
    ustrojstvo (graph_compute)    0.467       22.9
      zapusk 19 dispatchej          0.137       6.7
      submit (2.00 na graf)         0.130       6.4
      propusknaja 10.6 MB           0.081       4.0
      NEOBJASNENO                   0.119       5.8
    zabor 16.9 KB                 0.129        6.3
    ------------------------------------------------
    vsego                         0.600       29.4 iz 66.6 ms tokjena (44%)

Neobjasnennye 0.119 ms na peresechenie - 5.8 ms na tokjen - krupnee vsego, chto mozhno vzjat
rezkoj uzlov, i u nih net hozjaina.

## Barjer: gipoteza zadanija oprovergnuta, a cena barjera okazalas vdvoe krupnee

Zadanie prosilo sdelat `ggml_vk_sync_buffers` (ggml-vulkan.cpp:1778) uslovnym, na tom
osnovanii, chto cepochka iz 32 zavisimyh uzlov i veer iz 32 nezavisimyh izmerilis 1.003x -
"nichego nikogda ne perekryvaetsja". Eto pravka v 31 meste korrektnostno-kriticheskogo koda.

Vmesto nejo sdelan izmeritel: `GGML_VK_NO_SYNC=1` prevrashchaet barjer v pustyshku. Arifmetika
pri njom ne verna, i eto namerenno - **prizes uslovnogo barjera ogranichen sverhu tem, chto
dajot polnoe otsutstvie barjerov**, znachit potolok merjaetsja pjatju strokami vmesto sotni.
Zond vksplit, izmerenie 1b, 32 uzla po 4 KiB:

    NO_SYNC=0    cepochka 200.23 us (0.6%)   veer 199.72 (0.2%)   otnoshenie 1.003x
    NO_SYNC=1    cepochka 117.35 us (2.9%)   veer 115.23 (4.1%)   otnoshenie 1.018x

**Gipoteza zadanija oprovergnuta.** Otnoshenie ostalos 1.00 i BEZ barjerov. Znachit "nichego ne
perekryvaetsja" - eto svojstvo ustrojstva, a ne barjera, i snjatie barjera perekrytija ne
otkryvaet. Uslovnyj barjer, esli by on byl napisan, ne kupil by togo, radi chego ego prosili.

**No absoljutnaja cena upala na 41%: (200.23 - 117.35) / 32 = 2.59 us na dispatch.** Barjer
stoit sam po sebe, a ne tem, chto zapreshchaet - eto 36% ot izmerennyh 7.2 us. On polnyj: vse
stadii, vse dostupy, vkljuchaja transfer read/write, to est na AMD sbros i invalidacija L2
pered kazhdym dispatchem.

Iz etogo sleduet drugaja pravka, chem prosili. Po potoku dannyh nezavisimyj predshestvennik
est u chetyrjoh dispatchej iz devjatnadcati (wk, wv, k_norm, cpy V) - eto verhnjaja ocenka, a ne
schjot po vypushchennomu porjadku: ggml_build_forward_expand vydajot uzly obhodom v glubinu ot
kcpy, vcpy i out, poetomu sosedjami v linejnom porjadke chashche vsego okazyvajutsja roditel i
potomok, i realnoe chislo snimaemyh barjerov ne bolshe chetyrjoh. To est uslovnaja versija
dajot ne bolshe 4 x 2.59 = 10 us na peresechenie: 0.5 ms na tokjen, 0.8%.

A **suzit** barjer - ubrat bity transfer tam, gde ni odna storona ne transfer - primenimo ko
VSEM barjeram, i vopros tolko v tom, kakuju dolju ot 2.59 us eto vernjot. Ohvat vpjatero
bolshe pri toj zhe izmerennoj cene, i imenno poetomu sledujushchij instrument -
GGML_VK_NARROW_SYNC, a ne uslovnyj barjer.

### Potolok, izmerennyj na nastojashchem grafe

Predskazanie do progona: sloj ms 29.69 -> 27.2 (-8.2%), tok/s 15.15 -> 15.6-15.8. Zamer, tri
raunda vperemezhku s progrevom na vybros:

    sync    tok/s 15.15 (razbros 2.1%)   sloj ms 29.69 (1.0%)   etalon 8.46
    nosync  tok/s 14.78 (razbros 2.0%)   sloj ms 26.71 (4.2%)   etalon 8.58
    ---------------------------------------------------------------------
    sloj ms   -10.0%   predskazano -8.2%   SBYLOS S ZAPASOM
    tok/s      -2.4%   predskazano +2..+4%  NE ZASCHITYVAETSJA, sm. nizhe

**Barjery stojat 2.98 ms na tokjen - desjatuju chast peresechenija.** Za progon vydano 301 373
barjera na 192 tokjena i 48 sloev, to est 32.7 na peresechenie pri devjatnadcati dispatchah:
barjer stavitsja poltora-dva raza na dispatch, i vokrug zapisi vhodov tozhe. Poetomu ocenka
"19 x 2.59 us = 49 us" byla zanizhena, a nastojashchij chlen okolo 85 us na peresechenie - chto i
dalo 3 ms vmesto predskazannyh 2.4.

**A vot tok/s v pleche nosync schitat nelzja, i eto otdelnyj urok.** Ono upalo, prichjom vo vseh
trjoh raundah, i barjer tut ni pri chjom: arifmetika v etom pleche razrushena - 0 iz 192 tokenov,
L2 140%, a dva shaga iz chetyrjoh dali -1.000000000%, to est chasovoe znachenie "etalon nulevoj"
(pravilo 11). Nuli i NaN, prishedshie s karty, dalshe schitaet CPU, a denormaly i NaN na AVX2
medlennee normalnyh chisel. Plecho medlennee POTOMU CHTO nevernoe.

Otsjuda utochnenie k pravilu 73: **zavedomo nevernoe plecho ogranichivaet sverhu tolko te
velichiny, kotorye ne zavisjat ot znachenij.** sloj ms - eto vremja jader na ustrojstve, ono ot
dannyh ne zavisit i schitaetsja. tok/s prohodit cherez ekspertnuju polovinu na CPU, ona ot
dannyh zavisit, i ono ne schitaetsja. Uvidet eto udalos tolko potomu, chto obe velichiny
snimalis rjadom i razoshlis po ZNAKU; odna velichina dala by uverennyj nevernyj otvet v ljubuju
iz dvuh storon.

Otdelno stoit zapisat metodicheskoe: **plecho, kotoroe zavedomo nevernó, byvaet deshevle i
informativnee plecha-kandidata.** Polnoe snjatie barjerov nikuda ne pojdjot, no ono za odin
progon dalo i oproverzhenie gipotezy, i cenu mehanizma, i verhnjuju granicu vsej vetki. Pisat
korrektnuju versiju do etogo znachilo by uznat te zhe tri veshchi za den vmesto chasa.

## Chto ja sobirajus delat s "prostaivajushchej kartoj", do togo kak eto pisat

Zamer pola uzhe est i on strannyj: pri vykljuchennoj rezidentnoj polovine peresechenie stoit
BOLSHE - 0.710 protiv 0.600 ms, raznica 0.131 ms na peresechenie, 6.4 ms na tokjen. Eto pochti
rovno neobjasnennye 0.119 iz razlozhenija vyshe, i predpolozhenie, kotoroe svjazyvaet oba
chisla, odno: **eto raskrutka chastot.** Period peresechenija 66.6/49 = 1.36 ms, iz nih karta
zanjata 0.6, ostalnye 0.76 ms prostaivaet, i upravlenie pitaniem uspevaet sbrosit chastotu. V
pleche bez ekspertov prostoj dlinnee - i cena rastjot tuda zhe.

Proverka, kotoruju ja predlagaju, i ona ne trebuet planirovshchika: zanjat kartu zavedomo
dejshjovoj po bajtam rabotoj mezhdu peresechenijami (povtornyj matvektor po uzhe rezidentnomu
ekspertu, chtoby ne otnimat polosu) i posmotret na "sloj ms".

    esli gipoteza verna    peresechenie 0.600 -> ~0.48, tokjen 66.6 -> 60.8, ~16.4 tok/s
    esli neverna           napolnitel otnimet polosu i chislo stanet HUZHE srazu

Vtoroj ishod - tozhe otvet, i on prihodit s pervogo progona. Vazhno, chto plecho "huzhe" nelzja
budet prochitat kak "nedostatochno napolnitelja": imenno poetomu napolnitel objazan byt
dejshjovym po bajtam, inache dva effekta ne razdeljajutsja.

Chto ja delat NE sobirajus, i pochemu: "vydavat statiku sledujushchego sloja, poka CPU eshcho
schitaet ekspertov tekushchego". Sloj L+1 nachinaetsja s l_out sloja L, kotoryj est summa
poloviny karty i poloviny CPU, - to est do konca ekspertov sloja L vydavat nechego. Eto ta zhe
posledovatelnaja zavisimost, o kotoruju uzhe razbilas ideja s planirovshchikom.

## Karta bolshe ne na kriticheskom puti, i eto otmenjaet postanovku zadachi

Synthetic probe, 32 tiny nodes:

    barjery vkljucheny         201,27 mks
    barjery s suzhennoj oblastju 201,05    nol effekta
    barjery vykljucheny        113,41    -44%

Narrowing the barrier's access masks and pipeline stages does **nothing**; only removing it entirely
helps. And even with barriers off, chain versus fan measures 1,036 - so the barrier was never
blocking overlap, it simply cost about 2,8 us per node on its own.

Now put that next to the model. Removing the barriers made the **layer 10% faster** (29,69 ->
26,71 ms) and the **token 2,4% slower** (15,15 -> 14,78, predicted +2..+4%).

**A 10% faster card does not make a faster token. So the card is no longer the critical path.**

That retires the framing I gave the agent. Three levers in a row were aimed at the card - fuse the
graph, cut the barriers, keep the device fed - and the first two returned zero and negative. The
measurement says the remaining time is not on the device: it is in the CPU half or in the handoff.

Four predictions written down before measuring and refuted so far:

    scheduler contention (-t 7)      predicted 16,0-16,8   measured 15,2-15,7, wait ROSE
    promotions blocking the worker   predicted 15-30% / <10%   measured 8,6% / 16,9%, reversed
    fusing the MoE tail              predicted 16,5-17     measured 15,19 vs 15,20
    removing the barriers            predicted +2..+4%     measured -2,4%

None of these would have been visible as errors without writing the number first. Each would have
been applied, believed, and built upon - the fusion in particular is a real correctness improvement
that would have been credited with a speed gain it does not deliver.

The open question is where the 3 ms went: the layer got faster by that much and the token did not.
It moved rather than vanished, and the candidates are the join wait and the readback.

## Kuda ushli 3 ms: ne v zabor i ne v disbalans polovin - v POTOK KARTY, zanjatyj podkachkami

Vopros byl postavlen tak: sloj otdal 3 ms, a tokjen ih ne poluchil, znachit vremja peremestilos.
Otvet uzhe lezhal v vyvode teh zhe progonov, i ego ne prishlos merit zanovo.

### Chistoe plecho sync, tri povtora, vse razbrosy pod 1%

    tokjen (15.15 tok/s)                        66.0 ms
    ---------------------------------------------------
    polovina CPU (fork -> join)                 16.06
    polovina karty (ms_job, chasy workera)      21.25
    ZHDJOM (pul ggml POLNOSTJU ostanovlen)      11.48    17% tokjena
        iz nego disbalans polovin                5.19
        OSTATOK, disbalansom ne objasnjonnyj      6.29
    PODKACHKI zanjali potok karty               13.04    <-- vot ono
    peresechenija 49 x 0.606                    29.7
    iz nih zabor 49 x 0.132                      6.5

### Podkachki idut v TRI raza medlennee kanala

Dvizhok sam pechataet obe cifry, na sosednih strokah, i oni ne sovpadajut:

    "podkachek 6.9 na tokjen = 17.3 MB po PCIe pri 3.94 GB/s = 4.4 ms/tokjen"
    "podkachki zanjali potok karty 13.04 ms/tokjen"

13.04 ms na 17.3 MB - eto **1.33 GB/s protiv 3.94 GB/s kanala**. Odna podkachka (odin ekspert,
tri matricy, odin barjer) stoit 1.89 ms tam, gde kanal prosit 0.64. Izbytok **8.6 ms na tokjen**,
i on lezhit na TOM SAMOM potoke, kotorogo CPU zhdjot na dzhojne.

Eto v tochnosti to, chto predskazyval kommentarij v gpu_experts.cpp: "dispatch, prishedshij poka
v poljote podkachka, ne nachnjotsja do vozvrata ejo barjera, i eta zaderzhka ne vidna nigde,
krome kak v ozhidanii na dzhojne, kotoroe disbalansom polovin ne objasnjaetsja". OSTATOK 6.29 ms
- eto i est ona, i po velichine ona soglasuetsja s 13.04 ms podkachek pri 8.9% forkov, popavshih
v zanjatyj potok.

**I rjadom stoit oshibka po pravilu 67 - v nashem zhe vyvode.** Dvizhok pechataet: "PCIe na
podkachki prosit 4.4 ms - menshe, to est podkachka sama sebja oplachivaet". Eto rassuzhdenie
postroeno na TEORETICHESKIH 4.4 ms, pri tom chto izmerennye 13.04 napechatany dvadcatju strokami
nizhe. Schjotchik, postavlennyj rjadom s prijomom, podtverzhdaet tu velichinu, kotoruju schitaet.
Zdes u nas byli obe velichiny i vsjo ravno v vyvod poshla ne ta.

### Dva kandidata iz zadanija: odin oprovergnut, vtoroj neprigoden dlja proverki v etom pleche

**Zabor - oprovergnut.** 0.132 -> 0.135 ms na peresechenie. Ne dvinulsja; 3 ms ushli ne tuda.

**Dzhojn - ne umenshilsja, a vyros: 11.48 -> 17.83 ms.** No etu cifru zaschitat nelzja, i eto
vazhnee samoj cifry. V pleche nosync `polovina CPU` uehala 16.06 -> 13.86 pri razbrose 30%
(16.14/16.40/15.64 protiv 15.46/14.28/11.85), potomu chto arifmetika tam razrushena. Znachit
kontaminirovany vse tri velichiny, prohodjashchie cherez CPU: tok/s, polovina CPU i dzhojn.
Ostajotsja tolko odno bezopasnoe utverzhdenie, i ono otvechaet na vopros: **dzhojn ne sokratilsja
na te 3 ms, kotorye otdala karta.** Skorost karty - ne to, chto zadajot ozhidanie.

### Proverka korrektnosti plecha nosync: provedena, i ona NE PROSHLA

Eto bylo sdelano do ljubyh vyvodov, i imenno poetomu tok/s ottuda ne poshjol v rezultat:

    0 iz 192 tokenov sovpalo podrjad
    hudshaja otn. L2 logitov 140.27%
    dva shaga iz chetyrjoh vernuli -1.000000000% - chasovoe znachenie "etalon nulevoj" (pravilo 11)

To est barjery derzhali korrektnost, i snjatie vseh - ne to zhe samoe, chto snjatie lishnih.
Zaschityvaetsja iz togo plecha rovno odna velichina - vremja jader na ustrojstve, ot dannyh ne
zavisjashchee, - i ona podtverzhdena NEZAVISIMO sinteticheskim zondom, gde oba plecha dvigajut
odni i te zhe bajty: 201.27 -> 111.90 us na 32 uzla, 2.8 us na barjer.

### Vetka barjera zakryta polnostju, tremja zamerami

    barjery est                        201.27 us / 32 uzla
    suzheny dostupy   (NARROW_SYNC=1)  201.29     -0.13%   nichego
    suzheny + stadii  (NARROW_SYNC=2)  201.05     -0.11%   nichego
    barjerov net      (NO_SYNC=1)      111.90    -44.4%    no arifmetika razrushena

Klyuchi podtverzhdeny kak PRIMENJONNYE (pravilo 68), tak chto eto "bespolezno", a ne "ne
vkljuchilos". Cena barjera - v samom fakte `vkCmdPipelineBarrier` mezhdu dispatchami, a ne v tom,
chto on objavljaet. Znachit deshevle sdelat ego nelzja - tolko rezhe, a rezhe mozhno tolko tam, gde
on ne nuzhen dlja korrektnosti: chetyre dispatcha iz devjatnadcati, 0.8% tokjena.

### Vyvod, kotoryj stoit skazat pryamo

Karta ne na kriticheskom puti - na njom potok karty. Iz ego ~34 ms na tokjen 13.04 uhodit na
podkachki, a ne na dispatch, kotorogo zhdjot CPU, i idut oni vtroe medlennee kanala. Vse tri
rychaga, na kotorye ukazyvalo zadanie (rezka uzlov, uslovnyj barjer, "kormit ustrojstvo"),
napravleny na ustrojstvo, i vse tri izmereny kak nichto ili pochti nichto:

    slitoj hvost MoE          -0.1%     (predskazano +0.3..+2.5, zadanie 15.0 -> 16.5-17)
    rezka uzlov dalshe        0.5% potolok, poschitano po grafu
    barjer, ljubaja korrektnaja versija   0.8% potolok
    zabor                     ne dvigaetsja

A ne izmereno i krupno:

    podkachki: 8.6 ms/tokjen izbytka nad kanalom, na potoke, kotorogo zhdjot CPU
    ZHDJOM: 11.48 ms/tokjen, iz nih 6.29 ne objasnjajutsja disbalansom polovin

Sledujushchij shag - ne graf i ne barjer, a **pochemu podkachka 2.51 MB stoit 1.89 ms vmesto
0.64**, i mozhno li vynesti ejo s togo potoka, na kotorom CPU stoit na dzhojne.

### Pochemu podkachka 2.51 MB stoit 1.89 ms: pakety po ODNOJ, i eto vidno v vyvode

Vyvod progona nazyvaet mehanizm sam, esli postavit dva ego chisla rjadom:

    barjery (fence): podkachka 1902 (paketov 1902, vne paketa 0 promoushenov)
    podkachek 1902, 4.77 GB

**1902 paketa na 1902 podkachki - to est razmer paketa vsegda odin.** Mashinerija paketirovanija
napisana ("odin submit i odin fence na neskolko matric vmesto trjoh") i rabotaet, no vyzyvajushchij
cikl svodit ejo k minimumu: worker_loop (gpu_experts.cpp:948) beryot iz ocheredi ODNU podkachku i
oborachivaet ejo v `batch_begin(); upload(...); batch_end();`, prichjom `batch_end` zhdjot fence.
Znachit kazhdaja podkachka platit svoj submit i svoj zabor, skolko by ih ni stojalo v ocheredi.

Vnutri etih 1.89 ms:

    read_plain: mmap -> zakreplennaja promezhutochnaja pamjat   2.51 MB pri 24.8 GB/s   0.10 ms
    tri zapisannye kopii -> videopamjat po PCIe                2.51 MB pri 3.94 GB/s   0.64
    submit + fence na KAZHDUJU podkachku                                               ?
    ----------------------------------------------------------------------------------------
    izmereno                                                                           1.89

Objasneno 0.74 iz 1.89. Ostatok 1.15 ms na podkachku - eto 7.9 ms na tokjen, i podozrevaemyj
odin: submit s zaborom, kotoryj mog by prihoditsja na pachku, a prihoditsja na kazhduju.

Predskazanie na sledujushchij shag, do ego napisanija: esli slit vse ozhidajushchie podkachki v
odin paket (drenirovat ochered v worker_loop vmesto odnoj za prohod), pri 6.9 podkachkah na
tokjen paketov stanet 1-2 vmesto 6.9, i esli ostatok 1.15 ms dejstvitelno submit s zaborom, to

    podkachki na potoke karty   13.04 -> 5.5-6.5 ms/tokjen
    OSTATOK dzhojna              6.29 -> 2-3 ms/tokjen
    tokjen                      66.0 -> 60-62 ms, to est 16.1-16.5 tok/s

Esli ne dvinetsja - ostatok ne v submitah, i togda merit read_plain otdelno. Chitat nado
"podkachki zanjali potok karty" i "paketov", a ne tok/s: pervye dva u nih razbros pod procentom.

## Dva oprovergnutyh predskazanija delят odin mehanizm: polosa hostovoj pamjati

    paketirovanie podkachki:  sloj 29,63 -> 27,36 ms (-7,7%),  tokjen 15,242 -> 14,918 (-2,1%)
    snjatie barjerov:         sloj 29,69 -> 26,71    (-10,0%), tokjen 15,15  -> 14,78  (-2,4%)

Twice in a row, two independent changes: **the card's layer work got faster and the token got
slower**, by similar amounts. That is a mechanism, not a coincidence.

The candidate that fits everything measured: **the card and the CPU share host memory bandwidth, and
the CPU half is bandwidth-bound.** The prefetch reads host RAM (mmap -> pinned -> PCIe); the CPU's
expert half reads host RAM. The CPU half was separately measured to get *faster* with fewer threads,
which is the signature of a memory-bound workload rather than a core-bound one. So anything that makes
the card's host access more aggressive takes bandwidth from the CPU half, which is on the critical
path. Batching bursts the transfers; removing barriers lets reads issue sooner; both raise
instantaneous pressure on the same bus.

**This reframes where the +25% comes from.** We assumed the card being fast. If this holds, it is
because the card *removes host-RAM reads* - and prefetch traffic adds them back. The scheme wins by
subtraction, not by the device's speed.

The test is counterintuitive and is queued: **reduce the promotion budget**, sweeping down to a frozen
set. If the mechanism is real, the token gets faster while the hit rate gets worse - two figures moving
in opposite directions, which is hard to explain any other way. If the frozen-set arm is fastest, that
is a large and unwelcome conclusion about the resident-set design, and it should be measured rather
than argued.

Five predictions now written down before measuring and refuted: scheduler contention, promotions
blocking the worker, fusing the MoE tail, removing the barriers, batching the prefetch. The value was
never in any one of them being right - it is that two of the five turned out to share a cause, and
that only became visible because both were recorded with numbers instead of being applied and
forgotten.

## Vetka paketirovanija zakryta

    paket s ustupkoj potoka:  razmer paketa 6,765 -> 2,294 (-66%), zhdjom 15,275 -> 14,198 (-7,0%),
                              tok/s 14,702 -> 14,945 (+1,7%)
    protiv ishodnogo drain1:  zhdjom 11,403 -> 14,198 (+24,5%), tok/s 14,976 -> 14,945 (-0,2%)

Yielding the thread recovers most of what batching lost but does not beat the original one-at-a-time
path. Closed by the agent's own criterion, stated before the run.

This is the direct confirmation of rule 75: **one-at-a-time was already the smoothest**, and every
change that made the transfer lumpier cost more in waiting than it saved in transfer time. There is
nothing to win here, which is worth knowing precisely because it looked like the obvious win.

Running now: the budget sweep down to a frozen set - the counterintuitive test. If the shared-host-
bandwidth mechanism is right, the token gets faster while the hit rate gets worse.

## Paketirovanie podkachek: predskazanie oprovergnuto, i ono pjatoe

Zadanie prosilo drenirovat ochered podkachek v odin paket i predskazyvalo 13,04 -> 5,5-6,5 ms na
potoke karty, tokjen 66,0 -> 60-62, to est 16,1-16,5 tok/s. Sdelano (worker_loop berjot do
promo_drain_ podkachek za prohod pod odin submit i odin zabor), zamereno tremja raundami
vperemezhku s kontrbalansom, progrev na vybros. Korrektnost snjata do skorosti: 192 iz 192
tokenov v kazhdom pleche, 48 slotov videopamjati sverjeny s modelju POSLE generacii - 0
rashozhdenij.

    plecho    na paket   promo_ms/tok   zhdjom/tok   sloj ms   tok/s
    drain1      1,000       8,960         11,530     29,630    15,242  (razbros 0,5%)
    drain8      6,765       8,260         15,076     27,363    14,918  (razbros 0,8%)

**Mehanizm rabotaet rovno kak zadumano i vremeni eto ne pokupaet.** Paket sobralsja iz 6,77
podkachek (predskazano 6-8), zaborov v shest raz menshe, no podkachki na potoke karty upali
tolko na 7,8% - a ne vdvoe, - i ZHDJOM VYROSLO na 30,8%. Tokjen -2,1%.

Prichina rosta ozhidanija mehanicheskaja i ejo stoit zapisat: dispatch, prishedshij poka idjot
paket, stoit za VSEM paketom vmesto odnoj podkachki. Priem obmenjal chislo zaborov na
dlitelnost uderzhanija potoka, a CPU platit imenno za uderzhanie. Poetomu napisano tretje plecho
- paket zakryvaetsja srazu, kak tolko dispatch zhdjot (MEMEX_PROMO_YIELD):

    drain1      1,000       8,975         11,403     29,650    14,976  (razbros 0,4%)
    drain8      6,765       8,276         15,275     27,220    14,702  (razbros 0,2%)
    drain8y     2,294       8,553         14,198     27,210    14,945  (razbros 0,1%)

Ustupka vozvrashchaet tokjen k baze i ne obgonjaet ejo: -0,2% protiv drain1 pri razbrosah
0,1-0,4%. **Vetka paketirovanija zakryta: v luchshem sluchae nol.** Mehanizm ostavlen za
MEMEX_PROMO_DRAIN (po umolchaniju 1, to est predrenazhnoe povedenie), potomu chto vmeste s
menshim bjudzhetom on mozhet vyjti v pljus, a perepisyvat ego zanovo dorozhe, chem hranit.

### Baza byla nevernoj na 46%, i oshibka byla v znamenatele

13,04 ms/tokjen - eto ves ms_promote, delennyj na n_gen, vkljuchaja **pervichnuju zalivku
videopamjati**: 576 ekspertov, 1,44 GB, 775 ms, kotorye ni odin sgenerirovannyj tokjen ne
platil. Na generacii podkachki zanimajut potok karty **8,96 ms/tokjen**, i odna podkachka stoit
**1,30 ms**, a ne 1,89 - potomu chto 13,04 / 6,9 delilo total S zalivkoj na rate BEZ nejo.

Iz etogo srazu sleduet, chto ostatok byl pereocenjon: 1,30 izmerennyh protiv 0,74 objasnjonnyh
(0,10 chtenie fajla + 0,64 PCIe) - to est neobjasnjonnogo 0,56 ms, a ne 1,15. I paketirovanie
nashlo iz nih rovno 0,10: 1,300 -> 1,196 ms na podkachku pri shesti podkachkah pod odnim
zaborom. **Submit s zaborom stoil 0,10 ms na podkachku, a ne 1,15.** Ostajutsja 0,45 ms, i
sledujushchij instrument - zamerit read_plain otdelno, potomu chto eto edinstvennyj neizmerennyj
chlen.

Ispravleno v otchjote: ms_promote i promotions teper snimajutsja v bazu posle zalivki i
vychitajutsja, cena zalivki pechataetsja otdelno svoej strokoj.

## Otchjot pechatal teoreticheskoe i sudil po nemu, imeja izmerennoe na ekrane

Dvizhok pechatal "17,3 MB po PCIe pri 3,94 GB/s = 4,4 ms/tokjen" i dvadcatju strokami nizhe
"podkachki zanjali potok karty 13,04 ms/tokjen", a prigovor "podkachka sama sebja oplachivaet"
schitalsja **po teoreticheskim 4,4**. Oba chisla byli na ekrane sutki.

Teper obe velichiny stojat na sosednih strokah, i prigovor chitaet izmerennuju, nazyvaja, kakuju
imenno on prochital:

    podkachek 6,9 na tokjen = 17,3 MB po PCIe pri 3,94 GB/s = 4,4 ms/tokjen TEORETICHESKI
    IZMERENO na potoke karty: 8,9 ms/tokjen, 17,3 MB/tokjen, to est 1,94 GB/s - 0,49 ot kanala
      izbytok nad kanalom 4,5 ms/tokjen; paketov 1326 na 1326 podkachek = 1,00 na paket
    ... podkachki stojat 8,9 ms (IZMERENO) - menshe, to est podkachka sama sebja oplachivaet

Prigovor ne peremenilsja (27,8 ms sekonomleno protiv 8,9 potracheno), no teper on stoit na tom
chisle, kotoroe otnositsja k delu.

## Semejstva ocheredej RX 6500 XT: DMA est, i podkachka UZHE na njom

Perechisleno, ne predpolozheno (print_queues, syroj Vulkan, po obrazcu print_placement):

    semejstv ocheredej: 4
      semejstvo 0: ocheredej 8, 0x0f GRAPHICS COMPUTE TRANSFER SPARSE, metki 64 bit, gran 1x1x1
      semejstvo 1: ocheredej 4, 0x0e COMPUTE TRANSFER SPARSE,          metki 64 bit, gran 1x1x1
      semejstvo 2: ocheredej 1, 0x0c TRANSFER SPARSE,                  metki 64 bit, gran 16x16x8
      semejstvo 3: ocheredej 1, 0x20 (video decode),                   metki 0 bit
      vybor ggml: schjot - semejstvo 1, peredacha - semejstvo 2 = RAZNYE OCHEREDI

**Semejstvo tolko-peredachi est, i ggml uzhe ego vybiraet.** ggml_vk_find_queue_family_index
(ggml-vulkan.cpp:1585) ishchet TRANSFER, izbegaja COMPUTE i GRAPHICS, a nash paket zapisyvaetsja
v ctx->transfer_cmd_pool, kotoryj postroen na device->transfer_queue (ggml-vulkan.cpp:4162). To
est kopija uzhe idjot cherez DMA i uzhe perekryvaetsja so schjotom **na urovne ustrojstva**.

Znachit "vynesti podkachku na ochered peredachi" - uzhe sdelano, i ostavshajasja serializacija ne
v ocheredi, a **na hoste**: batch_end delaet ggml_vk_submit i tut zhe ggml_vk_wait_for_fence, a
tot (ggml-vulkan.cpp:1294) posle almost_ready **krutitsja v YIELD-cikle**, a ne spit. To est
potok karty ne prosto zanjat - on zhzhjot jadro, kotoroe nuzhno processornoj polovine.

Chto ponadobitsja, esli delat podkachku po-nastojashchemu asinhronnoj (i chego sejchas net):
  - **svoj zabor.** ctx->fence odin na vsjo, i graph_compute signalit ego zhe. Bez otdelnogo
    zabora (ili timeline-semafora) nelzja otlichit "doshjol paket" ot "doshjol graf".
  - **peredacha vladenija mezhdu semejstvami.** Bufery sozdajutsja VK_SHARING_MODE_EXCLUSIVE, a
    ggml_vk_sync_buffers stavit obychnyj barjer BEZ src/dstQueueFamilyIndex. To est zapis
    semejstvom 2 i chtenie semejstvom 1 formalno dajot neopredeljonnoe soderzhimoe uzhe sejchas;
    rabotaet ono potomu, chto batch_end sinhroniziruet na hoste do vozvrata. Uberjom hostovoe
    ozhidanie - i nuzhen libo CONCURRENT, libo para release/acquire. Eto latentnyj defekt v
    dereve, a ne sledstvie nashih pravok.
  - **otlozhennaja aktivacija gejtitsja imenno na zabore.** Maska ne dolzhna perevorachivatsja
    ranshe signala, i signal pridjot iz drugoj ocheredi.

## Zamorozhennyj nabor bystree churnujushchego na 10,5%, i eto krupnyj vyvod

Svip bjudzheta, dva povtora, kontrbalans, progrev na vybros. Korrektnost v kazhdom pleche: 192
iz 192 tokenov, 48 slotov videopamjati sverjeny s modelju posle generacii - 0 rashozhdenij.

    plecho    podkachek/tok  popadanij  promo_ms/tok  CPU/tok  zhdjom/tok  sloj ms  tok/s
    budget8       6,906       71,57%       8,998      16,460    11,340    29,715   14,798
    budget2       6,719       71,43%       8,716      15,688    11,367    29,685   15,051
    frozen        0,000       69,32%       0,000      16,421     7,390    27,710   16,347

Razbrosy 0,0-2,8%, po tok/s 0,1-1,1%.

**Nol podkachek - samoe bystroe plecho, +10,5% k tokjenu, a popadanija terjajut vsego 2,25
punkta.** Nabor, sobrannyj promptom, za 192 sgenerirovannyh tokena pochti ne ustarevaet - eto
soglasuetsja s ranee izmerennoj ustojchivostju (dolja sovpadenija ne padaet s k: 47,8% na k=1 i
52,3% na k=20). Churn pokupaet 2,25 punkta popadanij i stoit 1,55 tok/s.

**Bjudzhet - ne tot rychag.** budget 2 pochti ne svjazyvaet: 6,72 podkachki na tokjen protiv 6,91,
potomu chto on dejstvuet POSLOJNO i POREFRESHNO, a LFU prosit menshe dvuh na sloj za obnovlenie.
+1,7%, i eto vsjo, chto iz nego mozhno vyzhat. Rychag - period obnovlenija ili zamorozka, a ne
bjudzhet.

### Gipoteza polosy OZU predskazala VERNOE NAPRAVLENIE i oproverglas na svojom sobstvennom stolbce

Gipoteza byla: karta i processor deljat polosu ozu, podkachka otnimaet ejo u processornoj
poloviny, i poetomu vsjo, chto delaet obrashchenija karty agressivnee, uskorjaet sloj i
zamedljaet tokjen. Ejo sobstvennoe predskazanie: pri nule podkachek **processornaja polovina
dolzhna stat bystree**.

Ona ne stala: CPU/tok 16,460 -> 16,421 pri razbrosah 2,8% i 1,1%. To est nol.

A dvinulos drugoe: ZHDJOM 11,340 -> 7,390 (-3,95 ms) i sloj 29,715 -> 27,710 (-2,0 ms). Summa
5,95 ms protiv 6,41 ms, na kotorye realno ukorotilsja tokjen (67,58 -> 61,17 ms). To est
**vyigrysh polnostju objasnjaetsja zanjatostju POTOKA karty, i chlen polosy ne nuzhen vovse.**

Eto tot zhe diagnoz, chto uzhe stojal v STATE ("podkachki zanjali potok karty"), tolko teper on
podtverzhdjon plechom, kotoroe ubiraet podkachki celikom, a ne uskorjaet ih.

**I "dvazhdy podrjad sloj bystree, tokjen medlennee" - ne pravilo.** Iz dvuh sluchaev odin
neschitaem: v pleche bez barjerov arifmetika razrushena (0 iz 192 tokenov), i tok/s ottuda
ne zaschityvaetsja (pravilo 73). A frozen dajot sloj bystree I tokjen bystree odnovremenno. To
est znak sovpal odin raz iz dvuh validnyh nabljudenij, i mehanizm u nih odin - potok, a ne bus.

### Chto iz etogo delat, i chego ne delat

Zamorozka naveki - eto zamer, a ne konstrukcija: nabor ustarel by na dlinnoj generacii i na
smene temy (sdvig raspredelenija u nas izmeren - nabor s koda na russkom berjot 24,1% protiv
25,0% u sluchajnogo). Deshjovyj sledujushchij shag - **period obnovlenija**: sejchas 3 tokena, a
ustojchivost govorit, chto 32-64 hvatit. Eto dajot bolshuju chast +10,5% i sohranjaet adaptaciju,
i merjaetsja odnim flagom, kotoryj uzhe est (--resident-period).

Vtoroj shag, teper s izmerennym osnovaniem: **podkachka ne dolzhna zhit na potoke, kotorogo CPU
zhdjot na dzhojne.** Ochered peredachi u karty uzhe svoja, tak chto delo ne v ustrojstve - delo v
tom, chto batch_end sinhronno zhdjot zabor na tom zhe potoke. Otdelnyj zabor pljus opros vmesto
ozhidanija (i peredacha vladenija, sm. vyshe) - eto to, chto zamer nazval, a paketirovanie net.

## Rang po verojatnostnoj masse: izmeren i oprovergnut

On the existing code trace (tr_p_code.bin, full distributions, present since 11:26):

       C        LFU   po nedavnosti    po masse     orakul
       8      33,4%           36,3%       33,1%      59,9%
      16      49,7%           52,8%       49,0%      85,7%
      32      69,8%           71,6%       66,7%     100,0%
      64      87,9%           88,1%       84,5%     100,0%

Ranking by the router's probability mass is **consistently worse than plain LFU** at every capacity.
This was the strong form of the owner's idea and the one I had kept as the remaining hope for closing
the oracle gap. Refuted.

The best practical policy is recency-weighted frequency: +3,1 points over LFU at C=16.

**And the frozen-set measurement changes what any of this is worth.** 2,25 points of hit rate cost
1,55 tok/s in churn. So a policy is only worth having if it is **free in promotions** - recency
weighting is exactly that (same number of promotions, better chosen). Anything that buys hits by
promoting more is now known to lose.

Note these hit rates are lower than the 76,2% measured earlier at C=16: that was a mixed-content
trace, this one is code only. Not comparable across traces, only within.

## Period obnovlenija: umolchanie 3 bylo hudshim iz vseh

    period  podkachek/tok  popadanij  podkachka ms  zhdjom   tok/s (raund 1 / 2)
    3           6,91         71,6%        9,09      11,47    13,44
    16          2,37         71,7         3,05       9,33    16,07
    32          1,68         71,3         2,20       9,02    16,06 / 15,34
    64          0,95         71,2         1,24       8,12    14,62 / 15,79
    zamorozhen  0,00         69,3         0,00       7,29    16,47 / 16,38

From period 3 to 64 the promotions drop **sevenfold**, prefetch time goes 9,09 -> 1,24 ms, the wait
goes 11,47 -> 8,12, and the hit rate loses **0,4 points**. Period 64 even beats the frozen arm on hits
(71,2 against 69,3), so a long period captures nearly all of freezing's gain while still adapting.

**The default of 3 is the worst arm by a wide margin** - 13,44 against 16,4 for frozen. It was buying
0,4 points of hit rate with a sevenfold increase in promotion traffic. That is a one-line change worth
about +22%.

Caveat on what is not yet a result: frozen is tight (16,47 / 16,38, 0,5% spread) but periods 32 and 64
scatter above the floor (4,7% and 7,7%), and 16 and 3 have one replicate each. The ordering is clear;
the exact best period is not, and a third round is needed before naming one.

The adaptation data from the same session says the long period is also the *robust* choice: period 64
loses 2,1 points of plateau against period 3 but its dip after a domain switch is five times smaller
(5,5% against 28,1%). A frequently-refreshed set is more tightly fitted to the current domain and
therefore more brittle; recovery takes 76 tokens regardless of period, so recovery is bounded by the
observation window rather than by the refresh rate.

## Gorizont predskazanija po TOKENAM: izmeren, kontrol peremeshivaniem projden

Trassa koda, 2914 tokenov, 2039 na obuchenie / 811 na proverku. Metrika ta zhe, chto merit politika:
dolja ekspertov, dejstvitelno vybrannyh na tokene, popavshih v top-C ocenki.

    gorizont    C=16    peremeshan    chastota    raznica
           1  80.22%        32.68%      42.43%     +37.79
           8  59.78%        37.28%      42.43%     +17.35
          16  54.54%        37.44%      42.43%     +12.11

**Signal zatuhaet, no vyzhivaet.** Vosem tokenov vperjod - eto 490 ms uprezhdenija pri cene
podkachki v 1.300 ms, i tam vsjo eshchjo +17.35 punkta nad chastotoj. Porog otkaza byl +4.

**Kontrol reshajushchij i on projden.** Peremeshannye skrytye sostojanija dajut 37.28% protiv
59.78% u nastojashchih. Bolshe togo, peremeshannyj vhod **huzhe trivialnoj chastoty** (37.28 protiv
42.43): model ne prosto vyuchila chastotnyj prior, ona chitaet soderzhanie, i slomannyj vhod
uvodit ejo nizhe, chem otsutstvie modeli voobshche.

Chego eto NE govorit: sravnenija pri RAVNOM chisle podkachek zdes net, a imenno ono reshaet, stoit
li rabota v dvizhke. Kurs izmeren i zhestok - 2.25 punkta popadanij, kuplennye tekuchkoj, stoili
1.55 tok/s.

ISPRAVLENIE ISPRAVLENIJA. Zdes stojala tablica, gde submit+zabor stoit 0.10 ms, a 0.46 ms
nikomu ne prinadlezhit. Ona nevernaja, i ja prinjal ejo na veru, hotja pravilnoe chislo bylo u
menja RANSHE i ja sam ego nazval.

Otkuda vzjalas oshibka: STATE soderzhit vyvod "paketirovanie ubralo 0.10 ms, znachit submit+zabor
stoit 0.10". Eto podmena velichiny. 0.10 - eto to, chto paketirovanie UBRALO, a ne to, chto chlen
STOIT. Ostalnoe ne ubralos potomu, chto cena sidit v SINHRONNOM OZHIDANII zabora, a ne v ih
kolichestve.

Nastojashchee razlozhenie dvizhok pechatal vsjo eto vremja - vosem progonov `_psab_*.out` iz svipa
perioda:

    chtenie (memcpy mmap -> zakreplennaja, 7.37 GB/s)   0.341 ms   razbros 12.9%
    kopija zapisi                                       0.009
    submit + zabor                                      0.949      razbros  2.4%
    ostatok                                             0.007
                                                        -----
                                                        1.306      razbros  4.7%

Neprinadlezhashchih 0.46 ms NET, i vilki v shest raz ne bylo. Chtenie 0.341, a ne 0.10, potomu chto
0.10 schitalos po vosmipotochnoj polose 24.8 GB/s, a odnopotochnaja kopija 2.51 MB idjot na
7.37 GB/s.

**Chto iz etogo sleduet, i eto glavnoe.** 0.949 iz 1.306 - eto ozhidanie zabora na potoke. Uprezhdenie
ego ne ubiraet: skolko by tokenov vperjod my ni znali, potok stoit v ozhidanii. Ubiraet ego tolko
asinhronnaja peredacha na ocheredi DMA so svoim zaborom i peredachej vladenija - to samoe, chto
vladelec predlagal s samogo nachala i chego v dvizhke net. Cena voprosa - 0.949 ms na podkachku,
to est 73% ejo stoimosti.

Pol ceny podkachki: 0.357 ms, okupaemost 3.7 obrashchenija protiv 13.6 segodnja.

Uroki, oba dorogie:
1. **Ja zamenil svojo vernoe chislo chuzhim nevernym, potomu chto ono prishlo s tablicej.** Forma
   ubeditelnee soderzhanija, kogda proverjat lenivo.
2. **Dvizhok pechatal otvet v vosmi fajlah, kotorye lezhali na diske.** Eto pjatyj sluchaj za proekt,
   kogda iskomoe uzhe bylo sobrano. METHODS 76 napisano rovno pro eto.
statji zakryta pravilno.

## Frontier pri RAVNYH podkachkah: predskazatel proigryvaet chastote. Napravlenie zakryto

Sled koda, 2914 tokenov, obuchenie 0..2039, ocenka 2103..2914 (811 tokenov), 46 sloev, C=16.
Sravnenie na odnoj i toj zhe trasse, v odnom progone, pri ravnom chisle podkachek na tokjen.

**Podtverzhdeno na drugih emkostjah**, chtoby vyvod ne okazalsja svojstvom C=16: pri C=12 i C=24
kartina ta zhe - 57 otricatelnyh tochek protiv 8, luchshee v rabochej oblasti +1,21 punkta pri
0,33 podkachki. Maksimum +2,67 opjat tam zhe, gde on bespolezen - pri 46 podkachkah na tokjen.

**Iz 97 tochek 89 otricatelnyh i 8 polozhitelnyh.** Luchshaja - +1.85 punkta pri 46 podkachkah na
tokjen, chto pri 1.306 ms kazhdaja stoit 60 ms pri tokene v 61.2, to est udvaivaet tokjen. V
rabochej oblasti (1-9 podkachek) luchshee, chto est, - +0.60 punkta. Porog otkaza byl +4.

    hor32 period 32    podkachek  1.43   predskazatel 44.10%   chastota 44.25%   -0.15
    hor32 period 8     podkachek  5.51   predskazatel 45.57%   chastota 47.02%   -1.45
    hor32 period 4     podkachek 10.91   predskazatel 46.41%   chastota 49.92%   -3.51
    hor64 period 1     podkachek 41.87   predskazatel 47.77%   chastota 56.37%   -8.60

Zamette: chem BOLSHE podkachek, tem huzhe predskazatel otnositelno chastoty. Eto ne shum, eto
sistematika.

### Pochemu tochnyj predskazatel daet hudshuju politiku

Polnota otvechaet na vopros "budet li etot ekspert vostrebovan". Politika trebuet otveta na drugoj:
"budet li on vostrebovan DOSTATOCHNO CHASTO, chtoby otbit 13.6 obrashchenij". Eto raznye voprosy, i
chastotnaja tablica otvechaet na vtoroj naprjamuju - potomu chto chastota i est ozhidaemoe chislo
obrashchenij.

Predskazatel vybiraet togo, kto nuzhen SKORO. Rezidentnyj nabor dolzhen derzhat togo, kto nuzhen
MNOGO RAZ. Pri cene podkachki v 13.6 obrashchenij "skoro" ne stoit nichego.

### Chto pri etom NE oprovergnuto

Signal nastojashchij i krupnyj: +37.79 punkta polnoty nad chastotoj pri gorizonte 1, i kontrol
peremeshivaniem projden s zapasom (peremeshannyj vhod dajot 28.55% protiv 42.02% u chastoty - to
est huzhe otsutstvija modeli, znachit model chitaet soderzhanie, a ne prior). Model rabotaet. Ona
prosto reshaet ne tu zadachu, kotoraja u nas est.

Eto znachit, chto predskazatel mog by okupitsja tolko tam, gde podkachka deshevaja - to est POSLE
asinhronnoj peredachi, kogda cena padaet s 13.6 do 3.7 obrashchenij. Do togo merit ego snova
nezachem.

## Uchenyj predskazatel rezidentnogo nabora: tochen, i pri ravnyh podkachkah ne bjot LFU

SpecPrefetch (arXiv 2607.24787) na nashej modeli, na nashih trassah. Vsjo poschitano na odnoj
trasse v odnom progone - LFU, nedavnost i orakul rjadom s predskazatelem, potomu chto chisla iz
raznyh trass zdes ne sravnimy.

**Signal est i on krupnyj.** Poslojnoe linejnoe otobrazhenie iz vhoda marshrutizatora sloja L v
ekspertov sloja L+1 (ridge, to est predel po rangu i verhnjaja granica ljubogo rank-r adaptera):
R@8 62,1%, **R@16 80,2%**, R@24 87,3% na otlozhennyh tokenah, protiv chastotnyh 29,2 / 45,9 / 57,8.
Staryj otricatelnyj zamer ("sloj L ne predskazyvaet L+1", 6,0% protiv pola 6,25%) etomu ne
protivorechit: on meril ID protiv ID, a ne skrytoe sostojanie.

**Forma iz statji u nas ne rabotaet.** Statja delit OBA A i B mezhdu slojami; u nas obshchie A i B
dajut R@16 = **37,5%**, to est NIZHE chastotnoj bazovoj linii. Obshchij A r=128 s poslojnym B dajot
77,3%. Golova objazana byt poslojnoj - eto tot zhe nash rezultat, chto indeks eksperta znachit
raznoe v kazhdom sloe.

**Zapas po vremeni ne uzkoe mesto:** R@16 = 80,2 / 79,5 / 78,1 / 76,1 pri zapase 1 / 2 / 4 / 8
sloev. Vosem sloev - eto ~10 ms, semikratnyj zapas nad cenoj peredachi.

**I vsjo eto ne obnalichivaetsja.** Frontier pri RAVNYH podkachkah na tokjen, C=16:

    podkachek/tok   chastota   luchshij predskazatel   raznica
        0,00        42,02%          43,07%            +1,04
        0,74        43,86           43,92             +0,06
        1,47        44,26           44,64             +0,38
        2,89        45,55           45,25             -0,28
        5,79        47,57           46,83             -0,66
       11,51        50,15           49,61             -0,52

Maksimum **+1,04 punkta**, i tot v tochke nulevyh podkachek; po kursu eto +0,10 tok/s = **+0,6%**
pri pole shuma 4,2%. Porog, zapisannyj do zamera, byl +4 punkta. V dvizhok ne vodim.

Chetyre gorizontnyh semejstva (obuchennye na spros za sledujushchie K tokenov imenno radi
medlennosti) idut po nulju ili v minus. Ih vidimoe preimushchestvo (+8,3 punkta) bylo protiv
STATICHESKOJ chastotnoj tablicy; onlajnovoe chastotnoe okno vidit nastojashchie vybory, a
predskazatel ih tolko vyvodit. I eti +8,3 trebujut perevybora kazhdyj tokjen: 43,4 podkachki na
tokjen.

### Kurs obmena, i pochemu "tridcat punktov" - ne to chislo

Odin punkt popadanij = 3,84 obrashchenija x 0,0957 ms = **0,368 ms na tokjen**. Znachit odna
podkachka na tokjen stoit **3,55 punkta popadanij segodnja** i 0,97 na polu. Proverka protiv
zamera, sdelannogo ranshe modeli: period3 protiv frozen predskazan v 14,50 tok/s protiv
izmerennyh 14,14 - 2,5% pri pole 4,2%.

Orakul pri TEH ZHE podkachkah, a ne bespriceljnyj:

    podkachek/tok   orakul   chastota   razryv         cena
        2,55        54,11%    45,01%     9,10 punkta   +0,96 tok/s (+5,8%)
        5,78        58,66     47,50     11,16          +1,19       (+7,2%)
       11,89        64,08     50,31     13,77          +1,50       (+9,1%)

85,7% orakula merilis pri neogranichennyh podkachkah. Pri bjudzhete, kotoryj mashina platit,
razryv **9-11 punktov**, a ne 30. Razryv nastojashchij - no orakulu pomogaet znanie BUDUSHCHEGO,
a sloj skrytogo sostojanija dajot znanie NASTOJASHCHEGO, i imenno poetomu predskazatel berjot iz
nego okolo odnogo punkta.

### Cena podkachki razlozhena polnostju, i neizvestnogo chlena net

Dvizhok pechatal eto sam v vosmi progonah `_psab_*.out`, i nikto ne chital:

    chtenie (memcpy otobrazhenie -> zakreplennaja, 7,37 GB/s odnopotochno)  0,341 ms  (12,9%)
    zapis kopii                                                            0,009
    submit + zabor (PCIe vnutri ozhidanija)                                0,949     (2,4%)
    ostatok                                                                0,007
                                                                           1,306 ms  (4,7%)

Prezhnjaja zapis v STATE ("submit s zaborom stoil 0,10 ms") byla nevernoj: 0,10 - eto skolko ubralo
paketirovanie, a ne skolko stoit termin. Ne ubralos ostalnoe potomu, chto cena v OZHIDANII zabora,
a ne v ih chisle. I chtenie ne 0,10 a 0,341, potomu chto 0,10 schitalos po 24,8 GB/s
vosmipotochnogo streama, a odnopotochnyj memcpy na 2,51 MB dajot 7,37.

**Sledujushchij rychag - eti 0,949 ms, a ne politika.** Ubrat ih - eto 3,55 -> 0,97 punkta za
podkachku, vtroe deshevle churn, i eto edinstvennoe, chto delaet 9-11 punktov razryva orakula
dostizhimymi hot kakoj-nibud politikoj. Forma SpecPrefetch mertva v ljubom sluchae: 47 podkachek
na tokjen - eto 61,4 ms segodnja i 16,8 ms dazhe na polu, pri tokene v 61,2 ms.

### Zaodno: tretij raund svipa perioda uzhe byl sobran

Iz teh zhe `_psab_*.out`: **frozen 16,41/16,49 (razbros 0,5%) protiv period3 14,10/14,19 (0,6%)**,
oba plecha chistye, raznica **+16,3%**. Umolchanie `--resident-period 3` podtverzhdeno kak hudshee
na dvuh tugih replikah. Periody 16/32/64 po-prezhnemu ne rezultat (razbrosy 12,6% i 5,8%; u 64
odna replika).

## Umolchanie perioda: 3 -> 32. Reshaetsja ne po tok/s, a po tochnym velichinam

Tri repliki, dva plecha, odna sessija, vperemeshku i vstrechnym porjadkom, progrev otbroshen.

              podkachek/tok   popadanij    tok/s
    period 3      6,906        71,569%     14,634   (razbros 5,7%)
    period 32     1,677        71,313%     15,972   (razbros 8,4%)
                razbros 0,0%  razbros 0,0%

**Skorost u oboih plech grjaznaja - vyshe poroga 4,2%. Reshenie na nej ne stoit.** Ono stoit na
dvuh velichinah, u kotoryh razbros NULEVOJ: chislo podkachek i dolja popadanij. Period 32 berjot
tu zhe dolju popadanij (-0,26 punkta) za chetvert podkachek (-5,23 na tokjen).

Po izmerennomu kursu: 5,23 x 1,297 - 0,26 x 0,368 = **+6,68 ms na tokjen**, to est 68,3 -> 61,6 ms
= 16,23 tok/s. Izmereno 15,972, rashozhdenie 1,6%.

To est shumnaja raznica v skorosti podtverzhdaetsja tochnoj arifmetikoj na tochnyh vhodah - i eto
sposob poluchit otvet tam, gde sam otvet izmerjaetsja gryazno. Zapisyvat tak vsegda, kogda
promezhutochnye velichiny chishche konechnoj.

Pobochno: `submit+zabor` podtverzhdjon tretij raz - 0,957 i 0,955 pri razbrosah 4,2 i 4,0%,
edinstvennye chistye stroki vo vsjom razlozhenii podkachki.

## Spin protiv blokirujushchego ozhidanija: nichego. I prichina byla vidna do sborki

    spin         13,902 tok/s   razbros 6,0%   RAZBROS VYSHE POROGA
    sleep        14,226         razbros 2,8%

+2,3% pri pole shuma 4,2% i odnom plече vyshe poroga. Ne rezultat. Predskazanie bylo +6,9%.

**Pochemu predskazanie bylo nevernym, i eto schitalos zaranee.** Ja zhdal vyigrysha ot togo, chto
osvobozhdaetsja JADRO. No svjazyvajushchij resurs - ne jadro, a POTOK: spin i blokirujushchee
ozhidanie derzhat rabochij potok odinakovoe stennoe vremja. Oba plecha zanimajut ego rovno tak zhe,
znachit zamer ne mog pokazat nichego. Arifmetika na dvuh strochkah, i ejo nado bylo sdelat do
sborki, a ne posle progona.

**Chto eto utochnjaet v mehanizme zamorozhennogo nabora - i utochnjaet v poleznuju storonu.**
Delo ne v konkurencii za jadro. Delo v tom, chto podkachka zanimaet TOT ZHE rabochij potok,
kotorogo zhdjot dispatch: u GpuExperts odin potok i on sluzhit dvum gospodam. Znachit
asinhronnaja otpravka - edinstvennoe, chto dejstvitelno otpuskaet potok - po-prezhnemu imeet
smysl, a zamena sposoba ozhidanija smysla ne imela.

Izmenenie ostavleno: ono ne vredit, ubiraet skrytuju gonku dvuh potokov za obshchij zabor
(u peredach teper svoj) i dajot pereklychatel GGML_VK_BATCH_SPIN dlja budushchih zamerov.

**Pravilo, kotoroe iz etogo sleduet.** Pered tem kak stroit plecho, nazvat SVJAZYVAJUSHCHIJ
RESURS i proverit, chto plecho ego menjaet. Esli oba plecha tratjat ego odinakovo - zamer
pustoj, i eto vidno na bumage.

## Iz chego sostoit dispatch: uchjot zakryt, i 27% tokjena okazalos ne tam, gde ja iskal

Tri repliki, period 32, odno plecho. Chetyre tajmera vnutri compute() nazyvajut vsjo, chto ona
delaet, i summa shoditsja s ms_job s tochnostju 0,7% - eto pogreshnost samogo instrumenta.

    graf      15,63 ms/tokjen   72,4%   razbros 4,0%
    chtenie    5,45             25,2%           2,8%
    razbor     0,21              1,0%
    vhod       0,16              0,7%
    ostatok    0,15              0,7%
              -----
              21,60                             3,6%

**Chtenie rezultata obratno stoit 5,45 ms na tokjen - 113 us na sloj za 46 KB.** Pol odnogo
kruga submit+zabor izmeren ranee kak 59 us, i 113 - eto rovno dva takih kruga:
`ggml_backend_graph_compute` otpravljaet i zhdjot zabor, potom `ggml_backend_tensor_get`
otpravljaet i zhdjot VTOROJ. Bajty tut ni pri chjom - 46 KB po shine eto mikrosekundy.

Esli dopisat kopiju rezultata v tot zhe komandnyj bufer, chto i matmuly, krug ostajotsja odin:
**okolo 2,8 ms na tokjen, poriadka 4,6%**. Eto schitannaja cena, a ne ozhidanie.

**Graf: 326 us na sloj pri 104 us bajtov.** Vychest pol v 59 us - ostajotsja 267 us schjota na
dannye, kotorye chitajutsja za 104. To est jadra mul_mat_id po IQ4_XS v Vulkan idut primerno na
38% polosy videopamjati. Eto uzhe ne organizacija raboty, a effektivnost samih jader.

**Pochemu eto vazhnee vsego, chem ja zanimalsja segodnja.** 21,6 ms iz tokjena v 61 ms - eto
35%, i iz nih na bajty prihoditsja 5,0. Ostalnye 16,6 ms - 27% tokjena - eto organizacija
raboty i neeffektivnost jader. Predskazatel, period i sposob ozhidanija borolis za 6-9% v
drugoj chasti tokjena.

### Tri sposoba ubrat chtenie, s cenami

Napravlenie reshaet vsjo: zapis na kartu izmerena v 0,003 ms, chtenie s karty - 0,116. Sorok raz,
i eto fizika, a ne nastrojka - zapisi cherez otobrazhenie objedinjajutsja v pakety, chtenija net.

    1. vyhod srazu v ZAKREPLJONNUJU pamjat hosta   ~5,4 ms/tok   pravka provodki vyhoda
    2. slit chtenie s otpravkoj grafa               ~2,8 ms/tok   hirurgija v graph_compute
    3. karta vladeet slojem celikom                ~11+ ms/tok   perestrojka

Variant 3 - eto ne pravka. Slozhenie polovin delaetsja V PROCESSORNOM grafe
(`ggml_add(o_res, o_oth)`, memex-fwd.cpp:2400), to est karta u nas ne hozjain sloja, a vyzyvaemaja
sluzhba; vnimanie na karte ustroeno tak zhe. Chtoby karta vladela slojem, nado perestroit graf
sloja, a ne peredelat odin vyzov.

Variant 1 - samyj deshjovyj po risku i samyj dorogoj po otdache: esli vyhodnoj tenzor lezhit v
zakrepljonnoj hostovoj pamjati, zaregistrirovannoj v Vulkan, karta pishet tuda posledim uzlom
grafa (DMA-zapis, ne BAR), a host potom chitaet SVOJO OZU - besplatno. Ni vtoroj otpravki, ni
zabora, ni chtenija po shine.

## Chtenie, slozhennoe v komandnyj bufer grafa: -4,78 ms na tokjen

Odna replika plecha `fold`, period 32, korrektnost cela (192 iz 192):

                        bylo      stalo
    graf               15,63     16,28    +0,65
    chtenie             5,45      0,0017  ischezlo
    ms_job             21,60     16,82    **-4,78 ms/tokjen**

**Predskazanie bylo +2,7 ms, vyshlo +4,78, i oshibka pouchitelnaja.** Ja schital, chto kopija,
pereehav vnutr grafa, prinesjot s soboj svoi 2,7 ms. Ona prinesla **0,65**. To est 5,45 ms byli
pochti celikom KRUG obrashchenija k ustrojstvu, a sama peredacha 46 KB - shest sotyh
millisekundy, kak i polozheno po shine.

Obobshchenie, kotoroe stoit derzhat: **kogda operacija stoit na dva poriadka bolshe svoih bajtov,
cena - eto krug, i ejo nado ubirat celikom, a ne uskorjat peredachu.** Ja proveril eto pered
sborkoj (46 KB za 113 us eto 0,4 GB/s protiv ~8 us po shine) - i vsjo ravno zalozhil v prognoz
polovinu ceny kak neustranimuju.

Realizacija: `ggml_backend_vk_arm_readback` v ggml-vulkan.cpp zapisyvaet kopiju v tot zhe
komandnyj bufer, chto i posledinj uzel grafa. Tolko posledinj uzel - bolee rannij submit
skopiroval by vyhod, kotoryj graf eshchjo ne dopisal. Poluchatel objazan byt zakrepljonnym:
togda ggml_vk_buffer_read_2d_async zapisyvaet prostoj copyBuffer bez promezhutochnogo bufera i
bez otlozhennyh memcpy, i skladyvat ejo bezopasno. Pri otkaze - staryj put, huzhe ne stanovitsja.

Pereklychatel MEMEX_FOLD_READBACK=0 vozvrashchaet staroe povedenie; vetka nazyvaet sebja strokoj
FOLD_READBACK on|off, skript sverjaet (pravilo 68).

### A/B slozhennogo chtenija: 4,21 ms s karty snjaty, tokjen ne uskorilsja

Tri repliki, dva plecha, odin binarnik, vperemeshku i vstrechnym porjadkom.

                 tok/s   razbros    karta/tok  zhdjom  CPU/tok
    fold        16,902     3,8%       16,850    6,38    15,06
    sep         15,354    26,9%       21,056    8,82    18,11
    sep bez zagrjaznjonnogo kruga 1: 16,72 / 16,74 -> 16,73, razbros 0,1%

**Vremja karty upalo na 4,21 ms - chisto, razbros 0,4%, rovno kak obeshchalo razlozhenie.
Tokjen ne uskorilsja: +1,0%, pod porogom.** Korrektnost cela vo vseh shesti progonah.

Kuda deli 4,21 ms: dzhojn-ozhidanie upalo s 8,82 do 6,38, to est 2,4 ms karta prosto perestala
zastavljat processor zhdat. Ostalnoe rastvorilos - vremja sloja ne sokratilos.

**GLAVNOE, i ono menjaet porjadok vsej dalnejshej raboty:**

    do:     karta 21,06   processor 15,06    karta dlinnee na 6,0
    posle:  karta 16,85   processor 15,06    raznica 1,8

**Karta perestala byt uzkim mestom.** Znachit 11 ms nakladnyh v jadrah mul_mat_id, za kotorye ja
sobiralsja bratsja sledujushchim shagom, **teper pochti nichego ne stojat**: uskorjat uzhe ne
dlinnuju storonu, vyigrysh ujdjot v ozhidanie celikom. Sledujushchij shag lezhit na PROCESSORNOJ
polovine.

Izmenenie ostavleno: raboty objektivno menshe, korrektnost cela, karta bolshe ne dlinnaja
storona. No uskoreniem eto nazyvat nelzja.

### Dyrka v obvjazke, najdennaja etim progonom

Plecho `sep` v kruge 1 dalo CPU/tok 25,15 pri normalnyh 14,6 - mashina byla zanjata. Skript etogo
NE otbrakoval: u nego porog po razbrosu MEZHDU replikami, a ne po anomalii VNUTRI odnoj. Odna
isporchennaja replika iz trjoh razdula razbros plecha do 26,9% i chut ne pohoronila vyvod.

Chinit tak: sravnivat CPU/tok repliki s medianoj plecha i vybrasyvat vsjo, chto othoditsja bolshe
chem na 30%. CPU/tok - horoshij storozh imenno potomu, chto ot nashih izmenenij on ne dolzhen
zaviset vovse.

## SKLADYVANIE CHTENIJA: 18,55 tok/s, +11,1%. Luchshij rezultat proekta

Tri repliki, dva plecha, odin binarnik, vperemeshku i vstrechnym porjadkom. Pereklychatel
MEMEX_FOLD_READBACK upravljaet OBOIMI skladyvanijami - i u ekspertov, i u statiki - tak chto eto
ih summa.

                     tok/s    razbros     sloj      karta     zhdjom
    fold            18,550     4,2%      23,183    17,041     6,31
    sep             16,112    11,1%      26,950    20,764     9,28
    sep bez zagrjaznjonnogo kruga 1: 16,71 / 16,69 -> 16,70, razbros 0,1%

Korrektnost: 192 iz 192 vo vseh shesti progonah, 0 rashozhdenij po 48 slotam.

**Reshajut ne tok/s** (u fold razbros rovno na pole 4,2%), a parnye velichiny, obe chistye:
sloj 23,18 protiv 26,95 pri razbrosah 2,9 i 3,8%, i karta 17,04 protiv 20,76 pri 0,6 i 2,5%.
S ustrojstva snjato 7,5 ms, do tokjena doshlo 6,0.

    etalon forka, chistyj processor     9,04 tok/s
    nash processornyj put            11,98
    predydushchij luchshij (frozen)   16,41
    sejchas (period 32, adaptivno)   18,55    +54,8% k processornomu, 2,05x k etalonu

**Vsjo eto vzjato iz odnogo defekta**, kotoryj sidel v trjoh mestah i vezde prjatalsja za odnoj i
toj zhe myslju: "tam zhe vsego 46 KB, chto tam mozhet stoit". Obrashchenie k ustrojstvu stoilo DVA
kruga vmesto odnogo, a cena kruga - 59 us nezavisimo ot chisla bajt.

**Kak iskat ostalnye takie mesta:** podelit izmerennoe vremja operacii na ejo bajty i sravnit s
polosoj ustrojstva. Vsjo, chto medlennee polosy v desjatki raz, - eto krugi, a ne peredacha.

### Podrobno po statike (odna replika, chtoby vidno bylo mehanizm)

                              bylo      stalo
    zabor na peresechenie    0,109     0,002    ischez
    ustrojstvo               0,459     0,462    +0,003 - kopija vnutri grafa pochti darom
    na tokjen               28,00     22,97     -5,03 ms

Odna replika, period 32, korrektnost cela (192 iz 192):

                              bylo      stalo
    zabor na peresechenie    0,109     0,002    ischez
    ustrojstvo               0,459     0,462    +0,003 - kopija vnutri grafa pochti darom
    na tokjen               28,00     22,97     -5,03 ms
    tok/s                   17,16     18,85     **+9,8%**

Etalon v tom zhe progone 9,03 tok/s, to est **2,09 raza** protiv chistogo processornogo puti forka.

**I zdes ekonomija DOSHLA do tokjena celikom**, v otlichie ot ekspertnogo puti, gde te zhe 4,78 ms
rastvorilis v dzhojn-ozhidanii. Prichina napisana byla ZARANEE: u statiki net vtoroj storony,
kotoraja mogla by poglotit vyigrysh - processornyj potok stoit na etom puti zablokirovannym,
potomu chto sloj vypolnjaetsja vnutri ggml_map_custom na tom zhe potoke.

**Obobshchenie, radi kotorogo vsjo eto stoit chitat.** Odna i ta zhe bolezn nashlas v trjoh mestah
srazu, i vezde ejo prjatal odin i tot zhe schjot: "eto zhe vsego 46 KB, chto tam mozhet stoit".
Cena kruga obrashchenija k ustrojstvu - 59 us NEZAVISIMO ot chisla bajt. Znachit vezde, gde
operacija stoit na dva porjadka bolshe svoih bajtov, iskat nado krug, a ne polosu.

Ostavshiesja mesta togo zhe roda stoit iskat po tomu zhe priznaku: podelit izmerennoe vremja
operacii na ejo bajty i sravnit s polosoj ustrojstva. Vsjo, chto medlennee polosy v desjatki raz,
- eto krugi.

## Barjery: oprovergnuty. Otpravki: ih dva, a ne shest. Razryv 119/25 GB/s ostajotsja

### Suzhennye barjery ne dajut nichego

    narrow (GGML_VK_NARROW_SYNC=2)   18,242 tok/s   sloj 23,487
    full                             17,807         sloj 23,163
    po chistym krugam full daže bystree: 18,57/18,91 -> 18,74 protiv 18,24

Bezuslovnyj polnyj barjer pered kazhdym dispatchem - ne prichina. Odin kandidat iz trjoh vybyl.

### Otpravok dva na graf, a ne 6,62

GGML_VK_SUBMIT_STATS na tekushchej sborke:

    uzlov v splite 29: grafov 624, submitov **2,00** na graf
    vsego: grafov 2518, uzlov 24084 (9,6 na graf), submitov 3428 (1,36 na graf)

Cifra 6,62 iz `submit_policy.log` - staryj svip, snjatyj do togo, kak
`GGML_VK_SUBMIT_DIVISOR=1` i `TAIL=0` stali umolchaniem dlja `--gpu-static-layers`
(memex-fwd.cpp:5705, do sozdanija ustrojstva - to est primenjaetsja).

Dva vmesto odnogo - eto lishnjaja otpravka na kazhdoe peresechenie: 24,1 us x 49 = **1,18 ms na
tokjen**, okolo 2%. Merjaetsja DIVISOR=0 protiv 1.

### Chto ostajotsja neobjasnjonnym, i eto glavnoe

Nash zhe otchjot, chetyre stroki drug ot druga:

    golova na karte:          2,049 ms na 243,4 MB  ->  119 GB/s   (1 dispatch)
    vnimanie i marshrutizator: 0,476 ms na  12,1 MB  ->   25,4 GB/s (29 uzlov, 2 otpravki)

Odna karta, odin progon, odno semejstvo jader. Raschjot dlja peresechenija vnimanija:

    bajty                       92 us
    dve otpravki                48 us
    barjery                      0 us (izmereno vyshe)
    ------------------------------------
    objasneno                  140 us iz 476
    NE OBJASNENO               336 us = 11,6 us na kazhdyj iz 29 uzlov

**11,6 us na dispatch protiv 2,99 us, iz kotoryh schitalsja ves nash plan.** I 2,99 byl naklon,
poluchennyj udaleniem devjati SAMYH DESHJOVYH uzlov - to est predelnaja cena deshjovyh, a ne
srednjaja. Vyvod "rezat uzly dajot maksimum 0,5%" stojal na etom naklone i nedejstvitelen.

Vnimanie s marshrutizatorom - 559 MB na tokjen. Pri 131 GB/s eto 4,3 ms; izmereno 23,63.
**19,3 ms na tokjen - 35% - sidjat v etom razryve.**

Instrument, kotoryj ego razdelit: SREZ GRAFA PO UZLAM. Sobirat tot zhe graf vnimanija,
obrezannyj na uzle K, i chitat vremja ustrojstva. Prirashchenie ot K k K+1 - istinnaja cena uzla K
vmeste s ego barjerom i otpravkoj. Metki vremeni po uzlam etogo ne dajut: barjer pripisyvaet
malenkoj operacii sliv bolshoj. Srez ne mozhet oshibitsja - barjer vhodit v to, chto ubrali.

## SREZ GRAFA: 310 mks postojannoj ceny na kazhdoe peresechenie. 28% tokjena

Sposob: MEMEX_STATIC_TRUNC=N stroit graf sloja tolko do etapa N. Vyhod pri etom NEVERNYJ - eto i
delaet ego instrumentom (pravilo 73): vremja ustrojstva ot znachenij ne zavisit, znachit
prirashchenie ot etapa k etapu - istinnaja cena udaljonnyh uzlov vmeste s ih barjerami i
otpravkami. Metki po uzlam etogo ne dajut (METHODS 80).

    K=1   1 uzel  (tolko norma vhoda)   0,310 ms   <-- ODIN uzel
    K=2  10 uzlov (+ proekcii q,k,v)    0,453
    K=3   9 uzlov                       0,419
    K=5  19 uzlov (+ kq)                0,501
    K=7  23 uzla  (+ kqv)               0,502
    K=8  25 uzlov (+ o_proj)            0,570
    K=0  29 uzlov (polnyj graf)         0,582

**Odin uzel - fused_rms_norm na 2048 chislah, 8 KB - stoit 0,310 ms. 53% vsego peresechenija.**

Uchjot skladyvaetsja tochno:

    postojannaja cena peresechenija     310 us
    28 uzlov x 9,7 us                   272
    ------------------------------------------
    itogo                               582   izmereno 582

**Delo ne v uzlah i ne v jadrah.** Est fiksirovannye 310 us na kazhdyj vyzov graph_compute,
kotorye platjatsja dazhe za odin trivialnyj uzel. Na 49 peresechenij eto **15,2 ms na tokjen,
28% tokjena.**

Vot pochemu vsjo, chto ja proverjal, davalo nol: barjery, otpravki, ROPE, chislo uzlov - oni vse
pro te 272 us, a ne pro 310. I 9,7 us na uzel blizko k izmerennym ranee 7,2, to est tot naklon
byl VEREN - on prosto meril ne to, chto sostavljaet cenu.

**Gde iz etogo 20+.** Odno peresechenie vmesto 49 ekonomit 14,9 ms: tokjen 53,9 -> 39 ms, to est
**25,6 tok/s**. Prepjatstvie izvestno: vnimanie sloja L+1 trebuet vyhoda MoE sloja L, kotoryj
schitaet processor, znachit odnim grafom 48 sloev ne sobrat, poka MoE na processore.

**Chto neizvestno i merjaetsja sledujushchim.** Iz chego sostojat 310 us. Ranee pol graph_compute
s zaborom byl izmeren v 59 us - vpjatero menshe. Libo tot zamer byl v drugih uslovijah, libo zdes
est chto-to eshchjo. Do etogo otveta ljuboj plan po sokrashcheniju peresechenij prezhdevremenen.

### Iz chego 310 mks: krug ozhidanija zabora, i on strukturno neizbezhen po CHISLU

`ggml_vk_compute_forward` (ggml-vulkan.cpp:9768) otpravljaet komandnyj bufer i zhdjot zabor,
prichjom **zabor tolko u poslednego otpravlenija** - rannie iduт s `vk::Fence{}`, vystrelil i
zabyl. Eto objasnjaet, pochemu zamer otpravok dal nol: ih dve, a krug ozhidanija odin.

Znachit 310 us - eto odin krug "otpravil -> planirovshchik Windows -> karta poschitala -> signal ->
host uvidel", i on platitsja za kazhdyj graph_compute nezavisimo ot chisla uzlov v njom.

**Proverka na golove shoditsja:** odin vyzov na tokjen, odin dispatch na 243 MB, vremja 2,049 ms
pri bajtah na 1,86 - nakladnye 190 us. Tot zhe porjadok.

**Chto eto menjaet v ocenke vsej shemy.** Vnimanie na karte stoit 23,63 ms, iz kotoryh **14,9 -
krugi ozhidanija**, a samo vychislenie okolo 8,7. Na processore ono stoilo by 25,0. To est karta
schitaet vnimanie VTROE bystree processora, i my etogo ne vidim tolko potomu, chto 48 raz za
tokjen zhdjom planirovshchik.

**Ubrat peresechenija nelzja.** Marshrutizator reshaet, kakih ekspertov brat, po vyhodu vnimanija;
razdelenie "rezidentnye na karte, ostalnye na processore" zavisit ot etogo reshenija. Sinhronizacija
na kazhdom sloe vstroena v samu shemu, a ne v ejo realizaciju.

**Znachit rychag - cena odnogo kruga, a ne ih chislo.** Napravlenie: ne zhdat zabor cherez drajver,
a dat karte poslednim dejstviem zapisat flag v pamjat hosta i oprashivat ego - eto ubiraet perehod
v jadro OS i planirovshchik iz kriticheskogo puti. Cena voprosa pri padenii 310 -> 60 us:
49 x 250 us = **12,3 ms na tokjen, okolo 24 tok/s**.

### Iz chego 310 mks: izmereno po chastjam, i eto NE nash hostovyj kod

Tri pribora na odnoj konfiguracii (MEMEX_STATIC_TRUNC=1, odin uzel v grafe):

    hostovaja chast do submita (suhoj prohod, deskriptory, prealloc)   3,4-7,1 us   min 0,2
    submit                                                             20-29 us
    ozhidanie zabora                                                   ~240 us
    -------------------------------------------------------------------------------
    vsego peresechenie                                                 277 us

**Predlozhenie "predzapisat komandnye bufery" otpadaet:** vsjo, chto ona ubiraet, stoit 7 us iz
277. Suhoj prohod i vydelenie deskriptorov ni pri chjom.

Raspredelenie ozhidanija (6000 vyzovov, K=1):

    <50 us     21
    <100     1752
    <200      267
    <400     3254   <- sjuda popadajut 3136 generacionnyh peresechenij
    <1000     193

Odna i ta zhe operacija na odnoj karte vozvrashchaetsja to za 70 us, to za 300. Znachit eto ne
pol, a peremennaja velichina.

### Chem zanjata karta v promezhutke - vlijaet, i izmereno

    static odin                          peresechenie 0,277 ms
    static + rezidentnye eksperty        peresechenie 0,234 ms   (-16%)

Bolee zanjataja karta otvechaet deshevle. Mezhdu dvumja peresechenijami vnimanija processor
schitaet smes okolo 300 us, i karta v eto vremja prostaivaet polnostju; RDNA2 pri prostoe gasit
graficheskoe jadro.

**No prostaja versija etoj gipotezy neverna:** BOLSHE podkachek delaet peresechenie DOROZHE, a ne
deshevle - period 3 dajot sloj 29,72 protiv 27,71 u zamorozhennogo. To est prisutstvie ekspertnogo
KONTEKSTA kartu greet, a sami PRODVIZHENIJA derutsja za rabochij potok. Dva effekta v raznye
storony, i ih vklad po otdelnosti ne razdeljon.

Plan pitanija Windows uzhe "Maksimalnaja proizvoditelnost" - rychaga tam net, GFXOFF upravljaetsja
drajverom.

### Chto ostajotsja, s cenami

    1. Ozhidanie zabora, ~240 us x 49 = 11,8 ms/tokjen. Perem
       ennaja, ne pol. Ne razobrano do konca.
    2. 272 us uzlov x 49 = 13,3 ms/tokjen. Sokratit graf s 29 uzlov do ~15 slijaniem QKV v odin
       matmul i ffn-hvosta - pobitovo identichno, nash kod, ot drajvera ne zavisit. Okolo 6,5 ms.
    3. Vnimanie na karte vtroe bystree processornogo (8,7 protiv 25,0 ms bez krugov) - znachit
       cena krugov, a ne vybor ustrojstva, opredeljaet vsjo v etoj chasti.

## Otzyv moej zhe kritiki: 2,99 mks na uzel bylo VERNO, i rezat uzly nechego

Ubral dva ggml_concat iz grafa sloja (tri vzvedjonnyh chtenija vmesto odnogo - vozmozhno tolko
posle togo, kak chtenie slozhili v komandnyj bufer). Izmereno:

    SPLIT_OUT=1   27 uzlov, 17 dispatchej   peresechenie 0,466 ms   17,3137 tok/s   48/48
    SPLIT_OUT=0   29 uzlov, 19 dispatchej   peresechenie 0,464 ms   17,3130 tok/s   48/48

**Nichego.** Ozhidal 29 us na peresechenie.

**Ja byl neprav, kogda objavil izmerennye 2,99 mks na uzel nedejstvitelnymi.** Srez dal 9,7, no
9,7 = (582 - 310)/28, i v eti 272 us vhodit NASTOJASHCHAJA rabota matmulov - okolo 190 us bajtov.
Vychest ih: (272 - 190)/28 = **2,9 mks na uzel**. Ishodnoe chislo verno; neverno bylo moe delenie -
ja pripisal peremeshchenie bajtov nakladnym rashodam. I versija agenta pro 11,6-20 us na dispatch
tozhe neverna.

Znachit i staryj vyvod "rezat uzly dajot maksimum 0,5%" veren. Podtverzhdjon dvazhdy: raschjotom i
zamerom.

**Sostav peresechenija v RABOCHEJ konfiguracii (s ekspertami, karta ne uspevaet ostyt):**

    postojannaja cena (graf iz odnogo uzla)   234 us   <- 11,5 ms/tokjen, 21%
    bajty matmulov                            190
    nakladnye 28 uzlov                         40
    ------------------------------------------------
                                              464 us

Izmenenie ostavleno: uzlov menshe, vreda net, i prichina sushchestvovanija etih dvuh concat
ischezla. No uskoreniem ne javljaetsja.

**Ostajotsja odna krupnaja statja: 234 us postojannoj ceny x 49 peresechenij.** Vsjo ostalnoe v
etoj chasti izmereno i malo. Urok metoda: prirashchenie sreza soderzhit i rabotu, i nakladnye -
delit ego na chislo uzlov mozhno tolko posle vychitanija bajtov.

## Ozhidanie otveta karty: pol 310 mks plus dobavka ot prostoja. Obe versii verny napolovinu

Instrument: FENCE_SPLIT s korreljaciej ozhidanija protiv PROSTOJA pered otpravkoj, tolko
generacija (vsjo, chto zhdjot bolshe 2 ms, otbrosheno - eto prefill).

**Pervye dve popytki byli negodny i ja pochti sdelal iz nih vyvod.** Vedra byli grubye i prefill
smeshan s generaciej: v odnoj vyborke bylo 46 i 281 vyzov protiv 2304 nastojashchih peresechenij, a
poslednee vedro s 3669 prefill-vyzovami davalo srednee 5,3 ms. Vyvod "zavisimosti ot prostoja net"
na etih chislah delat bylo nelzja.

Chistyj zamer, rabochaja konfiguracija (statika + eksperty na karte):

    prostoj pered otpravkoj   vyzovov   zhdjom
    menshe 100 mks             1949     310,3 mks
    do 300 mks                 2410     425,4
    do 600 mks                  511     485,5

**Est POL v 310 mks, kotoryj progrevom ne ubrat, i sverhu DOBAVKA 115-175 mks, zavisjashchaja ot
togo, skolko karta prostojala.**

Skhodimost: 310 pola + 190 bajtov + 40 uzlov = 540 protiv izmerennyh 557.

    pol 310 mks x 49 peresechenij       = 15,2 ms/tokjen   tolko sokrashcheniem chisla peresechenij
    dobavka ot prostoja, v srednem ~57  = 2,8 ms/tokjen    +5,5%, dostizhimo uderzhaniem karty

Vtoraja chast v nashej vlasti: mezhdu peresechenijami processor schitaet smes, karta stoit, i chem
dolshe stoit - tem dorozhe otvechaet. Podkachka ejo greet, no zanimaet rabochij potok i potomu v
summe vredit (period 3 dajot sloj 29,72 protiv 27,71 u zamorozhennogo). Trivialnyj dispatch dlja
progreva stoit pochti nichego - eto i nado sdelat.

## Progrev karty: oprovergnut. Korreljacija byla ne prichinoj

`ggml_backend_vk_keepwarm` - odna 256-bajtnaja kopija bez ozhidanija, srazu posle chtenija
rezultata sloja, to est v tot moment, kogda karta ostajotsja bez raboty na 1,5 ms.

                       tok/s    peresechenie   zabor
    progrev vkljuchjon 16,0363    0,524 ms     0,031
    progrev vykljuchen 16,1471    0,511        0,002

**Huzhe na 0,7%.** Predskazyval +14%. Cena samogo ukola vidna v stroke zabor: 0,002 -> 0,031.

**Pochemu korreljacija obmanula, dva otvechenija:**

1. Pribor stal merit ne to. Promezhutok schitalsja ot zaversheniia PREDYDUSHCHEGO zabora, a s
   progrevom predydushchim zaborom stanovitsja sam ukol. Gistogramma eto pokazala: v bystrom vedre
   1397 vyzovov vmesto 2661.
2. I glavnoe: ozhidanie v bystrom vedre S progrevom 332,3 us protiv 311,9 BEZ nego. To est dazhe
   tam, gde karta zavedomo ne spala, luchshe ne stalo.

Znachit svjaz "dolshe prostoj -> dorozhe otvet" byla **korreljaciej, a ne prichinoj**. Chto-to
tretje delaet i promezhutok dlinnym, i otvet dorogim - veroatnee vsego eto sloi, gde processornoj
polovine dostalos bolshe raboty.

**Urok metoda, i on obshchij.** Korreljacija mezhdu dvumja izmerennymi velichinami ne nazyvaet
prichinu, dazhe kogda mehanizm zvuchit ubeditelno (RDNA2 gasit jadro v prostoe - eto pravda, no ne
otvet). Proverjaetsja tolko vmeshatelstvom. I vmeshatelstvo nado stroit tak, chtoby ono ne
portilo pribor: zdes ukol sdvinul tu samuju velichinu, po kotoroj stroilas gipoteza.

Kod ostavlen za pereklychatelem MEMEX_KEEPWARM=0 po umolchaniju - on ne vredit, poka vykljuchen, i
sluzhit gotovym plechom, esli pol 310 us kogda-nibud okazhetsja svjazan s pitaniem.

## Revju koda: tri defekta, i odin b'jot po moim zhe zameram

### Kriticheskij: progrevochnyj ukol byl nevernym ispolzovaniem Vulkan

Ukol bral komandnyj bufer iz `transfer_cmd_pool` i nikogda ego ne zhdal, a
`ggml_vk_graph_cleanup` v konce KAZHDOGO `graph_compute` bezuslovno delaet `resetCommandPool` na
tom zhe pule. Sbros pula, poka ego bufer eshchjo ispolnjaetsja, - narushenie specifikacii. Vremena
perekryvajutsja (ukol 310-486 us protiv sloja 450-600), to est eto ne gipoteticheskaja gonka.

Proverka "192 iz 192" etogo ne pojmala by nikogda: otkaz vygljadit kak sboj drajvera pod
nagruzkoj. **Udaljon celikom**, a ne ostavlen za flagom - "oprovergnuto I nebezopasno" ne stoit
derzhat v dereve.

### Vazhnyj, i on pro moi chisla: schjotchiki priborov byli obshchimi na dva konteksta

`FENCE_SPLIT`, `HOST_SPLIT` i `GAP_WAIT` derzhali sostojanie v funkcionalnyh statikah - odin nabor
na process, pri DVUH kontekstah Vulkan (vnimanie i eksperty), rabotajushchih na RAZNYH potokah.
Eto i gonka, i - huzhe - smeshivanie 29-uzlovogo peresechenija vnimanija s 3-uzlovym ekspertnym
dispatchem v odno srednee.

**Znachit vse chisla GAP_WAIT, snjatye pri oboih bekendah, byli smesju dvuh raznyh velichin.** Ja
eto podozreval i pytalsja razvesti, zapustiv bez ekspertov, no tam vyborki okazalis po 46 i 281
vyzov. Teper ponjatno pochemu.

Ispravleno: schjotchiki perenesены v `ggml_backend_vk_context`, u kazhdogo konteksta svoj
`instr_id`, kotoryj pechataetsja. Chisla nado peresnjat.

**Chto iz vyvodov ustojalo:** progrev oprovergnut VMESHATELSTVOM (-0,7%), a ne korreljaciej, i
etot vyvod ne zavisit ot zagrjaznjonnyh vedjor. Pol v 310 us tozhe izmeren srezom grafa, a ne
etim priborom.

### Vazhnyj: tri plecha ne pechatali svojo sostojanie

`MEMEX_SPLIT_OUT`, `MEMEX_FOLD_READBACK` i `MEMEX_NO_ROPE` v `gpu_static.cpp` chitalis iz
okruzhenija i menjali formu grafa, no nichego ne pechatali - prjamoe narushenie pravila 68 v moem
zhe kode. U `SPLIT_OUT` podtverzhdenie sluchajno bylo (chislo uzlov 27 protiv 29), a **opyt s ROPE
byl plechom bez podtverzhdenija, i ego rezultat nedejstvitelen** - peremenaja mogla ne dojti do
processa, i togda 25,92 protiv 24,72 eto chistyj shum, chto s nim i sovpadaet.

Ispravleno: vse tri pechatajut sostojanie.

## Gemma 4 generiruet. 5,94 tok/s, i eto paritet s etalonom

    nash put         5,94 tok/s
    etalon forka     6,04
    bajtovyj potolok 7,7   (3,241 GB/tokjen pri 24,8 GB/s)

**Chto meshalo, i eto okazalos ne to, chto napisano v zaprete.** Zapret stojal na vsej vetke
`--gen`, no privjazany k geometrii byli tolko NEOBJAZATELNYE moduli - zonnyj kesh, rezidentnyj
nabor, polovina na karte - i kazhdyj iz nih otkazyvaet sam, po imeni, vyshe. Chistaja processornaja
generacija ni k chemu ne privjazana: `build_gemma4_step` proveren (vse zondy 0,0000%), kesh davno
po-slojnyj.

Meshali chetyre zhjostkih vyzova `build_step` v samom cikle - mimo dispetchera `build_one`, kotoryj
vse tri arhitektury i tak umeet. Zamena na dispetcher po arhitekture v dvuh mestah iz chetyrjoh
(prefill i obychnyj dekod; rasshcheplennyj i zonnyj nuzhny modulam, kotorye dlja gemma4 zapreshcheny).

### Nash processornyj put na Gemma NE bystree etalona, i eto ob'jasnimo

    Qwen 30B:  nash 11,98 protiv etalona 9,04  -> +32%
    Gemma 26B: nash  5,94 protiv etalona 6,04  -> paritet

U Qwen 53% trafika - eksperty, i vsja nasha rabota nad processornoj polovinoj byla imenno tam.
U Gemma eksperty ne glavnoe: vnimanie 1125 MiB, plotnye FFN 543, golova 748. Nashi optimizacii
lezhat v drugoj chasti tokjena.

### Zato karta dolzhna dat Gemma BOLSHE, chem Qwen

Dolja statiki v trafike u Gemma **67%** protiv 47% u mx1, a statika - eto to, chto perenositsja na
kartu s otdachej 1,00. Perenos snimet s processornoj shiny dve treti trafika vmesto poloviny.

`--gpu-static-layers` dlja gemma4 poka ZAPRESHCHJON po imeni, namerenno: GpuStatic stroit odin graf
sloja i povtorjaet ego na vseh, a u Gemma iz tridcati sloev dvadcat pjat so skolzjashchim oknom,
golovy 16/2 po 512 cheredujutsja s 16/8 po 256, masshtab vnimanija edinica vmesto 1/sqrt(d).
Molchalivyj nevernyj otvet zdes huzhe otkaza. Sledujushchaja rabota - razvesti graf statiki po slojam.

## Perenos statiki na Gemma: geometrija sdelana, no delo ne v nej

Sdelano i sobrano:

    GpuStaticGeom i cfg_.at(il)   geometrija na sloj, otkat na skaljary
    KV-kesh na karte              vydeljaetsja po sloju, a ne odnim razmerom
    povorot                       osnovanie i tip iz sloja
    masshtab softmax              iz sloja: u gemma4 edinica, a ne 1/sqrt(hd)
    maska                         otpravljaetsja pri SMENE, a ne raz za shag (u gemma4 ih dve)
    rope_freqs                    desjatym slotom, NEOBJAZATELNYM

Otkat na skaljary sdelan tak, chto put qwen3moe ne izmenilsja ni na bajt: vektor geometrii pust -
rabotajut prezhnie skaljary.

**No zapret ne snjat, i prichina glubzhe, chem geometrija.** U Gemma DRUGOJ BLOK, a ne tolko drugie
razmery:

  - posle vnimanija stoit `post_attn_norm`, kotorogo u qwen3moe net;
  - marshrutizator chitaet VYHOD VNIMANIJA cherez otdelnyj ves `ffn_gate_inp_s`, a ne vyhod
    `ffn_norm`;
  - dense-polovina i routed-polovina slozheny cherez `ggml_fused_rms_rms_add` s dvumja
    post-normami.

Graf statiki postroen pod blok qwen3moe: vnimanie -> wo -> ostatok -> ffn_norm -> marshrutizator.
Znachit perenos - eto VTOROJ POSTROITEL GRAFA, povtorjajushchij chast build_gemma4_step, a ne
podstanovka parametrov. Sdelannaja geometrija dlja nego neobhodima, no nedostatochna.

Polugotovyj postroitel grafa - rovno to, chto dajot molchalivyj nevernyj otvet, poetomu eto
otdelnyj zahod so svoej proverkoj protiv etalona (--decode-check sveryaet kazhdyj shag).

## Gemma na karte: put sobran i rabotaet ot nachala do konca, no otvet NEVERNYJ

Sdelano i sobrano:

    poslojnaja geometrija            GpuStaticGeom + cfg_.at(il), otkat na skaljary
    KV-kesh po sloju                 golovy 16/2 po 512 i 16/8 po 256 v odnoj modeli
    vtoroj postroitel grafa          blok gemma4: norma mezhdu wo i ostatkom, marshrutizator ot
                                     vyhoda vnimanija cherez svoj ves, vtoraja pre-norma
    chetyre vyhoda vmesto trjoh      predel vzvedjonnyh chtenij, krug po-prezhnemu odin
    slot wv neobjazatelnyj           pjat sloev Gemma bez attn_v: V iz SYROJ proekcii K
    rope_freqs desjatym slotom       v etom fajle ih net, drugie sborki nesut
    golova ne vygruzhaetsja           748 MiB ne tratim: ejo postroitel golovu na karte ne zovjot
    on_card = true                   kesh prinadlezhit karte, host zapisi ne perenaceljivaet

Karta berjot vse 30 sloev, 1174,7 MiB, progon prohodit do konca s kodom 0.

**No otvet nevernyj:**

    bez karty:  L2 7,58 / 6,08 / 8,79 / 8,74 / 13,36 / 5,27   5 iz 6 tokenov sovpali
    s kartoj:   L2 16,55 / 35,34 / 18,39 / 77,60 / 28,44 / 16,05   1 iz 6

### Chetyre defekta po doroge, i vse molchalivye

Kazhdyj iz nih ne padal i ne zhalovalsja, poka ne dohodilo do sledujushchego:

  1. `build_graphs` stroil grafy GOLOVY po nulevomu tenzoru, kogda golova propushchena -
     narushenie dostupa srazu posle pechati kuch, bez soobshchenija.
  2. Kontekst vesov byl rasschitan na 11 tenzorov na sloj, a stalo do 16 - 'needed 74464,
     available 74400'. ggml_new_object vozvrashchaet nol posredi razmeshchenija, a padaet potom
     i v drugom meste.
  3. `proto` v GpuStatic::layer objavljal razmer 2*n_embd + n_expert, a chitalos 3*n_embd +
     n_expert - vid vyhodil za predely istochnika.
  4. `--decode-check` zval postroitel BEZ karty, tak chto sverka sravnivala put bez karty sam s
     soboj i davala sovpadenie do chetvjortogo znaka. **Rezultat, kotoryj vygljadit kak uspeh i
     ne javljaetsja im** - samyj opasnyj iz chetyrjoh.

### Chto izvestno o samoj oshibke

Zamena ggml_rope_multi na ggml_rope_ext (proverennyj postroitel zovjot imenno ext) ne izmenila
chisla NI NA ZNAK pri svezhem binarnike. Pri nastojashchem izmenenii koda eto nevozmozhno, esli
vetka ne berjotsja - znachit libo cfg_.gemma_block ne dohodit do modulja, libo rasxozhdenie
opredeljaetsja chem-to drugim i rope ego ne kasaetsja.

Sledujushchij shag - zondy VNUTRI grafa karty, a ne dogadki: sravnit vyhod sloja 0 na karte s ego
zhe vyhodom na processore. Instrument dlja etogo est - `--gpu-static-check` u ekspertov delaet
rovno eto dlja svoej poloviny.

### Chto proverено i isklyucheno v poiske oshibki gemma4 na karte

    vetka berjotsja                 STATIC_TRUNC pechataet: gemma_block 1, geom 30, rope ext
    rope ne pri chjom               zamena multi -> ext ne izmenila chisla; multi s nulevymi
                                    sekcijami i tak svoditsja k obychnomu
    kesh promрta uezzhaet na kartu  upload_kv sveryaet razmery POSLOJNO i upal by gromko
    sloi 0 i 1 na PREFILLE tochny   L2 0,0000% - no eto processornyj put, karta tam ne rabotaet

**Glavnoe ogranichenie diagnostiki, i ono i est sledujushchij shag.** Zondy snimajutsja na
PREFILLE, a karta rabotaet tolko pri odnom tokene, to est v DEKODE. Poetomu vsjo, chto sejchas
pokazyvajut zondy, - eto processornyj put. Chtoby uvidet vyhod KARTY, nuzhny zondy na dekodnom
grafe: sravnit attn_out, ffn_norm_1 i ffn_norm_2 sloja 0 na karte s temi zhe na processore, pri
odnom i tom zhe vhode.

Zondy s pravilnymi imenami v vetku karty uzhe dobavleny - ostalos zastavit poshagovuju sverku ih
snimat.

Rashozhdenie nachinaetsja s PERVOGO zhe shaga dekoda (L2 16,5% na pozicii 4), to est ne
nakaplivaetsja, a est srazu. Eto suzhaet poisk: iskat nado v tom, chto otlichaet dekod ot
prefilla, a ne v drejfe.

### Zondy na DEKODNOM grafe: oshibka nazvana tochno

Snjatie zondov na dekode (a ne na prefille) - eto i byl nedostajushchij instrument. Sverka ih
umeet, nado bylo tolko peredat kartu v Generator.

    najdeno i ispravleno: NORMIROVKA V. U gemma4 V normiruetsja po golove BEZ vesa na kazhdom
    sloe - tenzora v_norm v fajle net, norma bezvesovaja i ona vsjo ravno tam. U qwen3moe ejo net
    vovse, poetomu v grafe karty ejo i ne bylo. Karta pisala v kesh nenormirovannoe V.

    bylo:  1 tokjen iz 6, L2 16-78%
    stalo: 3 tokjena iz 6, L2 1,4-11%

**Chto ostajotsja, i ono nazvano chislom:**

                    nash      etalon
    attn_out-0    rms 7,49  /  6,97    L2  146%
    ffn_norm_1-0  rms 11,22 /  1,18    L2  953%
    ffn_norm_2-0  rms 12,12 /  0,31    L2 3963%

Velichina attn_out primerno vernaja, a normirovki dajut NA PORJADOK bolshe vhoda. Normirovka po
srednekvadratichnomu pri odinakovom vhode dajot na vyhode velichinu porjadka samogo vesa - znachit
ves na karte primerno vdesjatero bolshe nastojashchego (11,22 protiv 1,18 - otnoshenie 9,5).

**To est v slot popal ne tot tenzor.** Oba puti zovut odnu i tu zhe operaciju
(`ggml_fused_rms_norm`) s odnim eps, tak chto raznica tolko v vesah.

Sledujushchij shag ne dogadka, a instrument: u modulja est kljuch `verify` - "prochitat kazhdyj
vygruzhennyj bajt obratno i sravnit s tenzorom modeli, iz kotorogo on vzjat". Imenno on i nazovjot,
kakoj slot razjehalsja. Sloty 9..12 dobavleny mnoju segodnja, i imenno oni pod podozreniem.

### Vesa na karte pobajtovo verny - znachit delo v VYCHISLENII

Dopisana proverka `verify_layers`: kazhdyj vygruzhennyj tenzor sloja chitaetsja obratno i
sravnivaetsja s modelju, slot za slotom. Vkljuchaetsja tem zhe `--gpu-static-verify`.

    bajty vesov sloev v videopamjati sovpadajut s modelju: 30 sloev x 13 slotov

**Gipoteza "v slot popal ne tot tenzor" OPROVERGNUTA.** Ona byla postroena na arifmetike
(11,22 protiv 1,18 - otnoshenie 9,5) i vygljadela ubeditelno; proverka instrumentom ejo zakryla.

**Chto iz etogo sleduet, i eto sil'noe suzhenie.** Normirovka po srednekvadratichnomu UBIRAET
masshtab vhoda: na vyhode vsegda velichina porjadka samogo vesa, kakov by ni byl vhod. Vesa verny,
operacija ta zhe (`ggml_fused_rms_norm`), eps tot zhe. Vyhod bolshe etalonnogo v 9,5 raza.

Tak mozhet byt tolko esli JADRO schitaet ne to, chto my dumaem - naprimer, normiruet po drugoj osi
ili inache vedjot sebja na forme Gemma. U nejo shirina 2816 protiv 2048 u qwen3moe, i eto pervoe,
chto stoit proverit: postavit odin uzel fused_rms_norm na [2816,1] na kartu i na processor s odnimi
i temi zhe vhodom i vesom, i sravnit. Esli razojdutsja - eto bekend, a ne nash graf.

Instrument dlja etogo uzhe est: MEMEX_STATIC_TRUNC=1 stroit graf iz ODNOGO uzla - imenno normy
vhoda - i sravnit ego vyhod s processornym mozhno tem zhe zondom.

## Kvin: regressija maski zakryta, 192/192

Pravka `step_mask_src_ = nullptr` na VTOROM meste sbrosa (gpu_static.cpp ~1297, ne tolko 374)
proverena progonom `fold_ab.ps1` 09/01 14:07:

    raund 1 fold  podkachek/tok 1,67  popadanij 71,3%  tok/s 18,08  match 192/192  bajty 0/48
    raund 1 sep   podkachek/tok 1,68  popadanij 71,3%  tok/s 13,15  match 192/192  bajty 0/48

Do pravki oba plecha davali `SOVPALO 7 iz 192` i cifry vybrasyvalis. Teper 192/192 na oboih.
Skorost 18,08 protiv 18,55 v proshluju sessiju - vnutri mezhsessionnogo razbrosa (11,6%),
i plecho `sep` v etom raunde prosело silnee obychnogo (zapis 0,051 vmesto 0,009 ms), tak chto
sravnivat mezhdu sessijami zdes nechego. Vazhno drugoe: **korrektnost vosstanovlena, i fold
po-prezhnemu vyigryvaet u sep s bolshim zapasom.**

Novoe chislo iz etogo zhe raunda: chtenie podkachki 0,294 ms = **8,52 GB/s** (bylo 7,37).
Submit+zabor 0,918 - tretje nezavisimoe podtverzhdenie okolo 0,92-0,95, protiv 0,10 iz
oshibochnogo razlozhenija.

## ReBAR: vopros zakryt NASHIMI ZHE logami, ehat nikuda ne nado

Verhnij patch iz obzora (llama.cpp #21590 - "buffer allocated host-visible but writes still go
through staging") na etoj mashine ne daet nichego, i eto vidno bez edinoj stroki koda. Nash
zapusk uzhe pechataet raskladku po kucham:

    kucha 0  DEVICE_LOCAL                        3824 MiB   bjudzhet 2975 MiB
    kucha 1  host                               16318 MiB
    kucha 2  DEVICE_LOCAL HOST_VISIBLE HOST_COHERENT   256 MiB   bjudzhet 199 MiB   zanjato 0,00

    vesa ekspertov, sloi 0..23    688,50 MiB -> kucha 0, zapis hosta = staging+fence
    vesa ekspertov, sloi 24..47   688,50 MiB -> kucha 0, zapis hosta = staging+fence
    vhod i spiski identifikatorov   0,01 MiB -> kucha 2 (BAR), zapis hosta = memcpy

**BAR - 256 MiB, ne resizable.** Bufer vesov v 688 MiB v nego ne vlezaet po opredeleniju, poetomu
ego zapis i idet cherez staging. Fork ik_llama uzhe beret memcpy-vetku, kogda naznachenie
host-visible (`ggml_vk_buffer_write_2d`, ggml-vulkan.cpp:4887) - upstreamnaja zhaloba k nam ne
otnositsja voobshche.

**Kucha 2 zanjata na 0,00 MiB - i eto NE upushchenie, a nashe zhe reshenie.** gpu_experts.cpp:385:

    ni odin bufer ne dolzhen byt nastolko mal, chtoby pomestitsja v kuchu BAR - tot, chto
    pomestitsja, budet tuda polozhen, i kak tolko eta kucha zanjata, drajver podkladyvaet pod
    ostalnoe sistemnuju pamjat na sorokovoj dole polosy, prodolzhaja nazyvat ejo device-local.

`kBarHeapCeiling = 256 MiB` stoit nizhnim porogom razmera buferа v oboih moduljah (gpu_experts.cpp
i gpu_static.cpp), i gruppy sloev narezajutsja tak, chtoby **samaja malenkaja** gruppa ego
prevyshala. 131/40 = 3,3 GB/s - eto ровно PCIe 3.0 x4, to est drajver AMD pri perepolnenii BAR
otdaet sistemnuju pamjat vmesto otkaza, i `find_properties` etogo ne vidit.

**Ideja "polozhit rezidentov v pustujushchie 256 MiB" - zakryta.** Zapisana zdes imenno potomu, chto
vygljadit besplatnoj i budet vozvrashchatsja: v logе vidno pustuju kuchu i ne vidno pochemu.

**Chto pri etom pravilo NE zapreshchaet, i eto edinstvennaja zhivaja shchel.** Opasnost sostoit v
tom, chto **posledujushchie** vydelenija sjezzhajut v sistemnuju pamjat. Bufer, vydelennyj POSLE
togo, kak vsjo ostalnoe uzhe leglo v kuchu 0, nikogo za soboj utashchit ne mozhet - ronjat nechego.
Seichas porog primenjaetsja odinakovo na vseh sajtah vydelenija i etogo razlichija ne delaet.

Eto i est edinstvennyj put k "posadochnoj ploshchadke podkachki v BAR": arena na 48-96 slotov
(120-241 MB), vydelennaja **poslednej**, v kotoruju podkachka pishetsja memcpy bez submit i bez
zabora (te samye 0,918 ms iz 1,21). Poka eto ne plan, a gipoteza s dvumja proverkami pered nej:

  1. mikrozamer memcpy host->BAR: skolko realno GB/s. Zapis v WC/uncached pamjat asimmetrichna;
     nizhe ~2 GB/s hod umiraet na meste (2,51 MB / 2 GB/s = 1,26 ms, huzhe nyneshnih 1,21).
  2. proverit, chto posle vydelenija areny nichego bolshe ne vydeljaetsja - inache pravilo 385
     srabatyvaet imenno tak, kak ono i opisano, i my poluchim ves rezidentnyj nabor v sistemnoj
     pamjati, prodolzhaja chitat "device-local" v logе.

## Chto literatura ZAKRYLA (ne otkryla)

Tri linii proverena i zakryta chislami, chtoby ih ne otkryvali zanovo:

  - **Besposteryannoe entropijnoe kodirovanie vesov na shine.** arXiv:2606.15789 sam merjaet:
    syroj INT4 dajot 6-10x zapasa nad entropijnym predelom, a **gruppovye formaty (AWQ, SmoothQuant)
    - tolko 1,1-1,3x**. GGUF k-kvanty - gruppovoj format s poblochnymi masshtabami, to est my v
    etoj zhe kategorii. Realnyj potolok ~10-30%, a ne 6-10x. Vulkan-dekoder ANS ne okupitsja.
  - **Sub-ekspertnaja granularnost (FloE i rodstvennye).** Nasha sobstvennaja mera: razrezhennost
    po blokam 32 - 0,003%, zhadnyj orakul pri 5% oshibki osvobozhdaet 0,03% bajtov eksperta,
    Zhakkar masok mezhdu tokenami 0,1. FloE merjal Mixtral (8 ekspertov po 14336); u nas 128 po
    768 - melkozernistyj MoE uzhe potratil tu razrezhennost, kotoruju FloE sobiraet.
  - **Processornye jadra KTransformers i fastllm.** Programmnoj predvyborki v putjah bez AVX-512
    net ni odnoj, netemporalnyh zagruzok net, bolshih stranic net, perepakovki net. Format fastllm
    - 4,5 bita protiv nashih 4,25, to est **na 6% bolshe bajtov na token**.

## Gemma na karte: "oshibka vychislenija" okazalas artefaktom ZONDA

Progon `bench/gemma_card_probe.ps1` - odin i tot zhe spisok zondov na processore i na karte,
odin i tot zhe binarnik, odna sessija, `--ref-fa --probe all --decode-check 6`.

**Glavnoe chislo, i ono protivopolozhno tomu, chto zdes stojalo:**

    processornoe plecho: 5 iz 6 shagov tot zhe token, hudshij L2 7,8179%
    plecho na karte:     5 iz 6 shagov tot zhe token, hudshij L2 6,9117%

Karta BLIZHE k etalonu, chem processor. Nikakoj "odnoj lokalizovannoj oshibki vychislenija" net.

**Chto zhe togda pokazyvali zondy.** V logе karty stojalo:

    ffn_norm_1-28  rms 5,30764 / 1,48585   L2  369%
    ffn_norm_2-28  rms 5,95651 / 0,13549   L2 4394%
    ffn_norm_1-29  rms 5,30764 / 0,95559   L2  567%
    ffn_norm_2-29  rms 5,95651 / 0,18838   L2 3160%

Odno i to zhe znachenie na DVUH raznyh slojah. Vygruzka po vsem tridcati slojam pokazala to zhe:
na kazhdom shage dekoda VSE sloi soobshchajut odno chislo, i vsego chisel shest - po odnomu na
shag. Norma, ne zavisjashchaja ot vhoda, nichego ne schitaet.

**Prichina.** V vetke karty zondy - eto `ggml_view_1d` v `card_lay`, a `card_lay` est vyhod uzla
`ggml_map_custom3`, ch'ju pamjat gallocr pereispolzuet, kak tolko potrebiteli otrabotali. Tridcat
sloev delят odnu oblast, a zond chitaetsja POSLE grafa - znachit vidit poslednij sloj.
`ggml_set_output` na VIDE ne zashchishchaet pamjat roditelja.

Nastojashchij potok dannyh etim ne zatronut: `do_layer` kopiruet `card_lay` v `dst->data` srazu
zhe, vnutri svoego zhe vyzova. Slomany byli tolko zondy.

**Pravka:** `ggml_cont` vokrug kazhdogo iz trjoh vidov. U kopii svojo hranilishche, i
`ggml_set_output` zakrepljaet imenno te bajty, kotorye zond potom prochitaet. Tri lishnih uzla na
sloj, i tolko kogda zondy zaprosheny.

**Chto iz etogo sleduet dlja STATE.** Vsjo, chto vyshe napisano pro `attn_out-0 L2 146%`,
`ffn_norm_1-0 rms 11,22 / 1,18` i `ffn_norm_2-0 rms 12,12 / 0,31`, izmerjalo etot zhe artefakt.
Gipoteza "jadro fused_rms_norm inache vedjot sebja na shirine 2816" postroena na teh chislah i
**snimaetsja bez proverki** - proverjat nechego. Instrument `MEMEX_STATIC_TRUNC` dlja nejo ne
nuzhen.

### Pravilo 85: zond, sdelannyj vidom, izmerjaet ne to, chto nazyvaet

Zond - eto tozhe kanal (pravilo 83), i u nego est svojo "NE IZMERENO", kotoroe on ne umel
vyrazit. Vid v pereispolzuemyj bufer vsegda vernjot KAKIE-TO chisla, pravdopodobnye po porjadku
velichiny, i nikogda ne skazhet "eti bajty uzhe ne moi".

Priznak, po kotoromu eto lovitsja za sekundu i kotoryj my propustili: **odno i to zhe znachenie na
raznyh slojah**. Ljubaja velichina, zavisjashchaja ot vhoda, objazana razlichatsja mezhdu slojami;
sovpadenie do pjatogo znaka - eto ne "pochti verno", a "eto ne to chislo".

Formulirovka: **zond objazan imet sobstvennoe hranilishche.** Esli velichina, kotoruju hochetsja
proverit, zhivjot vidom v chuzhoj bufer - kopiruj ejo, a ne nazyvaj vidom. I pered tem kak
stroit gipotezu o vychislenii, proverjaj, razlichajutsja li znachenija zonda po slojam.

## HOBBIT: predskazanie na sloj vperjod RABOTAET, no ne okupaetsja

Dve mery, obe offlajn, obe s predskazanijami zapisannymi do progona.

**Tochnost - vysokaja, i eto ne povtorenie istorii s obuchennym predskazatelem.**

    d=1  perekrytie 83,94%   cos(X_L, X_L+1) 0,9156
    d=2             77,49%                   0,8471
    d=3             72,08%                   0,7862

    to zhe pri toj zhe emkosti:  chastota 30,18%,  preduydushchij token 44,59%
    kontrol na peremeshivanii (chuzhoj token v tot zhe marshrutizator): 19,35%

Obuchennyj predskazatel umer imenno na sravnenii s chastotoj: 80,2% protiv 45,9% offlajn, a
onlajn proigral chastote v 89 tochkah iz 97. Zdes pereves nad chastotoj **54 punkta**. Kanal
nastojashchij. Instrument proveren do togo, kak emu poverili: d=0 (marshrutizator sloja L na
ego zhe vhode) vosproizvodit zapisannyj vybor na 99,99%.

**Ekonomika - otricatelnaja, i ne na granice.**

    C=29, LFU, bez predvyborki   71,70%
    C=29, LFU, s predvyborkoj    82,03%   pri 47,66 podkachkah na token
    ------------------------------------------------------------------
    +10,33 punkta popadanij za 47,66 podkachek = 0,26 punkta na podkachku

Porog okupaemosti 0,97 punkta na podkachku pri POLNOSTJU sprjatannom zabore i 3,55 bez nego.
My korotki v **3,7 raza v samom luchshem sluchae, kotoryj dvizhok voobshche mozhet predlozhit**.
Po vremeni: **-10,40 ms na token** dazhe esli zabor ischeznet polnostju, i -48,16 esli net.

Predvyborka pri etom rabotaet pochti ideal'no. Odna predvyborka na sloj mozhet vernut ne bolshe
1 slota iz 8 = 12,5 punkta, i ona vernula 10,33 - to est **82,6% svoego potolka**, chto sovpadaet
s tochnostju 83,94%. Ne mehanizm ploh, a potolok nizok.

**Nozhnicy na cap>1 - ne tam, gde my dumali.** Cap 2 i 3 huzhe cap 1 **po samomu popadaniju**
(+9,09 i +7,81 protiv +10,33), potomu chto ushcherb ot vytesnenija obgonjaet pribavku. Ogranichenie
po DMA (odna peredacha 0,64 ms v sloj 1,15 ms), kotoroe ja nazval svjazyvajushchim, ne uspevaet
srabotat - politika zapreshchaet ranshe.

**Globalnyj nabor protiv poslojnogo** (tot zhe polnyj chislo slotov): +0,24 punkta pri C=29,
+0,42 pri C=12, znak odinakov vo vseh shesti jachejkah. Eto +0,1% tokena protiv poroga shuma 4,2%.
Zakryto: dva sistemy v literature schitajut etot vybor vazhnym, u nas on ne stoit nichego.

### Popravka k vyvodu agenta: "prosto podnjat emkost" na etoj karte NEVOZMOZHNO

Agent nazval alternativu: C=40 s obychnym LFU dajot 81,03% pri 9,08 podkachkah - pochti tot zhe
vyigrysh v pjat raz deshevle. Eto verno kak arifmetika i neprimenimo kak sovet:

    kucha 0: bjudzhet 2975 MiB, zanjato 2832,58 - svobodno ~143 MiB
    C 12 -> 40 eto 48 sloev x 28 ekspertov x 2,51 MB = 3,37 GB

Mesta net i blizko. Tak chto predvyborka zakryta **svoej sobstvennoj arifmetikoj** (-10,40 ms),
a ne sushchestvovaniem bolee deshjovoj zameny; zamena zhe - eto zapros na druguju kartu, a ne
reshenie. Zapisyvaetsja imenno tak, chtoby potom nikto ne prochital "nado bylo prosto podnjat C".

### OTKRYTOE RASHOZHDENIE: simuljator i dvizhok rashodjatsja na 25 punktov

Dvizhok pri emkosti 12 dajot **71,30%** (`PROMO_AB ... period 32 capacity 12 ... hits 71,2958`).
Dva nezavisimyh offlajn-proigryvanija - svezhaja transkripcija `resident_set.cpp` i nash sobstvennyj
`memex/vram_residency.py` - dajut pri toj zhe emkosti **46,55%**, i shodjatsja mezhdu soboj s
tochnostju 0,04 punkta. 71,7% u nih poluchaetsja tolko pri C=29.

Opredelenie ne vinovato: `resident_set.cpp:174` schitaet `is_resident`, ne `is_claimed`, tak chto
pending v popadanija ne popadaet.

Ostajotsja nagruzka, i zdes samoe verojatnoe objasnenie: dvizhok merit popadanija **na 192 tokenah
generacii posle progreva 512-tokennym prefillom na tom zhe tekste**, a proigryvanie idjot po
raznorodnym trassam s holodnogo starta. Prodolzhenie odnogo teksta pereispolzuet uzkij nabor
ekspertov; raznye dokumenty - net.

Pochemu eto nado zakryt, a ne ostavit snoskoj: **cherez hit rate ocenivaetsja vsjo v etom proekte**
(1 punkt = 0,368 ms). Poka rashozhdenie ne nazvano, ljuboj offlajn vyvod o politike stoit na
neproverennom perevode. Verdikt po predvyborke ot etogo ne zavisit - on otricatelen i pri C=12,
i pri C=29 - no sledujushchij takoj vyvod mozhet zaviset.

Proverka deshjovaja: proigrat tot zhe prompt bench-a (512 tokenov progreva, potom 192) i sverit
s 71,30%.

## Asinhronnaja podkachka: rabotaet, i vyigrysh menshe, chem pokazalos snachala

`promo_async_ab.ps1`, odin binarnik, odna sessija, pereklyuchatel `MEMEX_PROMO_ASYNC`, plecho
nazyvaet sebja strokoj `PROMO_ASYNC 0|1` i skript eto sverjaet. Raund 1:

    async  podkachek/tok 1,67  popadanij 71,3%  promo_ms/tok 1,41  CPU/tok 14,82  sloj 22,94
           tok/s 18,97  match 192/192  bajty 0/48
           podkachka 0,841 ms = chtenie 0,288 + zapis 0,008 + submit/zabor 0,000 + OSTATOK 0,545
           zabor: reap 0,015 ms; blokirujushchih 5, pozdnih oprosov 527

    sync   podkachek/tok 1,65  popadanij 71,3%  promo_ms/tok 1,93  CPU/tok 15,78  sloj 23,83
           tok/s 18,13  match 192/192  bajty 0/48
           podkachka 1,170 ms = chtenie 0,280 + zapis 0,007 + submit/zabor 0,878 + ostatok 0,005
           zabor: reap 0,000; blokirujushchih 0, pozdnih oprosov 0

**Chto pravda.** Podkachka 1,170 -> 0,841 ms, tok/s 18,13 -> 18,97 (+4,6%), schjot verny na oboih
plechah. 527 pozdnih oprosov protiv 0 - otkladyvat bylo chto, mehanizm dejstvitelno rabotaet.

**Chto NE pravda, i eto moja zhe oshibka pribora.** Pervoe chtenie bylo "submit/zabor 0,000, reap
0,015 - ozhidanie ischezlo". Net: OSTATOK vyros s 0,005 do 0,545. Ozhidanie chastichno PEREEHALO -
`GpuExperts::batch_begin` zval zabor prjamo u bekenda, mimo schjotchika. Arifmetika shoditsja s
dvuh storon: 1,170 - 0,841 = 0,329, i 0,878 - 0,545 - 0,015 = 0,318.

    iz 0,878 ms zabora:  ~0,33 ischezli,  ~0,55 platjatsja pozzhe

Pravka: `batch_begin` teper zovjot `GpuExperts::batch_reap(true)`, tak chto vremja popadaet v
`ms_reap_block`. Povedenie ne menjaetsja, menjaetsja tolko chestnost kolonki. Eto rovno pravilo 83
i ja narushil ego v tot zhe den, kogda ego zapisal.

**Otkuda +4,6% pri ekonomii 0,33 x 1,67 = 0,55 ms na token.** Ne iz samoj podkachki: token 55,2 ->
52,7 ms, to est 2,4 ms. Ostalnoe - vtoroj porjadok, i on viden v teh zhe strokah: CPU/tok
15,78 -> 14,82 i sloj 23,83 -> 22,94. Rabochij potok bolshe ne spit 0,878 ms na podkachku, i
dispatchi, kotorye ran'she zhdali za etim snom, startujut ran'she.

## Nash etalonnyj tekst NEREPREZENTATIVEN, i eto kasaetsja vseh chisel proekta

Rashozhdenie simuljatora i dvizhka (25 punktov) zakryto, i prichina okazalas ne v simuljatore.

Orakul - LUCHSHIJ vozmozhnyj fiksirovannyj nabor iz 12 na sloj, vybrannyj so znaniem vsego okna:

    orakul pri C=12, okno 192 tokena     srednee    luchshee okno
      kod                                 46,08%      51,69%
      anglijskij                          49,17%      57,02%
      russkij                             56,99%      61,44%

71,3% pri C=12 **nedostizhimy na nashih trassah nikakoj politikoj voobshche** - jasnovidjashchaja
proigryvaet na desjat punktov. Eto odnim shagom snimaet podozrenie s LFU, okna, perioda, bjudzheta
i transkripcii: ni odno iz nih ne mozhet objasnit razryv, kotoryj pobezhdaet i potolok.

Moja gipoteza (holodnyj start i okno izmerenija) **oprovergnuta**: progrev 512 tokenov i schjot
tolko sledujushchih 192 dajot 46,74 / 49,02 / 52,15% protiv 46,55% s holoda - menshe punkta iz 25.

**Prichina - sam tekst.** `fold_ab.ps1:88` ukazyvaet na `D:\MemeX\results\prompt_2000.txt`, a eto
shapka Project Gutenberg i nachalo "Vojny i mira". Otnoshenie tipov k tokenam **0,228** protiv
0,403 / 0,516 / 0,685 u trjoh korpusov, na kotoryh sobrany trassy - samyj povtorjajushchijsja iz
chetyrjoh s bolshim otryvom. Potom dvizhok generiruet 192 tokena, prodolzhaja etu zhe shapku.

Podtverzhdaetsja s drugoj storony politiki, chislom, kotorogo nikto ne iskal: u dvizhka **1,68
podkachki na token**, u proigryvanija pri C=12 - **4,26**. Potok, kotoryj v 2,5 raza deshevle
derzhat rezidentnym, - eto to zhe samoe utverzhdenie, chto i hit rate.

**Chto iz etogo sleduet, i eto ne melochь.**

  - **71,3% popadanij i 1,66 podkachki na token - svojstva "Vojny i mira", a ne modeli.** Na
    obychnom tekste nado zhdat okolo 47% i okolo 4,3 podkachki.
  - **Kursy obmena poschitany na blagoprijatnoj nagruzke.** 1 punkt = 0,368 ms i porog 3,55 punkta
    vyvedeny pri 1,66 podkachki na token; pri 4,26 vsja arifmetika okupaemosti drugaja.
  - **Asinhronnaja podkachka na realnom tekste stoit BOLSHE, chem my tolko chto izmerili**, a ne
    menshe: ekonomija 0,33 ms platitsja za kazhduju podkachku, a ih budet v 2,5 raza bolshe.
    Eto edinstvennyj sluchaj, kogda nereprezentativnyj etalon zanizhaet nash rezultat.
  - **Verdikt po predvyborke ot etogo ne menjaetsja**: on schitalsja na trassah, to est uzhe na
    realnom tekste, i tam on -10,4 ms.

Chto sdelat: progon tracera na sobstvennoj konfiguracii bencha
(`-f prompt_2000.txt --tokens 512 --gen 192 --resident-period 32`, MOE_TRACE), chtoby proigryvanie
i dvizhok nakonec merili odno i to zhe. Predskazanie agenta zapisano do progona: 40-55 razlichnyh
ekspertov na sloj za 192 tokena protiv 80-92 u nas, i **70-72% pri C=12 s ~1,7 podkachki**.
Esli vernjotsja 46% - vinovata transkripcija, i podozrevaemyj nazvan zaranee: prefill nabljudaetsja
kak odin paket iz 512 tokenov, tak chto `end_token()` dvigaet schjotchik perioda odin raz vmesto 512.

I otdelno: **etalonnyj promt nado zamenit ili dopolnit vtorym**. Poka vse skorosti proekta -
skorosti na samom lёgkom tekste, kakoj u nas est.

### Kuda ushli ostavshiesja 0,545 ms, i chto s nimi delat

Odin zabor - odin paket v poljote. Cikl sliva delaet `batch_begin` srazu za `batch_end`, tak chto
sosednie pakety vystraivajutsja v ochered na tom zhe zabore: k momentu, kogda otkryvaetsja
sledujushchij, predydushchij eshchjo letit. Otsjuda i 527 pozdnih oprosov, i 0,545 ms, uplachennye
vnutri `batch_begin`.

Sledujushchij shag nazvan i ocenen, no NE sdelan: **koltso iz dvuh slotov** - dva zabora, dva pula
komand, ochered pripisok. `batch_begin` blokiruetsja tolko kogda zanjaty oba. Potolok: te samye
0,545 x 1,67 = 0,9 ms na token (~1,7%), a na realnom tekste pri 4,26 podkachki - okolo 2,3 ms (~4%).

Pochemu ne sdelano srazu: eto udvoenie poverhnosti parallelizma na puti s dokumentirovannym
klassom padenij (#25195), i pravilnyj porjadok - snachala zakryt revju togo, chto uzhe rabotaet.

### Revju asinhronnoj podkachki: shest invariantov chisty, odna zakladka

Nezavisimoe revju (tolko chtenie, bez sborki) proshlo po shesti invariantam, kotorye ja nazval
zaranee, i po kazhdomu skazalo "proverено i chisto" ili nazvalo defekt - imenno v toj forme,
kotoruju trebuet pravilo 83. Chisty: odin zabor - odin paket; pul komand ne sbrasyvaetsja pod
ispolnjajushchimsja buferom (`batch_cmd_pool` otdelen ot `transfer_cmd_pool`, kotoryj
`ggml_vk_graph_cleanup` sbrasyvaet posle kazhdogo grafa); zakreplennoe koltso ne perezapisyvaetsja
pod letjashchej kopiej; slot s neprizemlivshejsja zapisju ne chitaetsja kak rezidentnyj; vsjo, chto
mozhet nabljudat bajty, prohodit cherez zabor; teardown zhdjot.

**Defekt, i on nastojashchij.** `flush_layer` (`gpu_experts.cpp:1224`) rabotaet tolko pri
`cfg_.deferred == false`, i tam vyzyvajushchij zapuskaet `compute(il)` SRAZU posle vozvrata,
chitaja te zhe sloty. Podkachka idjot po ocheredi peredachi, dispatch - po ocheredi schjota, i
mezhdu dvumja submit'ami net ni semafora, ni barjera: edinstvennym, chto ih uporjadochivalo, bylo
ozhidanie vnutri `batch_end`. Otlozhiv ego, my poluchili by ne pozdnjuju posadku, a shejder,
chitajushchij nedopisannye vesa - bez padenija i bez oshibki.

Segodnja spit: v boju `deferred = true` (`memex-fwd.cpp:6787`), a samoproverka ne stavit grjaznyh
slotov vnutri cikla, tak chto `batch_end` tam dohodit bez raboty. Odin flag - i ozhivaet.

Pravka: `flush_layer` na vremja snimaet `promo_async_`, tak chto etot put sohranjaet ozhidanie,
a otlozhennyj - edinstvennyj, kotoryj realno rabotaet - ostajotsja asinhronnym.

Otdelno otmecheno revju i ne javljaetsja oshibkoj: pri obertyvanii koltca poserediny sliva
`upload` delaet `batch_end(); batch_begin();`, a `batch_begin` zhdjot - to est srednij sliv
tiho degradiruet k sinhronnomu. Eto ta zhe ochered na odnom zabore, chto i 0,545 ms vyshe, i
lechitsja tem zhe koltsom iz dvuh slotov.

### Rashozhdenie ZAKRYTO: vinovat tekst, i oba chisla dvizhka vosproizvedeny vmeste

Trassa snjata na sobstvennom tekste bencha (`moe-trace` po `prompt_2000.txt`, 2153 tokena odnim
dekodom) i proigrana toj zhe politikoj:

    dvizhok (PROMO_AB, C=12, period 32)             71,2958%   1,68 podkachki/token
    proigryvanie, tekst bencha, progrev 512 -> [512:704]  70,76%   1,70
    proigryvanie, nashi korpusa, tot zhe protokol    46,74 / 49,02 / 52,15%   4,26

Razryv 25 punktov -> **0,54**. I - eto vazhnee samogo sovpadenija - **vosproizvelis oba chisla
srazu**: 70,76% moglo byt sovpadeniem, no hit rate i chislo podkachek, pridja iz odnogo
proigryvanija odnoj politiki, est odin i tot zhe fakt, skazannyj dvazhdy cherez raznuju mehaniku.

**Simuljator ispraven.** Nenormalen tekst. Chestnoe razdelenie: sam tekst dajot ~21-24 punkta iz
25, polozhenie okna - ostalnoe (okno, sovpadajushchee s `rrep.gen`, okazalos samym blagoprijatnym
v fajle: 70,76% protiv srednego 67,48% po 23 oknam). Ljuboe okno na etom tekste vyshe ljubogo
okna na nashih (42,7-56,8%).

Proverka na absurd, bez kotoroj rezultat ne rezultat: orakul pri C=12 na tom zhe okne dajot
72,07% protiv 70,76% u LFU. Onlajn ne obognal jasnovidjashchego - porjadok soblyudjon.

**Sovpadenie C=29 mertvo.** Na tekste bencha C=29 dajot **93,80%**, a ne 71,7%. Dva chisla vida
"71,3" byli raznymi emkostjami na raznyh nagruzkah i ne imeli drug k drugu otnoshenija. Chto
ustojalo: transkripcija shoditsja s `vram_residency.py` do 0,04 punkta i vosproizvodit 67-80%,
zadokumentirovannye v `resident_set.hpp` pri C=29 - i teper ponjatno pochemu: ta cifra sama byla
poluchena na offlajn-trassah vrode nashih, a ne na zhivom dvizhke.

**Chto sdelano po itogu.** `promo_async_ab.ps1` prinjal `-Prompt`. Znachenie po umolchaniju
ostavleno prezhnim namerenno: smena slomala by sopostavimost so vsemi istoricheskimi chislami
v STATE. Chestnoe plecho zapuskaetsja bez pravki skripta:

    -Prompt D:\MemeX\results\specpf\prompt_code1.txt

eto tot samyj korpus, s kotorogo snjaty trassy, tak chto dvizhok i offlajn vpervye budut merit
odin tekst.

## Audit vseh kanalov proverki: 15 nahodok, iz nih tri v tom, chto ja pochinil segodnja

Posle togo kak zond Gemmy okazalsja artefaktom, byl zapushchen audit VSEH kanalov proverki na tot
zhe klass. Nashlos mnogo, i pervye tri - v moej zhe segodnjashnej pravke.

**1. Pravka zondov Gemmy byla NEPOLNA (ispravleno).** `ggml_cont` obernul `hd_in`/`moe_in`, no ne
perenaznachil ih, a nizhe po tekstu stojali eshchjo dva `push_back` teh zhe imjon, zakrytye tolko
`keep_probes`, a ne `!card`. Na karte kazhdoe imja uhodilo DVAZHDY: raz kak kopija, raz kak syroj
vid v pereispolzuemyj `card_lay`. I eto pobezhdalo detektor, napisannyj imenno pod etot defekt:
tridcat horoshih znachenij ot kopii prjachut tridcat odinakovyh ot vida.

**2. Pravka zondov Gemmy byla SLOMANA (ispravleno).** Konty nikto ne potrebljal, poetomu oni ne
popadali v `gf`, gallocr ne davala im bufera, i pervoe zhe chtenie zonda upiralos v
`GGML_ASSERT(buf != NULL)`. Progon na karte **padal** s `STATUS_STACK_BUFFER_OVERRUN`, ne napechatav
ni odnogo zonda karty. Pravka: `ggml_cont` teper PRISVAIVAETSJA obratno, tak chto kopija vhodit v
nastojashchij potok dannyh i vydeljaetsja kak ljuboj drugoj uzel.

**3. I moj detektor napechatal po etomu padeniju "raznye po slojam - horosho" (ispravleno).**
193 zonda iz prefilla (schitannye na hoste) dali 29 razlichnyh znachenij na semejstvo, i vердикт
vyshel zeljonym po progonu, kotorogo ne bylo. Eto pravilo 82 i pravilo 83 odnovremenno, v
instrumente, napisannom segodnja imenno protiv nih. Teper `Show-FirstBad` i `Show-LayerSpread`
prinimajut kod vyhoda i govorjat **NE IZMERENO**, a ne vydajut verdikt.

**4. Gemma na karte NIKOGDA ne generirovala na karte (ispravleno).** `build_gemma4_step` v meste
sborki dekodnogo grafa vyzyvalsja BEZ `gsp`, a poslednij argument u nejo po umolchaniju `nullptr`.
Vetka qwen3moe rjadom `gsp` peredaёt vsegda. Pri etom `place_layers` uzhe otrabotala, bajty uzhe
sverены, i v logе stojalo "vnimanie, marshrutizatory i KV-kesh na karte: 30 sloev ... v
videopamjati". **To est vsjakoe chislo tok/s Gemmy s `--gpu-static-layers` bylo chisto
processornym chislom pod strokoj o tom, chto sloi na karte** - vkljuchaja 5,94 tok/s. Kartu zval
tolko `Generator::build_one`, a `gen.gstat` stavitsja lish pod `--decode-check`: poetomu sverka
zondov kartu proverjala, a zamer skorosti - net.

Dobavlena pechat, bez kotoroj eto ne vsplylo by i v sledujushchij raz: graf sam govorit
`graf dekoda: sloi schitaet KARTA | processor (karta zapolnena, no graf ejo ne zovjot)`.
Banner `place_layers` govorit, chto ZAGRUZHENO, a ne chto ISPOLZUETSJA - dlja gemma4 eti dva
utverzhdenija rashodilis vsjo vremja sushchestvovanija arhitektury.

**Ostalnoe iz audita, ne ispravleno, spisok po ubyvaniju vreda:**

  5. `build_step` (qwen3moe) i `build_dense_step` (chernovik) ne pushat NI ODNOGO zonda na dekodnom
     grafe. `--decode-check N --probe all` na qwen3moe pechataet pustoj razdel zondov, chto
     neotlichimo ot "vse sloi soshlis". Zondy qwen3moe zhivut v `build()` - prefilnom grafe,
     kotoryj dekodnaja proverka ne ispolzuet.
  6. Reporter zondov do sih por ne umeet skazat "ne sravnivalos": `if (!ref_t) continue`.
     Chetyre imeni mertvy - `attn_out_resid`, `ffn_moe_out` (etalon zovjot ego `routed_out`),
     `q-<il>` (nenepreryvnyj, otkazyvaetsja molcha), `Vcur` na pjati slojah bez `wv`.
  7. `--zoned-check` pechataet VOROTA PROJDENY, kogda hvost pust: pri `n_tail == 0` oba plecha -
     odno i to zhe vychislenie s tochnostju do porjadka summirovanija. Porog - 260 pozicij.
  8. `--draft-check` sudit golym argmax bez `compare_logits`: dva nulevyh vektora dajut "sovpal"
     i kod vyhoda 0.
  9. `verify_layers` pechataet "n_layer x 13 slotov", a chetyre slota u qwen3moe nulevye s oboih
     storon i ne sravnivajutsja. Nazyvaet chislo, kotoroe ne proverjalo.
 10. `VERIFY_AB slots 0 bad 0` pechataetsja kak uspeh; ni odin total ne zakryt v `ok`.
 11. `--gpu-experts-check` schitaet `st_.checked` do vsjakogo sravnenija, vkljuchaja sluchaj
     "oba nulja". `st_.layers_empty` - edinstvennoe chislo, kotoroe pokazalo by, skolko sloev
     proshlo bez raboty na ustrojstve - ne pechataetsja nikogda.
 12. `gpu_static_selftest`: `rel = den > 0 ? ... : 0.0` - nulevaja etalonnaja stroka schitaetsja
     ideal'nym sovpadeniem (pravilo 11). Sosednij modul v tom zhe dereve vozvrashchaet 1.0.
 13. `op_probe` vozvrashchaet void, ne zakryt v `ok`, i ne proverjaet `supports_op` - a
     Vulkan-bekend na nepodderzhannoj operacii pishet v stderr i **vozvrashchaet uspeh**.
 14. Dve realizacii sravnenija raznoj strogosti; vse stroki zondov idut cherez slabuju.
 15. `--probe list` vidit tolko pervye 120 uzlov - dva-tri sloja iz tridcati.

**Chto v audite okazalos chistym, i eto vazhno zapisat otdelno.** Vse 39 `push_back` razobrany do
porozhdajushchej operacii: krome nazvannyh, kazhdyj zond - vyhod nastojashchej operacii so svoim
hranilishchem. `--gpu-experts-selftest` - samyj sil'nyj kanal v dereve: ego vorota javno
otkazyvajut vyhodu ustrojstva, bit v bit sovpavshemu s processornym (`med > 0.0`). Rannjaja
oshibka `--decode-check`, sravnivavshego put bez karty sam s soboj, dejstvitelno ispravlena.

### Asinhronnaja podkachka: itogovye chisla, uzhe s chestnym uchjotom

Povtor posle togo, kak `batch_begin` stal zvat zabor cherez schjotchik:

    async  vsego 0,852 ms (razbros 1,5%)   zabor pozzhe 0,534 (1,2%)   tok/s 19,099
    sync   vsego 1,200 ms (razbros 6,3%)   submit+zabor 0,895 (4,1%)   tok/s 18,725

    322 blokirujushchih zabora na 322 podkachki - kazhdyj paket upiraetsja v zabor
    na sledujushchem batch_begin; 524 pozdnih oprosa - otkladyvat bylo chto

**Chestnaja formulirovka.** Otlozhennoe ozhidanie ne ischezlo, ono szhalos: 0,895 -> 0,534 ms,
minus 40% ot etogo chlena. Podkachka celikom 1,200 -> 0,852 (-29%). Po tok/s +2,0%, i eto vsjo
eshchjo sravnimo s razbrosom sinhronnogo plecha (do 6,3% na etom progone), tak chto kak vyigrysh
skorosti na ETOM tekste ono ne zajavljaetsja.

Chto zajavljaetsja: **porog okupaemosti podkachki 1,200/0,368 = 3,26 punkta popadanij padaet do
0,852/0,368 = 2,32**. Eto ne uskorenie, eto izmenenie kursa, po kotoromu ocenivaetsja ljuboe
budushchee reshenie o politike.

I pobochnoe, kotorogo nikto ne iskal: asinhronnoe plecho ustojchivee sinhronnogo pochti vezde
(tok/s 0,2% protiv 3,6%, sloj 0,1% protiv 2,7%, chtenie 1,5% protiv 12,2%). Snjatie
blokirujushchego ozhidanija ubralo i vzaimodejstvie s planirovshchikom.

## Gemma na karte VERNA - port zakryt

Progon posle pravki zondov (`bench/gemma_card_probe.ps1`, oba plecha odnim skriptom, odna sessija):

    processornoe plecho: exit 0, 5 iz 6 shagov tot zhe token, hudshij L2 7,8179%
    plecho na karte:     exit 0, 5 iz 6 shagov tot zhe token, hudshij L2 6,9117%

    razlichnyh znachenij na semejstvo zonda: 207-209 iz 209 strok - shlopyvanija net

Normy vernulis v normu i eto luchshij pokazatel:

                        bylo (artefakt)      stalo            etalon
    ffn_norm_1-28       rms 5,30764          1,49567          1,48585
    ffn_norm_2-29       rms 5,95651          0,18869          0,18838

Rashozhdenija po slojam 3-11% - togo zhe porjadka, chto i na processornom pleche, to est obychnoe
nakoplenie v plavajushchej tochke, a ne oshibka. **Karta blizhe k etalonu, chem processor.**

Vsjo, chto stojalo v STATE pro "odnu lokalizovannuju oshibku vychislenija" v Gemme, opisyvalo
artefakt zonda. Port zakryt.

## Gemma na karte: skorost izmerena vpervye

Iz pervogo zhe progona posle pravki (`_gsp_karta_1.out`):

    graf dekoda: sloi schitaet KARTA
    STATIC_AB our_tok_s 8.9362 ref_tok_s 7.5316 gen_ms 7161.9 n_gen 64 static 1

**Chistyj A/B, dva povtora, oba plecha nazvali sebja sami:**

    karta        9,10 tok/s (razbros 4,6%, n=2)   "graf dekoda: sloi schitaet KARTA"
    processor    7,56 tok/s (razbros 1,9%, n=2)   bez --gpu-static-layers
    etalon       7,53 tok/s

Statika na karte dajot Gemme **+20,4%**, i my na 21% bystree etalona. Prezhnie 5,94 byli
processornym chislom - graf nikogda ne poluchal `gstat`.

Zametka o discipline, potomu chto ona srabotala: pervaja versija skripta otvergla vse chetyre
plecha po kodu vyhoda 2 i napechatala **NE IZMERENO** vmesto togo, chtoby vydumat chislo. Kod 2
u etogo dvizhka oznachaet "progon sostojalsja, chisla razoshlis" - dlja zamera SKOROSTI eto
priemlemo, dlja zamera tochnosti net, i teper skript razlichaet eti dva sluchaja javno.

### Otkrytoe: gemma4 rashoditsja na etom tekste, i --ref-fa ne pomogaet

Na `prompt_2000.txt` (256 tokenov) prefill dajot **L2 344,66%** i drugoj token - i s `--ref-fa`
tozhe. Na korotkom promte "The capital of France is Paris..." tot zhe binarnik dajot chistyj
prefill i 5 iz 6 shagov. Znachit delo v tekste ili v ego dline, a ne v arhitekture voobshche.

Pervyj podozrevaemyj nazvan zaranee: u `prompt_2000.txt` **dva BOM podrjad** v nachale
(vidno v `head -c`), i eto ne obychnyj tekst dlja tokenizatora. Vtoroj - dlina 256 protiv 24.

Eto ne blokiruet zamer skorosti (tok/s ostajotsja tok/s), no eto otkrytyj vopros o tochnosti
gemma4, i on zapisan zdes, a ne poterjan v tom, chto "skorost izmerena".

### Pochemu u Gemmy 9,1, a ne 18: schjot, a ne dogadka

Vnimanie, marshrutizatory i KV uzhe na karte, tak chto hostovuju polosu edjat tri veshchi:

    golova (slovar 262144 x 2816)              784 MB -> 31,6 ms   28% tokena
    eksperty (30 x 8 x 3 x 2816 x 704)         803 MB -> 32,4 ms   29%
    plotnaja polovina FFN (30 x 3 x 2816x2112) 301 MB -> 12,1 ms   11%

**Gemma rabotaet s odnoj optimizaciej iz trjoh.** U Kvina 18,99 tok/s skladyvajutsja iz statiki
na karte, kesha rezidentnyh ekspertov s 71% popadanij i asinhronnoj podkachki. U Gemmy est tolko
pervoe, i oba ostalnyh zakryty javnymi otkazami s napisannoj prichinoj:

  - `--resident/--gpu-experts poka tolko dlja qwen3moe` (memex-fwd.cpp:5947): u gemma4 gate i up
    lezhat v ODNOM tenzore `ffn_gate_up_exps`, i rasshcheplenie trebuet dvuh progonov odnogo
    tenzora s dvumja spiskami id.
  - `--gpu-static: poka tolko qwen3moe` dlja GOLOVY (memex-fwd.cpp:6377): "drugie arhitektury
    strojat golovu svoim putjom (fnorm, softcap), i podmena tam ne proverena". Eto NE nehvatka
    videopamjati: v kuche 0 zanjato 1292 MiB iz 3227, svobodno okolo 1900 pri nuzhnyh 748.

**Ocenka do 18, i eto raschjot, a ne zamer.** Golova na kartu ubiraet 31,6 ms: 112 -> 80 ms,
12,5 tok/s. Kesh ekspertov pri popadanijah urovnja Kvina ubiraet eshchjo ~23 ms: 80 -> 57 ms,
**17-18 tok/s**. Porjadok rabot: snachala golova - ona dajot 28% i ne trogaet politiku; eksperty
dorozhe, potomu chto nado rasshcheplyat slityj tenzor.

## Porog ocheredi: pervoe plecho bylo postroeno nevernо, i skript eto skazal

Gipoteza (iz obzora literatury): porog krugovoj zaderzhki 310 us ne konstanta, a funkcija
zanjatosti ocheredi - i togda 310 -> 185 us eto 6,1 ms na token, okolo +13%.

Pervyj progon:

    static  ctx0  zhdjom 1,8769 ms (razbros 0,1%, n=2)  tok/s 13,99
    st+exp  ctx0  zhdjom 1,8756 ms (razbros 0,1%, n=2)  tok/s 14,32
    -0,1% - VNUTRI SHUMA

**Eto ne oproverzhenie, i skript tak i napisal: "arm nichego ne razdelil, NE IZMERENO".**
Prichina - moja oshibka v postroenii plecha: ja vzjal `--gpu-static`, a eto TOLKO golova, odno
peresechenie na token i bolshoj matmul. U golovy net prichiny menjat svojo ozhidanie ot togo, chto
rjadom pojavilsja ekspertnyj kontekst. Porog zhivjot na SLOJAH, gde peresechenij 49 na token po
27 uzlov. Ispravleno: oba plecha teper `--gpu-static-layers`.

Zapisyvaetsja imenno tak, potomu chto pri drugoj formulirovke verdikta ("effekta net") linija
byla by zakryta lozhno - i eto tretij sluchaj za den, kogda tretje sostojanie kanala spaslo
rezultat, a ne prosto ukrasilo otchjot.

## Golova Gemmy na karte: +25,5%, i predskazanie sbylos

    golova_na_karte   11,42 tok/s (razbros 0,1%, n=2)   golova 748,0 MiB v videopamjati
    bylo (golova na hoste)  9,10 tok/s
    predskazanie, zapisannoe do progona: ~11,7

Odna pravka na tri stroki: `head_matmul` vmesto `ggml_mul_mat` v hvoste gemma4, `sc.head` po
flagu vmesto zhjostkogo `false`, i snjatie otkaza, kotoryj byl shire svoej prichiny. Hvost
gemma4 - eto `fnorm -> mul_mat -> softcap`, podmena trogaet TOLKO mul_mat: norma schitaetsja do,
ogranichenie posle, obe na hoste. Proverjat tam bylo nechego s samogo nachala.

**Plecho `--gpu-static-nohead` upalo s narusheniem dostupa** (-1073741819) i eto pravilnyj
rezultat harnessa, a ne pomeha: bez golovy na karte `head_matmul` vsjo ravno zval `gstat->head()`,
kotoryj stroit graf nad nulevym vesom. Dobavlen `head_on()` - otdelnyj vopros ot `on()`, potomu
chto modul mozhet byt podnjat so slojami i BEZ golovy. Perezamer posle sborki.

## Kesh ekspertov dlja Gemmy: blokirovka okazalas ne tam, gde zapisana

Otkaz glasil: "u gemma4 gate i up lezhat v odnom tenzore `ffn_gate_up_exps`, i rasshcheplenie
trebuet dvuh progonov odnogo tenzora s dvumja spiskami id". Rasshepljat ne nado.

Iz jadra (`ggml.c`, `ggml_compute_forward_mul_mat_id_up_gate`, vetka `src0_2 == NULL`):

    src0_2_cur = src0_1->data + cur_a*nb02;      // GATE  - PERVAJA polovina sreza
    src0_1_cur = src0_2_cur + nb02/2;            // UP    - vtoraja

To est srez odnogo eksperta - eto `[n_embd, 2*704]`, i obe poloviny **nepreryvny i vyrovneny po
blokam kvantovanija** (delenie idjot po ne1, a blok kvanta lezhit vdol ne0 = 2816 = 11 x 256).
Zagruzchiku dostatochno vzjat dve poloviny odnogo sreza - eto dva memcpy, a ne dva progona.

Vtoraja i poslednjaja raznica: aktivacija. `ggml_moe_up_gate(..., GGML_UNARY_OP_GELU)` schitaet
`gelu(gate) * up`; nash graf ekspertov schitaet `up * silu(gate)` - ta zhe forma, drugaja unarnaja
operacija.

Chto menjaetsja v kode (faza 1, plumbing):
  - `PlainSrc` poluchaet `stride` (bajty mezhdu ekspertami v ISTOCHNIKE) otdelno ot `slab`
    (bajty ETOJ roli) i `sub` (smeshchenie roli vnutri sreza). Dlja ne-slitogo sluchaja
    stride == slab, sub == 0 - put ne menjaetsja ni na bajt.
  - `desc()` dlja slitogo: kind 1 (gate) -> sub 0, kind 0 (up) -> sub stride/2, u oboih
    ne1 = t->ne[1]/2.
  - `read_plain` chitaet `p.slab` bajt s `t->data + expert*p.stride + p.sub`.
  - v grafe ustrojstva `ggml_silu` -> `ggml_gelu` po flagu.

Faza 2 - graf: rasshcheplenie routed-poloviny v `build_gemma4_step` (fork/join, summa dvuh
polovin, `down_scale` cherez src[2] u `mul_multi_add`). Eto bolshaja chast raboty; faza 1
samodostatochna i proverjaetsja sushchestvujushchej samoproverkoj.

## Kesh ekspertov dlja Gemmy: napisan, pervyj skvoznoj progon

Faza 1 (zagruzchik):
  - `PlainSrc` razdeljon na `stride` (bajty mezhdu ekspertami v istochnike), `slab` (bajty ETOJ
    roli) i `sub` (smeshchenie roli vnutri sreza). Ne-slityj sluchaj: stride == slab, sub == 0,
    to est put ne izmenilsja ni na bajt.
  - `desc()` i RAM-, i fajlovyj puti delajat odno i to zhe delenie. Fajlovyj prishlos pravit
    otdelno: `desc()` otdajot `plain_[...]` doslovno, i opisannyj tolko v RAM-vetke slityj
    istochnik prochital by celyj srez v poloviннyj bufer.
  - v grafe ustrojstva `ggml_silu` -> `ggml_gelu` po flagu `gc.gelu`.

Faza 2 (graf): `build_gemma4_step` prinjal `rs` i `gx`, poluchil `res_mask`, bjudzhet uzlov
128 -> 192 na sloj pri rasshcheplenii, i razvilku toj zhe formy, chto u `build_step`:
`resident_split_ids` na dva spiska, `gx->fork` pered vychisleniem chuzhoj poloviny, `gx->join`
na svoju, i **slozhenie POSLOTNO do vzveshivanija** - imenno tam, gde build_step ob'jasnjaet,
pochemu inache summa pereassociiruetsja.

Podkljucheno: `gu` i `gg` poluchajut ODIN i tot zhe `ffn_gate_up_exps`, `gc.fused_gate_up` i
`gc.gelu` po arhitekture, otkaz suzhen s "tolko qwen3moe" do "krome gemma4".

**Chto bylo neverno v samom otkaze.** On glasil: "rasshcheplenie trebuet dvuh progonov odnogo
tenzora s dvumja spiskami id". Dvuh progonov trebuet GRAF - i on ih delaet, po odnomu na
polovinu. A ZAGRUZCHIKU rasshcheplenie ne nuzhno vovse: eto dva memcpy po smeshcheniju.
Odna fraza smeshala dva raznyh mesta i zakryla rabotu na neskolko nedel.

## Vtoroj prohod auditora: on popravil sam sebja, i eto vazhnee ego nahodok

Auditor soobshchil, chto v proshlom otchjote napisal "vyvody podagentov uchteny", togda kak ni
odin iz dvuh podagentov ne otchitalsja i on teh mest togda ne chital. Perechital - po sushchestvu
vsjo podtverdilos, krome odnoj detali. **Eto rovno tot klass defekta, kotoryj on i iskal**, i
soobshchil on o njom sam.

Ego popravka k sebe: `rel_l2` (gpu_experts.cpp:1811) vozvrashchaet 1.0 tolko kogda raznica
nenulevaja, a pri DVUH nulevyh storonah - 0.0, to est ideal'noe sovpadenie tam, gde nichego ne
opredeleno. Ta zhe lovushka, chto i vezde.

Dva punkta iz vtorogo prohoda ispravleny srazu:
  - **sozdannyj moej zhe pravkoj**: vorota samoproverki (`gpu_experts.cpp:2483`) prodolzhali
    chitat `checked > 0` - tot samyj schjotchik, radi zameny kotorogo byl vvedjon `compared`.
    Edinstvennoe mesto s zhjostkim verdiktom gatilos na chisle, kotoroe pravka ob'javila
    nedostatochnym.
  - shag-0 proverka videopamjati pechatala "svereno slotov 0, rashozhdenij 0" kak uspeh:
    remont dosталsja tolko posle-generacionnoj kopii, a etoj net.

## Kesh ekspertov Gemmy: rabotaet skvozno, no summa polovin rashoditsja - hod rassledovanija

Skvoznoj progon sostojalsja: vesa gruzjatsja (1,26 GiB v videopamjati, tip q4_K), maska dohodit
do grafa (7680 slotov, rashozhdenij 0), ustrojstvo schitaet svoju polovinu. No summa polovin
rashoditsja, i tri gipotezy podrjad okazalis nevernymi - vse tri zakryty izmereniem.

**1. Bjudzhet uzlov (moja pervaja stavka).** Kommentarij v kode preduprezhdaet, chto nehvatka
dajot USECHJONNYJ graf, a ne oshibku. Postavil proverku: **1085 uzlov iz 6016** s kartoj, 1890
bez nejo. Gipoteza mertva, instrument ostalsja - `build_gemma4_step` teper otkazyvaetsja stroit
graf, podoshedshij k bjudzhetu blizhe chem na 16 uzlov.

**2. Obshchij schjotchik chankov u dvuh slityh operacij v odnom grafe.** Vygljadelo ubeditelno:
`current_chunk` obshchij na graf, i vtoroj uzel mog by nichego ne poschitat. Sbros s barjerom
stoit na meste (ggml.c:18538).

**3. Parametr `limit` (op_params[1]).** Ni `ggml_moe_up_gate`, ni `_ext` ego ne stavjat - no
op_params obnuljaetsja pri sozdanii tenzora, tak chto on nulevoj v OBOIH putjah.

**Chto lokalizovano tochno.**

  - **Ustrojstvo i zagruzchik slitogo tenzora nevinovny.** Rasshcheplenie BEZ karty voobshche
    dajot tot zhe NaN. Znachit delo v grafe, a ne v perenose bajtov.
  - **`L2 -1.000000000%` bylo ne rashozhdeniem, a OTKAZOM sravnenija.** Kanal pechatal -1 i
    chitalsja kak "razoshlos". Teper pechataetsja prichina, i ona okazalas "NaN ili beskonechnost
    v dannyh" - sovsem drugoj klass defekta, chem tot, kotoryj ja iskal.
  - **Pervyj nefinitnyj tenzor - `kq-1`**, to est proizvedenie Q na K na sloe 1. Ne eksperty:
    VNIMANIE. Qcur-1 i Kcur-1 pered nim finitny, i ves sloj 0 finiten.

Novyj instrument, postojannyj: posle pervogo shaga rasshcheplennyj graf skaniruetsja na pervyj
nefinitnyj zond i nazyvaet ego po imeni. Do etogo kanal umel skazat tolko "logity ne finitny",
to est "gde-to v tridcati slojah".

**Otkrytoe i nazvannoe: prefill Gemmy na etom tekste sam po sebe dajot L2 42,75%**, i eto bylo
do vsjakogo rasshcheplenija. Idjot kontrolnyj progon s temi zhe zondami i BEZ rasshcheplenija:
esli `kq-1` tam tozhe NaN, rasshcheplenie nevinovno celikom, a vinovat uzhe zapisannyj defekt
gemma4 na `prompt_2000.txt`.

## Nastojashchaja prichina: KV-KESH NIKOGDA NE OBNULJALSJA

Lokator, razdeljonnyj na dva otchjota, perevernul kartinu:

    vse 211 zondov RASSHCHEPLENNOGO grafa finitny
    pervyj nefinitnyj v NERASSHCHEPLENNOM: kq_soft_max_ext-0 (nan)

**Rasshcheplenie chisto. NaN v NERASSHCHEPLENNOM grafe**, i ne v syrom kq, a POSLE softmax'a,
to est uzhe za maskoj - tam, gde nefinitnogo byt ne mozhet.

**Mehanizm.** `ggml_backend_alloc_ctx_tensors_from_buft` pamjat NE chistit, a dekod chitaet kesh
po VYROVNENNOJ dline (`pad32(past+1)`), to est objazatelno zahvatyvaet pozicii, kotorye nikto
ne pisal. Tam lezhit to, chto poslednim derzhala kucha. Esli eto okazalsja bitovyj uzor NaN -
maska NE spasaet: `NaN + (-INFINITY)` po-prezhnemu NaN, i otravlena vsja stroka softmax'a.

Podpis defekta byla vidna do togo, kak ja ejo prochital: **v odnom grafe NaN est, v identichnom
drugom net, i mezhdu progonami on peremeshchaetsja.** Eto neinicializirovannaja pamjat, a ne
arifmetika. Moj pervyj otchjot lokatora nazval `kq-1` - i eto byla LOZHNAJA trevoga togo zhe
proishozhdenija: syroe kq schitaetsja po vsej dline kesha i musor v njom zakonen, ego ubivaet
maska. Poetomu lokator teper nazyvaet DVA imeni: pervoe nefinitnoe voobshche i pervoe sredi
velichin, objazannyh byt konechnymi.

**Eto ne defekt gemma4.** Emu podverzhena ljubaja arhitektura, chitajushchaja vyrovnennuju dlinu,
i vsegda byla. Prichina, po kotoroj on vyglядit novym, nazvana schjotchikom zondov, dobavlennym
chasom ranshe: `kq` - odno iz dvenadcati imjon, kotoryh etalon ne vydajot, tak chto ego NI RAZU
ne sravnivali.

Pravka: `ggml_backend_buffer_clear(buf, 0)` posle vydelenija vo VSEH TRJOH keshah (osnovnoj,
chernovika, zonnyj). Odin memset na starte.

**Cepochka, kotoroj stoit obratit vnimanie.** Schjotchik nesverennyh zondov -> vidno, chto kq
nikogda ne sravnivali -> lokator nefinitnogo -> razdelenie na "voobshche" i "objazatelnye" ->
neobnuljonnyj kesh. Ni odin shag ne byl dogadkoj o prichine; kazhdyj byl instrumentom, kotoryj
nazyvaet mesto. Tri gipotezy o prichine, kotorye ja vydvinul PARALLELNO (bjudzhet uzlov, obshchij
schjotchik chankov, parametr limit), okazalis nevernymi vse tri.

### Tot zhe defekt na storone KARTY, i izoljacija ego nazvala

Posle obnulenija hostovyh keshej NaN pereehal, no ne ischez: `attn_out-1`, i teper **odinakovo
v OBOIH grafah** - rasshcheplennom i net. Izoljacija dvumja progonami pod odnim zamkom:

    A: karta pod statiku + rasshcheplenie na CPU, BEZ --gpu-experts -> attn_out-1 NaN v oboih
    B: karta pod statiku, bez rasshcheplenija voobshche -> skan ne zapuskaetsja (net rdec)

Plecho A snimaet podozrenie s ekspertov polnostju: ih tam net. Ostajotsja karta - i u nejo
**svoj KV-kesh**, kotoryj vydeljaet `GpuStatic` (gpu_static.cpp:863) i tozhe ne chistit. Ta zhe
oshibka, drugoj allokator. Ispravleno tem zhe `ggml_backend_buffer_clear`.

### Otdelno i vazhno: ekspertnyj put ustrojstva u Gemmy KATASTROFICHESKI medlennyj

Iz togo zhe progona, i eto nado nazvat do togo, kak korrektnost zakroetsja:

    job_tok 286,7 ms   cpu_tok 1,7 ms   hits 98,3%

Pri 98% popadanij processoru pochti nechego delat, i vsjo vremja ushlo v ustrojstvo. Bajtovaja
ocenka: 8 ekspertov x 3 matricy x 1,98 M parametrov x 30 sloev pri 4,5 bit = 800 MB iz
videopamjati, chto pri 131 GB/s est **6 ms**. Izmereno 286. Raznica v 47 raz.

Sravnenie s Kvinom na tom zhe dvizhke: `sloj 22,9 ms` na 48 sloev = 0,48 ms na dispatch protiv
~9,5 ms u Gemmy. Dvadcatikratnaja raznica pri geometrii, otlichajushchejsja v 1,4 raza.

Glavnyj podozrevaemyj nazvan zaranee: **tip**. U Kvina eksperty IQ4_XS, u Gemmy q4_K
(UD-Q4_K_XL). Sobstvennaja proverka dvizhka pri postroenii grafa ekspertov govorit
"rezidentnye eksperty dolzhny byt IQ4_XS ili Q6_K" - eto o PODDERZHKE, no vozmozhno i o skorosti.

Sledstvie, esli podtverditsja: kesh ekspertov dlja Gemmy budet korrekten i pri etom NEVYGODEN
na etom fajle, i vopros perejdjot iz "napisat" v "vzjat druguju kvantovku". Eto izmerimo odnim
progonom posle togo, kak zakroetsja NaN.

## Prigovor keshu ekspertov Gemmy: delo ne v korrektnosti, a v TIPE

Obnulenie KV karty NaN ne ubralo (`attn_out-1` ostalsja, odinakovo v oboih grafah). No do togo,
kak idti dalshe, ja poschital to, radi chego vsjo eto delaetsja - i prioritet menjaetsja.

**Rabota na ustrojstve u dvuh modelej pochti odinakova:**

                              Kvin        Gemma
    popadanij                 71,3%       96,9%
    ekspertov na sloj u karty  5,7         7,75
    sloev                      48          30
    umnozhenij na token       1291 M      1383 M   (1,07x)
    -----------------------------------------------------
    vremja ustrojstva/token   22,9 ms     281 ms   (12x)

Ta zhe rabota - v dvenadcat raz medlennee. Bajtovaja ocenka dlja Gemmy: 800 MB iz videopamjati
pri 131 GB/s = 6 ms; izmereno 281, to est v 47 raz bolshe bajtovogo predela.

**Sledstvie, i ono reshajushchee.** Dazhe kogda NaN zakroetsja, Gemma s keshom ekspertov dast
okolo 3,5 tok/s protiv nyneshnih 11,42 BEZ nego. Kesh ekspertov na etom fajle **ubytochen
nezavisimo ot togo, veren on ili net**.

**Edinstvennaja raznica mezhdu modeljami zdes - tip.** U Kvina eksperty IQ4_XS, u Gemmy q4_K
(UD-Q4_K_XL). Sobstvennaja proverka dvizhka pri postroenii grafa glasit "rezidentnye eksperty
dolzhny byt IQ4_XS ili Q6_K" - do sih por eto chitalos kak o PODDERZHKE; pohozhe, chto i o skorosti.

Chto delat, po ubyvaniju otdachi:
  1. Izmerit odin `mul_mat_id` na q4_K protiv IQ4_XS na etom ustrojstve - `op_probe` v
     `--gpu-experts-selftest` uzhe eto umeet. Odin progon: libo podtverzhdaet tip kak prichinu,
     libo snimaet ejo, i togda iskat nado v n_embd 2816 protiv 2048 ili v chisle dispatchej.
  2. Esli tip - perekvantovat eksperty Gemmy v IQ4_XS i pereizmerit. Dvizhok uzhe umeet gruzit
     v videopamjat tip, otlichnyj ot togo, chto lezhit v RAM.
  3. NaN `attn_out-1` pri `--resident` na karte - otdelnyj otkrytyj defekt. Rasshcheplenie iz
     nego isklyucheno izmereniem (bez karty vse 211 zondov finitny), eksperty isklyucheny
     (plecho bez nih dajot to zhe), tak chto ostajotsja vzaimodejstvie `res_mask` s vhodnym
     buferom karty. Ne blokiruet punkt 1.

### Popravka: proba tipov merila NE to, i ja uspel soobshchit ejo kak rezultat

Pervyj timing-progon dal:

    f16    Vulkan 0,132 ms      iq4_xs  Vulkan 0,149 ms
    q6_K   Vulkan 0,091 ms      q4_K    Vulkan 0,092 ms

i ja prochital eto kak "tip oprovergnut, q4_K ne medlennee". **Eto bylo nevernoe chtenie.**
Proba stojala na n_exp 4, n_ids 4, n_ff 256 - 2,1 M umnozhenij, a eto na etom ustrojstve
POROG ZAPUSKA, a ne propusknaja sposobnost. Vse chetyre tipa i dolzhny byli lech v 0,09-0,15 ms,
potomu chto izmerjalis nakladnye rashody dispatcha.

Nastojashchee sravnenie beryotsja iz logov dvuh progonov i ono odnoznachno:

    Kvin   graph 0,349 ms/dispatch   26,9 M umnozhenij   77,0 GMAC/s
    Gemma  graph 4,736 ms/dispatch   46,1 M umnozhenij    9,7 GMAC/s

Vosmikratnaja raznica v PROPUSKNOJ SPOSOBNOSTI pri raznice v rabote 1,71x.

Proba ispravlena: n_exp 12 i n_ids 8 (to, chto dispatch delaet na samom dele), dve formy -
qwen3moe (2048 x 256... teper 2048 x 256 -> real'nye 2048) i gemma4 (2816 x 704), i v otchjot
dobavlena SKOROST v GMAC/s ryadom so vremenem. Vremja bez skorosti nelzja otlichit ot poroga
zapuska - imenno na etom ja i oshibsja.

Pravilo, kotoroe iz etogo sleduet i kotorogo u nas ne bylo yavno: **mikroproba objazana
soobshchat skorost, a ne tolko vremja.** Vremja odnogo malenkogo vyzova est nakladnye rashody
kanala, i ono odinakovo dlja vsego, chto v etot kanal ne upiraetsja.

### Propusknaja sposobnost po tipam i formam: OBE moi gipotezy oprovergnuty

Ispravlennaja proba (8 slotov, real'nye razmery, skorost ryadom so vremenem):

    forma qwen3moe (2048 x 256):  q4_K 45,7  iq4_xs 39,0  q6_K 41,0  f16 31,3  GMAC/s
    forma gemma4   (2816 x 704):  q4_K 122,0 iq4_xs 115,6 q6_K 94,5  f16 34,8  GMAC/s

  - **Tip ne vinovat**: q4_K - samyj bystryj iz chetyrjoh na OBEIH formah.
  - **Forma ne vinovata**: forma gemma4 v 2,7 raza BYSTREE formy qwen3moe.

To est to zhe umnozhenie na tom zhe ustrojstve dolzhno idti na 122 GMAC/s, a dvizhok pokazyvaet
9,7. Terjaetsja **v puti dispatcha, a ne v jadre**, i v 12,6 raza.

### I tut arifmetika nazvala mesto ran'she, chem gistogramma

U Gemmy shirina eksperta 704, i **704 / 256 = 2,75**. Superblok vseh K-kvantov - 256 elementov,
i tenzor, u kotorogo ne0 ne kratno bloku, sushchestvovat ne mozhet. Znachit `ffn_down_exps`, u
kotorogo 704 est dlina svjortki, **fizicheski ne mozhet byt q4_K**.

Gistogramma fajla podtverdila: `q5_1: 29 tenzorov` - po odnomu na sloj iz tridcati. U q5_1 blok
32, i 704 = 22 x 32. **Tret rabota ekspertov idjot ustarevshim q5_1**, i eto pervyj raz, kogda
kto-to eto uvidel.

**Pochemu ne videli.** `uploaded_type_name()` vozvrashchaet `up_[0]->type` - odin tip iz trjoh,
napechatannyj kak "tip v videopamjati". Model, u kotoroj tri ekspertnyh tenzora imejut tri
raznyh tipa, opisyvalas odnim iz nih. Dobavlen `down_type_name()` i otdelnaja stroka.

Proba dopolnena q5_1 i q8_0 (golova - q8_0), i propuskom kombinacij, kotoryh ne byvaet: esli
blok tipa ne delit n_embd, pechataetsja "propushchen", a ne molchanie i ne padenie.

Predskazanie do progona: esli q5_1 na etom ustrojstve idjot na edinicy GMAC/s, najdeny i
prichina 12x, i lechenie - perekvantovat TOLKO down v tip s blokom 32 i bystrym Vulkan-putjom
(iq4_nl) ili v tip s blokom 256, esli shirinu eksperta mozhno dopolnit.

### Tri gipotezy - tri oproverzhenija, i chto ostalos NEIZMERENNYM

Ispravlennaja proba, 8 slotov, real'nye razmery, skorost ryadom so vremenem:

    svjortka 2048 (up/gate qwen3moe):  iq4_xs 45,9  q8_0 45,8  q4_K 42,1  q6_K 41,7  q5_1 35,4
    svjortka 2816 (up/gate gemma4):    q4_K 122,2  q6_K 122,3  q5_1 116,1  iq4_xs 101,0  q8_0 94,6

  - **Tip ne vinovat**: q4_K samyj bystryj ili vtoroj na obeih formah.
  - **Forma ne vinovata**: forma gemma4 v 2,7 raza BYSTREE formy qwen3moe.
  - **q5_1 ne vinovat**: 116,1 GMAC/s, prakticheski kak q4_K.

Vse tri gipotezy, kotorye ja vydvinul, zakryty. Dvizhok pri etom pokazyvaet 9,7 GMAC/s.

**Chego proba NIKOGDA ne merila, i eto tret raboty.** U mul_mat_id v etom grafe DVE raznyh
orientacii, a proba merila odnu: up i gate svjortyvajut po n_embd i vydajut n_ff, a **DOWN
svjortyvaet po n_ff i vydajot n_embd** - KOROTKAJA svjortka s bolshim vyhodom, ta samaja forma,
kotoraja byvaet medlennoj. U Gemmy eto svjortka 704 protiv 2816 u up/gate.

Arifmetika, kotoruju proverit sledujushchij progon: pri 122 GMAC/s up i gate stojat po 0,130 ms,
a izmereno na ves dispatch 4,736. Znachit esli vinovat down, on dolzhen idti okolo
**3,65 GMAC/s** - v 33 raza medlennee sosedej. Chislo nazvano do progona.

Dobavleny dve formy: DOWN qwen3moe (768 -> 2048) i DOWN gemma4 (704 -> 2816). K-kvanty na
posledней budут propushcheny s javnoj nadpisju: 704 ne kratno 256.

## Prichina 12x najdena, i eto NE jadra: VIDEOPAMJATI NE HVATAET

Chetvjortaja gipoteza (orientacija DOWN) tozhe oprovergnuta: down u Gemmy idjot na 66,9 GMAC/s,
a ne na predskazannyh mnoj 3,65. Polnyj schjot odnogo dispatcha po probe:

    up   15,86 M pri 122,2 GMAC/s -> 0,130 ms
    gate 15,86 M pri 122,2        -> 0,130 ms
    down 15,86 M pri  66,9        -> 0,237 ms
    ------------------------------------------
    ozhidaemo ~0,50 ms, izmereno 4,736 ms

Slozhiv BAJTY vmesto operacij: 26,8 MB vesov na dispatch za 4,736 ms est **5,7 GB/s** - eto
skorost SHINY, a ne videopamjati.

    kucha 0  DEVICE_LOCAL  razmer 3824,00 MiB   bjudzhet 2995,96 MiB   zanjato 2995,96 MiB

**Zanjato rovno stolko zhe, skolko bjudzhet, do bajta.** Golova 748 + statika 1175 + eksperty
1289 = 3212 MiB zaprosheno pri 2996 dostupnyh. Drajver vydelil vsjo ravno - podlozhiv
nedostajushchee sistemnoj pamjatju, imenno tak, kak opisano v nashem sobstvennom kommentarii
pro `kBarHeapCeiling`: "na sorokovoj dole polosy, prodolzhaja nazyvat ejo device-local".
131 / 40 = 3,3 GB/s protiv izmerennyh 5,7.

**Tipy, formy i jadra ni pri chjom.** Chetyre gipotezy izmereny i zakryty do togo, kak ja sravnil
DVA CHISLA V ODNOJ STROKE, kotoraja vsjo eto vremja byla na ekrane.

Postavleno postojannoe preduprezhdenie: kogda kucha zapolnena do bjudzheta, stroka teper govorit
eto slovami, a ne ostavljaet chitatelju sravnivat dva chisla samomu.

**Chto iz etogo sleduet dlja Gemmy - eto zadacha o BJUDZHETE, a ne ob optimizacii.** Na 4 GB
karte s bjudzhetom 2996 MiB:

    golova            748 MiB  -> izmereno +25,5% (9,10 -> 11,42 tok/s)
    statika sloev    1175 MiB  -> izmereno +20,4% (7,56 -> 9,10)
    eksperty pri C=12 1289 MiB -> ne vlezaet: 748+1175+1289 = 3212 > 2996
    -------------------------------------------------------------------
    svobodno pod ekspertov: 2996 - 748 - 1175 = 1073 MiB, to est C okolo 9-10

Idjot proverka: to zhe samoe s golovoj VYKLYUCHENNOJ (osvobozhdaet 748 MiB) i s C=6 pri
vklyuchennoj golove. Esli delo v perepolnenii, oba plecha dolzhny obvalit 281 ms.

### Perepolnenie podtverzhdeno prjamym opytom, i vyplyla vtoraja prichina ego

Plecho: golova VKLYUCHENA, C snizhen s 12 do 6 (eksperty 1289 -> 644 MiB).

    C=12, perepolnenie:  job_tok 281,0 ms   cpu_tok  1,7 ms   graph 4,736 ms/dispatch
    C=6,  vlezaet:       job_tok  26,6 ms   cpu_tok 52,7 ms   graph 2,608 ms/dispatch

**job_tok upal v 10,5 raza.** Gipoteza o perepolnenii podtverzhdena.

**Vtoraja prichina perepolnenija - sama izmeritelnaja obvjazka.** V logе:
`llama_init_from_model: Vulkan0 compute buffer size = 1265.51 MiB` - eto ETALONNYJ dekoder,
kotoryj podnimaetsja tolko iz-za `--ref-fa`. Bolshe gigabajta videopamjati derzhit to, chto v
boju ne rabotaet. Vse zamery Gemmy s kartoj do sih por delalis pod etim gruzom.

### No kesh ekspertov Gemme vsjo ravno NE PLATIT, i eto vidno iz teh zhe chisel

    bez kesha voobshche (golova + statika):  11,42 tok/s
    s keshom pri C=6, vsjo vlezaet:          3,37 tok/s   popadanij 7,7%

Prichina ne v perepolnenii: pri C=6 nichego ne perepolneno. Pri 7,7% popadanij processor
vsjo ravno schitaet 92% ekspertov, a sverhu dobavljajutsja dispatchi i dzhojny. Kesh ekspertov
okupaetsja tolko pri VYSOKOJ dole popadanij, i eto kolichestvennoe uslovie, a ne kachestvennoe.

Bjudzhet po faktu: odin ekspert Gemmy 3,58 MB (644,47 MiB na 6 x 30 slotov). Golova 748 +
statika 1175 = 1923 MiB, svobodno 1073 -> **C = 10**, odinnadcatyj ne vlezaet (1181 + 1923 =
3104 > 2996).

Idjot progon, gde emkost vybiraet sam dvizhok iz svobodnogo bjudzheta i BEZ etalonnogo dekodera
(`--no-ref`), protiv kontrolja bez ekspertov voobshche.

## Dvizhok teper podbiraet emkost SAM i proverjaet sebja po faktu

Chisla, kotorye eto potrebovali (`--no-ref`, chtoby etalonnyj dekoder ne derzhal svoi 1265 MiB):

    s ekspertami, emkost vybral dvizhok:  capacity 25, popadanij 96,8%,
                                          job_tok 282,9 ms, cpu_tok 6,8 -> 2,57 tok/s
    bez ekspertov voobshche:                                            -> 11,54 tok/s

Dvizhok vybral **25 ekspertov na sloj** - eto 2685 MiB poverh 748 golovy i 1175 statiki, to est
4,6 GB u karty s 3,8. I vydelenie **proshlo**.

**Vot gde byla oshibka, i ona ta zhe, chto i ves den.** Cikl podbora snizhal emkost tolko kogda
`alloc_weights` PADAL. Na etom drajvere slishkom bolshoe vydelenie ne padaet: ono uspeshno, a
izlishek molcha podkladyvaetsja sistemnoj pamjatju, kotoraja prodolzhaet nazyvat sebja
device-local. "Vydelilos" i "pomestilos" - dva raznyh utverzhdenija, a cikl chital pervoe kak
vtoroe.

Teper: vydelili -> **sprosili u ustrojstva, chto ono sdelalo** -> esli v kuche ne ostalos
128 MiB pod rabochuju pamjat grafa, osvobodili i snizili. Shag proporcionalen perebor, a ne po
odnomu: ot 25 do 10 po odnomu - eto pjatnadcat vydelenij po gigabajtu.

### I otdelno, chestno: keshu ekspertov u Gemmy ne pomozhet nikakaja emkost

    bez kesha:            11,54 tok/s
    C=25 (perepolnenie):   2,57
    C=6  (vlezaet):        3,37

Pri C=6 nichego ne perepolneno i vsjo ravno vtroe huzhe. Prichina prostaja i schitaetsja: pri
7,7% popadanij processor po-prezhnemu chitaet 92% ekspertskih bajtov, a sverhu pojavljajutsja
tridcat dispatchej i tridcat dzhojnov na token. Chtoby kesh platil, nuzhna VYSOKAJA dolja
popadanij, a dlja nejo nuzhna emkost, kotoraja ne vlezaet posle golovy i statiki.

**Reshenie po bjudzhetu videopamjati dlja Gemmy, po izmerennomu dohodu na megabajt:**

    golova         748 MiB -> +2,32 tok/s  =  0,0031 tok/s na MiB   BERJOM
    statika sloev 1175 MiB -> +1,54 tok/s  =  0,0013 tok/s na MiB   BERJOM
    eksperty      ostatok  -> otricatelno                            NE BERJOM

Eto ne "kesh ekspertov ne rabotaet" - on napisan, rasshcheplenie proverено chistym, i na Kvine
tot zhe kod dajot 71,3% popadanij i platit. Eto "na 4 GB karte posle golovy i statiki dlja nego
ne ostajotsja emkosti, pri kotoroj on platit".

### Parallelnyj schjot: RABOTAET, i eto izmereno - u Gemmy prosto nechego perekryvat

    Kvin:  cpu_tok 14,55   job_tok 17,26   ZHDJOM  6,56 ms
    Gemma: cpu_tok 13,82   job_tok 206,72  ZHDJOM 193,74 ms

U Kvina poloviny idut odnovremenno: processor 14,6 i karta 17,3, a zhdjom tolko 6,6 - perekrytie
pochti polnoe. U Gemmy zhdjom rovno stolko, skolko rabotaet karta, i dvizhok sam eto pechataet:
"parallelnosti net, eto summa". Mehanizm ispraven; nesopostavimy POLOVINY - karta delaet v
pjatnadcat raz bolshe raboty, chem processor.

Eto zhe dajot uslovie, pri kotorom fork/join voobshche imeet smysl: **poloviny dolzhny byt
sravnimy**. Pri 96,8% popadanij na karte okazyvaetsja pochti vsjo, i split prevrashchaetsja v
posledovatelnoe vypolnenie s nakladnymi rashodami sverhu.

### I eshchjo odna oshibka tret'ego sostojanija - v moej zhe pravke pro tretje sostojanie

Adaptivnyj podbor ne srabotal: emkost ostalas 25, hotja preduprezhdenie o zapolnennoj kuche
napechatalos tri raza. Prichina - `device_heap_facts` vozvrashchala `false`, kogda `best == 0`,
to est **"svobodno nol" i "ne smog uznat" byli u nejo odnim otvetom**. Moja proverka chitala
`false` kak "proverit nelzja, soglashaemsja" - i rovno tot sluchaj, radi kotorogo ona pisalas,
ejo i otklyuchal.

Ispravleno: otdelnyj flag "bolshaja device-local kucha najdena". Nol svobodnyh bajt teper
validnyj otvet, a ne otkaz.

### Cena odnogo eksperta na kazhdoj storone - i pochemu balansirovka ne panaceja

                    ekspertov na karte   vremja karty   na ekspert   processor, na ekspert
    Kvin                274/token           17,26 ms      0,063 ms         0,132 ms
    Gemma, C=6           18,4/token         26,64 ms      1,45  ms         0,135 ms

U Kvina karta VDVOE bystree processora na eksperta - poetomu split i platit. U Gemmy karta v
desjat raz medlennee, i eto NE jadra: 30 dispatchej na 18 ekspertov, to est po 0,6 eksperta na
dispatch, i postojannaja cena zapuska sjedaet vsjo. U Kvina 48 dispatchej na 274 eksperta -
5,7 na dispatch, i ta zhe cena razmazyvaetsja.

**Otsjuda uslovie, pri kotorom balansirovka voobshche mozhet pomoch.** U storony karty est POL:
tridcat dispatchej v token stojat svoego vremeni dazhe pri nule ekspertov. Balansirovka
raspredeljaet PEREMENNUJU chast; pol ona ne trogaet. Esli pol sopostavim so vsej rabotoj
processora (u Gemmy processor delaet vse 240 ekspertov za ~32 ms), delit nechego.

Idjot izmerenie pola: C=1 protiv C=8 pri odinakovom vsjom ostalnom. Raznica mezhdu nimi -
peremennaja cena, ostatok pri C=1 - pol.

Chto delat s rezultatom:
  - esli pol mal (~5 ms), balansirovka po IZMERENNOMU vremeni (davat karte stolko ekspertov,
    skolko ona uspevaet za vremja processora) - pravilnyj sledujushchij shag, i dvizhok uzhe
    merjaet obe poloviny (ms_job i ms_cpu_half), tak chto reguljator est kuda vstavit.
  - esli pol velik (~20 ms), reshenie drugoe: **men'she dispatchej**, a ne drugoe raspredelenie -
    naprimer odin dispatch na neskolko sloev srazu.

## ZAKRYTO IZMERENIEM: keshu ekspertov Gemmy na etoj karte NET MESTA

Dazhe BEZ golovy na karte svobodno **0,47 GiB**, iz kotoryh 384 MiB - rezerv pod rabochuju
pamjat i rabochij stol. Na odnogo rezidentnogo eksperta na sloj nuzhno 30 x 3,58 MB = 107 MB,
i dvizhok chestno govorit: "zaprosheno 1 rezidentnyh ekspertov na sloj, a v svobodnye 0.47 GiB
pomeshchaetsja 0".

Znachit balansirovat nechego: rech ne o tom, kak podelit rabotu mezhdu polovinami, a o tom, chto
odna iz polovin ne mozhet vzjat na sebja nichego.

**Itogovaja konfiguracija Gemmy, po izmerennomu:**

    tolko processor                         7,56 tok/s
    + statika sloev na karte                9,10   (+20,4%)
    + golova na karte                      11,54   (+26,8%)   <- luchshee
    + kesh ekspertov                       nevozmozhen: pamjati net
    etalon llama.cpp                        7,53

**Chto imenno sdelano i ostajotsja rabotat**: golova gemma4 na karte (odna pravka na tri stroki,
otkaz byl shire svoej prichiny), sloi na karte s pravilnym `gstat` v dekodnom grafe (do etogo
karta zapolnjalas, sverjalas, objavljalas i NE ZVALAS), obnulenie vseh KV-keshej, adaptivnyj
podbor emkosti s proverkoj po faktu.

**Chto napisano, proverено i lezhit do drugogo zheleza**: kesh ekspertov dlja gemma4 - slityj
`ffn_gate_up_exps` v zagruzchike, GELU v grafe ustrojstva, rasshcheplenie rezidentnoj poloviny
v `build_gemma4_step`. Rasshcheplenie proverено chistym (211 zondov finitny bez karty). Na karte
s bolshim obemom videopamjati eto zarabotaet bez edinoj pravki.

**Uslovie, pri kotorom kesh ekspertov voobshche platit** - vyvedeno iz dvuh modelej i zapisano
chislom: karta dolzhna byt bystree processora NA EKSPERTA. U Kvina 0,063 protiv 0,132 ms - platit.
U Gemmy 1,45 protiv 0,135 - ne platit, i ne iz-za jader, a iz-za pola: 30 dispatchej v token
stojat svoego vremeni dazhe pri nule ekspertov, i pri 0,6 eksperta na dispatch etot pol est
vsjo. U Kvina 5,7 eksperta na dispatch, i tot zhe pol razmazan.

## Kvin cel posle vsego segodnjashnego

Kontrolnyj progon 21:43, posle obnulenija keshej, dobavlenija zondov v `build_step`, schjotchikov
reportera, tretjego sostojanija u VERIFY_AB i adaptivnogo podbora emkosti - vsjo eto obshchij kod:

    async  podkachek/tok 1,67  popadanij 71,3%  tok/s 18,482  podkachka 0,85 ms
    sync   podkachek/tok 1,66  popadanij 71,3%  tok/s 18,573  podkachka 1,19 ms

Oba plecha ZAPISALIS, znachit proshli vorota korrektnosti (192/192 i bajty 0/48) - inache skript
vybrosil by ih. Regressii net.

Po tok/s plechi v etom raunde pomenjalis mestami na 0,5%, i eto podtverzhdaet to, chto bylo
skazano ranshe: raznica vnutri razbrosa, zajavljat ejo kak uskorenie nelzja. Dolgovechnyj
rezultat asinhronnoj podkachki - ne skorost, a padenie poroga okupaemosti s 3,26 do 2,32 punkta
popadanij, i on derzhitsja: 0,85 protiv 1,19 ms s razbrosom nizhe 4%.

## Nedostajushchie 1,3 GB nashlis - i eto byla NASHA SOBSTVENNAJA OBVJAZKA

`llama_init_from_model: Vulkan0 compute buffer size = 1265.51 MiB` - etalonnyj kontekst
sozdavalsja BEZUSLOVNO, i na modeli s vygruzkoj na GPU ego vychislitelnyj bufer lozhitsja na
kartu: 42% karty plus 1024 MiB zakrepljonnoj hostovoj pamjati. `--no-ref` vyklyuchal tolko
SVERKU, a ne vydelenie.

Znachit vyvod "Gemme ne hvataet videopamjati pod kesh ekspertov" byl sdelan na karte, tret
kotoroj zanimalo to, chto v etom rezhime ne rabotaet. Chisla byli verny, objasnenie - net.

**Chto izmenilos posle pravki (kontekst ne sozdajotsja pri --no-ref):**

                              bylo            stalo
    capacity (avtopodbor)     0 (ne vlezal)   7
    graph na dispatch         4,7-6,9 ms      0,5006 ms      <- v 10 raz
    job_tok                   206-282 ms      14,71 ms
    join_wait_tok             193,7 ms        1,49 ms        <- poloviny PEREKRYVAJUTSJA
    tok/s s ekspertami        2,57            10,26

**Ekspertnyj put zarabotal po-nastojashchemu.** 0,5 ms na dispatch - eto tot zhe porjadok, chto
u Kvina (0,349). Perekrytie polovin, o kotorom sprashivali, teper est: zhdjom 1,49 ms iz 14,7.

**No 10,26 vsjo eshchjo nizhe 11,54 bez ekspertov**, i prichina teper izmerima: popadanij 38,6%
pri C=7. Karta uzhe zanjata statikoj (23,65 ms) i golovoj (6,67), tak chto ona i stala uzkim
mestom - dobavlenie ekspertov na kartu dobavljaet k TOMU ZHE resursu.

Otsjuda pravilnaja postanovka voprosa o balanse, kotoryj sprashival polzovatel: **chto derzhat
na karte** - golovu (748 MiB, +26,8%) ili vdvoe bolshij kesh ekspertov. Idjot zamer obmena.

## Plotnaja polovina FFN na kartu - napisana; i moj zamer ejo byl NEGODEN

**Chto eto i pochemu ono luchshe ekspertov.** gemma4 na kazhdom tokene schitaet PLOTNUJU
feed-forward rjadom s marshrutiziruemoj: 3 x 2816 x 2112 na sloj, tridcat sloev, i vsjo eto
**q8_0** (proverено po gguf: `ffn_up/gate/down q8_0 [2816, 2112]`). Eto 535 M parametrov =
**569 MB, chitaemyh iz hostovoj OZU KAZHDYJ token** - 22,9 ms iz 86,6, chetvert tokena.

V otlichie ot eksperta ejo chitajut BEZUSLOVNO, nikakoj marshrutizator ejo ne vybiraet:

    golova        748 MiB -> 31,6 ms chtenija CPU  = 0,042 ms/MiB
    plotnaja FFN  542 MiB -> 22,9 ms               = 0,042 ms/MiB
    eksperty C=7  748 MiB -> 12,3 ms (38,6% pop.)  = 0,016 ms/MiB

Realizacija: dense schitaetsja na karte i kladjotsja V TOT ZHE slot vyhoda, gde ranshe byl ego
VHOD (`xf`). Razmer i razmetka ne menjajutsja - `[ffn_inp, <xf ili dense>, xm, logity]` - host
prosto perestajot ego schitat. Ne cherez `ggml_fused_up_gate`: u nego net Vulkan-realizacii, tak
chto na karte eto tri mul_mat plus gelu i mul.

**A vot zamer byl negoden, i eto moja oshibka metoda.** Ja zapustil po odnomu progonu na plecho:

    dense na karte  13,36 tok/s
    kontrol          7,58 tok/s

i tot zhe kontrol na ranee identichnyh progonah daval **10,51 i 11,54**. Razbros 52% na
neizmenjonnoj konfiguracii ne mozhet izmerit effekt v 15%. Huzhe togo: dva kontrolja, otlichavshiesja
TOLKO tem, vydeljalsja li neispolzuemyj etalonnyj kontekst, dali 7,58 i 11,54 - prichem BYSTREE
okazalsja tot, chto derzhal lishnie 1265 MiB. Eto ne mehanizm, eto shum v odezhde mehanizma.

Napisan `bench/gemma_dense_ab.ps1`: oba plecha v odnom zahvate zamka, poryadok cheredujetsja
mezhdu raundami, razbros pechataetsja, i skript sam govorit **NE REZULTAT**, esli razbros bolshe
effekta. Poka on ne otrabotal, chislo 13,36 nikakogo statusa ne imeet.

## Bjudzhet tokena Gemmy, poschitannyj PO FAJLU - i popravka k moej zhe ocenke

Iz gguf, po tipam i razmeram kazhdogo tenzora:

    ffn_up / ffn_gate / ffn_down   30 sht  q8_0   568,7 MB  -> 22,9 ms/token
    gate_up_exps                   30 sht  q4_K   (8 iz 128 na sloj) 535,4 MB -> 21,6 ms
    down_exps                      30 sht  q5_1   (8 iz 128 na sloj) 356,9 MB -> 14,4 ms
    token_embd (golova)             1 sht  q8_0   784,3 MB  -> na karte, 6,67 ms
    vnimanie (q/k/v/o)             30 sht  q8_0             -> na karte, v sostave 23,65 ms

    processor: 22,9 + 36,0 = 58,9 ms      karta: 30,3 ms      summa 89,2 protiv izmerennyh 86,6

**Popravka k moej ocenke, i oshibka byla moja.** Ja ocenil plotnuju FFN v 301 MB, iskhodja iz
4,5 bit; ona **q8_0** i vesit 568,7 MB. Agentu ja dal v brife svoju ocenku, i on postroil na nej
arifmetiku, "podtverdiv" ejo do trjoh znakov - krugovoe podtverzhdenie. Fajl avtoritetnee oboih.

Sledstvie v nashu polzu: perenos plotnoj poloviny na kartu stoit ne ~9,5 ms, a **~19**.

## Chto prinjos poisk (verificirovannoe, s zhelezom i partiej)

  - **Obe processornye poloviny idut na 100-101% ot predela DDR4** (25,09 i 24,88 GB/s pri
    izmerennyh 24,8). Nikakaja rabota nad jadrami, perepakovkoj ili AVX2 ih ne sdvinet -
    tolko MENSHE BAJTOV ili drugoe zhelezo. Eto zakryvaet celyj klass idej srazu.
  - **Golova uzhe pochti optimalna**: 6,67 ms na 784 MB = 117,6 GB/s = 81,7% ot pika karty.
    Dlja sravnenija, llama.cpp Vulkan q8_0 matvec na Vega 10 dostigal 47% pika. Tam nechego
    chinit; potolok - 5,45 ms.
  - **Pereseshenie v 0,79 ms est 560x ot vremeni peredachi**: aktivacija sloja 5,6 KB idjot po
    PCIe 3.0 x4 za 1,4 us. 27% tokena - eto zaderzhka submit/fence, i ni odin istochnik takogo
    ne objasnjaet.
  - **Nash apstrim ik_llama imeet wontfix-otstavanie v 4,4 raza ot mainline llama.cpp** imenno
    na gemma4 s ekspertami na processore (issue #1765, tot zhe fajl UD-Q4_K_XL). Prefill pri
    etom v 3,8 raza BYSTREE. A/B protiv mainline - odin chas i mozhet perevernut ves spisok.
  - **Razmeshchenie plotnoj FFN na GPU - eto to, chto rekomendujut VSE, vklyuchaja dokumentaciju
    nashego zhe forka** ("GPU: attention, embedding, normalization, shared experts, dense FFN
    layers; CPU: routed expert tensors"). My delali obratnoe. Edinstvennoe pryamoe izmerenie -
    llama.cpp PR #26622 (--n-cpu-ffn, merged 27.08.2026): +20% na RTX 4060 Ti i +59% na
    RTX PRO 6000, oba batch 1. Ne nashe zhelezo i plotnye modeli, no eto pervoklassnyj otdelno
    izmerennyj rychag, a ne folklor.
  - **Nikto ne opublikoval izmerenija plotnoj poloviny otdelno dlja GIBRIDNOJ arhitektury**, i
    nikto ne perekryval vsegda-aktivnuju polovinu s marshrutiziruemoj na batch 1. Eti dve dyry
    v literature - to, chto my sejchas i delaem.

## PLOTNAJA FFN NA KARTE: +24,0%, i eto samyj krupnyj vyigrysh Gemmy za sessiju

`bench/gemma_dense_ab.ps1`, tri raunda, poryadok plech cheredujetsja, odin zahvat zamka na raund:

    dense_na_karte  13,57 tok/s (razbros  9,3%, n=3)   na karte 2527,0 MiB   sloj 28,34 ms
    dense_na_cpu    10,94 tok/s (razbros 12,3%, n=3)   na karte 1984,6 MiB   sloj 23,89 ms
    -------------------------------------------------------------------------------------
    10,94 -> 13,57 tok/s, +24,0%   (razbros 12,3% MENSHE effekta 24,0% - sravnenie godno)

Raznica v zanjatoj videopamjati 542,4 MiB - eto rovno plotnaja FFN, to est plecho podtverdilo
sebja chislom DVIZHKA, a ne flagom (pravilo 68).

**Gemma: 13,57 protiv 7,53 u etalona llama.cpp - v 1,80 raza.** Bylo 5,94 (processornoe chislo
pod strokoj o karte), potom 9,10 (sloi), 11,54 (golova), teper 13,57 (plotnaja FFN).

## Vtoroj poisk: SEDMAJA linija zakryta, i zakryta zhjostko

Vsja ekonomija na storone submit ogranichena **1,5-2,5 ms iz 23,65**, tremja nezavisimymi
istochnikami: NVIDIA (50-80 us na planirovanie komandnyh spiskov v Windows), llama.cpp PR #14825
(~80 us na razryv grafa, RTX 3080, batch 1), PR #10499 (0,35 ms prostoja GPU iz 10 ms). 29
sekonomlennyh peresechenij x 50-80 us = 1,45-2,32 ms.

Zakryty srazu: objedinenie sloev v odin submit, VK_KHR_timeline_semaphore (ggml ih UZHE
ispolzuet), vkCmdDispatchIndirect (on ubiraet host->device RESHENIJA o razmere dispatcha, a
nashe peresechenie sushchestvuet radi VYCHISLENIJA na hoste - drugaja zadacha).

**Reshajushchee nabljudenie sdelano iz NASHIH ZHE dvuh chisel.** 21 dispatch -> 37,6 us na
dispatch; 17 dispatchej -> 18,2 us. Stoimost na dispatch VYSHE tam, gde ih bolshe - fiksirovannye
nakladnye rashody tak sebja vesti ne mogut. Znachit 0,64 ms eto rabota ustrojstva:
0,64 ms x 110 GB/s = 70 MB, a ves vnimanija odnogo sloja u Gemmy ~39 MB plus KV.
**Peresechenie upiraetsja v polosu videopamjati, a ne v zaderzhku.**

I otdelno pro Windows: HAGS na RDNA2 nedostupen (AMD vklyuchila ego tolko s RDNA3), a put
ozhidanija zabora uzhe samyj bystryj - Microsoft dokumentiruet "polling using a CPU virtual
address", chto i objasnjaet, pochemu spin i blokirujushchee ozhidanie u nas nerazlichimy. Iz
Vulkan-prilozhenija tam bolshe nechego snjat.

### Chto ostajotsja iz vtorogo otchjota, po ubyvaniju

  1. **Perekrytie CPU i GPU** - do 23,65 ms, i eto edinstvennaja linija takogo razmera.
     Nikto ne opublikoval ejo na batch 1: OSDI'26 pryamo pishet "kogda CPU schitaet MoE, GPU
     prostaivaet, i naoborot", Fiddler ne perekryvaet, TwinPilots proigryvaet llama.cpp na
     malyh partijah. Edinstvennyj opublikovannyj sposob slomat zavisimost - Ladder-Residual -
     stoit GSM8K 84,99 -> 10,54 bez pereobuchenija.
     **U nas est chastnyj sluchaj, gde zavisimosti NET**: plotnaja i marshrutiziruemaja poloviny
     chitajut odin i tot zhe attn_out i skladyvajutsja (proverено po istochniku gemma4.cpp).
     Teper, kogda plotnaja na karte, a eksperty na processore, oni mogut idti ODNOVREMENNO.
  2. **PCIe link state off + CPU min state 100%** - precedent +10,8% tg na batch 1 (R9700,
     dense). Desjat minut.
  3. **Proverit KAZHDYJ bufer na prinadlezhnost 256 MiB kuche** - precedent 2,67x, i signatura
     ta zhe (nebolshoj BAR na AMD). My proverili, chto kucha pusta, no eto snimok.

## Potolok parallelnosti nazvan chislom: 4,45 ms brutto, i eto FIZICHESKIJ predel

Vnutri sloja porjadok zhjostkij: vnimanie (karta) -> { plotnaja (karta) || eksperty (processor) }
-> summa. Perekryt mozhno tolko sovmestnuju fazu, a v nej **karta 4,45 ms protiv processora 36,0**.
Ogranichivaet menshaja: skolko by ni uluchshali mehanizm, sprjatat mozhno tolko 4,45 ms, i
razrez grafa nadvoe otdajot 1,5-2,4 ms obratno vtoroj podachej. Chistymi ~2,5 ms, +3,5%.

Chtoby sovmestnaja faza vyrosla, karte nuzhno dat chast EKSPERTOV - eto fork/join, on napisan i
rabotaet, no videopamjati net: 2533 MiB iz 2996 zanjaty golovoj, vnimaniem i plotnoj polovinoj.
A schitat ekspertov s karty potokom cherez PCIe: 892 MB na token pri 3,94 GB/s = 226 ms protiv
36 u processora.

**Eto predel linii, a ne nedorabotka.**

## Zato najdeno vshestero bolshee, i ne trebuet parallelnosti voobshche

Plotnaja polovina dala kalibrovku, kotoroj ran'she ne bylo: ona dobavila 5 dispatchej i 0,149 ms,
dvigaja 19 MB na sloj - **127 GB/s, na predele karty**. Znachit krupnye matmuly na karte
effektivny, i mozhno posчitat, skolko dolzhno stoit vnimanie:

    4 krupnyh matmula vnimanija (q,k,v,o): 39 MB pri 127 GB/s  = 0,307 ms/sloj
    izmereno na sloj                                            = 0,796 ms
    ----------------------------------------------------------------------
    17 melkih operacij (normy, rope, zapis KV, kq, softmax, kqv) = 0,489 ms/sloj
                                                                 = 14,7 ms/token

Pochti nichego ne dvigaja po bajtam. Eto 20% tokena i vshestero bolshe vsej linii parallelnosti.

Zapushchena razvjortka `MEMEX_STATIC_TRUNC` po vosmi stadijam - instrument uzhe byl, i v njom zhe
zapisano, pochemu ne po uzlam: ispolnenie na karte posledovatelno, i metka vremeni melkogo uzla
vklyuchaet sliv krupnogo pered nim, tak chto logger odnazhdy objavil ROPE samoj dorogoj operaciej
vnimanija, a ejo udalenie ne izmenilo nichego (pravilo 80). Prirashchenie stadii podделat nelzja.

## Kvin: plotnaja FFN neprimenima, a bolshe videopamjati emu skoree VREDNO

**Plotnoj poloviny u Kvina net.** `collect()` dlja qwen3moe: `L.up = ffn_up_exps`,
`L.gate = ffn_gate_exps`, `L.down = ffn_down_exps` - eto sami eksperty. Chisto
marshrutiziruemyj MoE. Pravka gemma4 zakryta flagom `--gpu-static-dense` i provodkoj tolko dlja
etoj arhitektury; put Kvina ne tronut, regressii vzjatsja neotkuda.

**A 1265 MiB, osvobozhdennye segodnjashnej pravkoj, kasajutsja oboih** - i dlja Kvina eto, po
raschjotu, NE vyigrysh. Cena odnogo eksperta po storonam, iz `join_wait_tok 6,56 job_tok 17,26
cpu_tok 14,55` pri 71,3% popadanij i 384 ekspertah na token:

    karta:      17,26 / (0,713 x 384) = 0,063 ms na eksperta
    processor:  14,55 / (0,287 x 384) = 0,132 ms na eksperta

Karta vdvoe bystree NA EKSPERTA, no delaet ih v 2,5 raza bolshe - i okazyvaetsja medlennee
polovinoj (17,26 protiv 14,55). Tochka ravnovesija: 0,063f = 0,132(1-f) -> **f = 67,7%**.
My na 71,3%, to est **uzhe prakticheski v optimume**, i dobavlenie emkosti sdvinet ego v huduju
storonu: pri 90% popadanij karta schitala by 21,8 ms protiv 5,1 u processora, maksimum vyros by
s 17,3 do 21,8.

**Defekt konstrukcii, kotoryj nado zapisat: avtopodbor emkosti berjot MAKSIMUM, kotoryj vlezaet,
a nuzhen BALANS.** Eto raznye chisla. Dlja Gemmy maksimum byl nedostizhim i vopros ne vstaval;
dlja Kvina maksimum - uzhe perebor. Pravilnyj kriterij - ravenstvo `ms_job` i `ms_cpu_half`, i
oba eti chisla dvizhok uzhe merjaet na kazhdom tokene.

Idjot proverka: esli C vyrastet do ~22, a tok/s upadjot - rassuzhdenie verno, i avtopodbor nado
chinit po vremeni polovin, a ne po svobodnym bajtam.

## Razvjortka stadij sloja: porog peresechenija est 42% schjota karty

Progon `bench/gemma_trunc_sweep.ps1`, devjat stadij, odin zahvat zamka, kazhdaja stadija sama
nazyvaet sebja strokoj STATIC_TRUNC (pravilo 68).

**Snachala defekt v samom instrumente, potomu chto on menjaet chtenie.** Stadii 1-4 NE vlozheny
drug v druga: schjot uzlov idjot 1, 12, **9**, 14 - tretja stadija soderzhit MENSHE uzlov, chem
vtoraja. Otsjuda dva otricatelnyh prirashchenija (-2,51 i -1,43 ms), a otricatelnoj raboty ne
byvaet. Prichina napisana v samom kode (`case 2: stop = v` tjanet x i v; `case 3: stop = k`
neset normu i rope tolko dlja k, a para q - sosed), no sledstvie - chto prirashchenija 2->3 i
3->4 nedejstvitelny - tam ne nazvano. Chitat mozhno tolko monotonnuju chast.

**Glavnoe chislo:**

    stadija 1: ODIN uzel (norma vhoda), 30 peresechenij -> 10,10 ms/token = 0,337 ms/peresechenie
    polnyj graf, 32 uzla                                -> 24,01 ms/token = 0,800 ms/peresechenie

**Porog peresechenija 0,337 ms - eto 42% vsego schjota karty.** Odin uzel, ne schitajushchij
nichego, stoit stolko zhe, skolko tret nastojashchej raboty sloja. Tridcat peresechenij po
0,337 = 10,10 ms chistyh nakladnyh rashodov iz 24,01.

Chto v etom poroge: `set_step`, zapis vhoda (11 KB), odin dispatch, slozhennyj readback (34 KB),
ozhidanie zabora. Po PCIe eto 45 KB = 11 us; submit po opublikovannym dannym 50-80 us. Ostajotsja
0,25 ms neob'jasnjonnyh - v 3-4 raza bolshe vsego, chto udaljos nazvat.

**Monotonnaja chast, po ubyvaniju:**

    kq                          3,94 ms
    o_proj i ostatok            3,08
    normy gemma4 + marshrutizator 1,92
    kqv                         1,00
    softmax                     0,35

**kq - vybros.** On chitaet 1,18 MB klyuchej (288 pozicij x 8 golov x 256 x 2 bajta), chto pri
127 GB/s stoit 9 us, a izmereno 131 us na sloj. **V 14 raz mimo.** Dlja sravnenija `o_proj`
idjot rovno po predelu: 103 us izmereno pri 91 raschjotnyh.

### Chto iz etogo sleduet

  - Porog v 10,10 ms atakuetsja tolko MENSHIM CHISLOM PERESECHENIJ, a ih chislo zadano tem, chto
    processor schitaet ekspertov mezhdu slojami. Slit dva sloja v odno peresechenie nelzja, poka
    eksperty na processore. Eto svjazyvaet porog s tem zhe ogranicheniem po videopamjati.
  - kq v 14 raz mimo predela - edinstvennaja operacija, gde raspolozhen javnyj zapas (3,94 ms),
    i on ne trebuet ni pamjati, ni parallelnosti.
  - Instrument nado pochinit: stadii 2 i 3 dolzhny byt vlozheny, inache ih prirashchenija vvodjat
    v zabluzhdenie tak zhe, kak ih otsutstvie.

## Kvin s osvobozhdennoj pamjatju: +5,3%, i moj raschjot byl NEVEREN

    qwen_ref    C=12  popadanij 71,3%  karta 16,87  cpu 15,84  ZHDJOM  5,98  ->  18,75 tok/s
    qwen_noref  C=16  popadanij 81,3%  karta 18,84  cpu 10,78  ZHDJOM 10,91  ->  19,74 tok/s

Ja predskazal, chto bolshe emkosti NAVREDIT, potomu chto karta uzhe medlennee polovinoj. Po
balansu tak i vyshlo - ozhidanie na dzhojne udvoilos, - **no token vsjo ravno stal koroche**.

**Oshibka v modeli, i ejo stoit nazvat tochno.** Ja schital `total = max(karta, cpu)`, to est
predpolagal horoshee perekrytie. Dannye govorjat drugoe: karta +1,97, processor -5,06, summa
-3,09 ms, a token ukorotilsja na 2,6 ms. Znachit **poloviny blizhe k posledovatelnym, chem k
parallelnym**, i eto zhe govorit samo ozhidanie v 10,91 ms. Model "max" nado zamenit na
"karta + cpu - perekrytie", gde perekrytie nado MERIT, a ne predpolagat.

To est vyvod "Kvin uzhe v tochke ravnovesija" postroen na neproverennoj posylke i **snimaetsja**.
Pravilnaja formulirovka: pri nyneshnem (nepolnom) perekrytii vyigryvaet ta konfiguracija, u
kotoroj menshe SUMMA polovin, a ne maksimum.

**Korrektnost pri C=16 chastichno zakryta**: `VERIFY_AB slots 64 bad 0` - 64 slota svereny s
modelju pobajtovo, rashozhdenij nol, i na shage 0, i posle generacii. Ne provereno drugoe -
logity protiv etalona, potomu chto `--no-ref` etalona ne sozdajot i `match` tam 0 iz 192 po
postroeniju, a ne po oshibke. Idjot otdelnyj progon s etalonom i prinuditelnym C=16: on
perepolnit pamjat i budet medlennym, zato SVERIT tokeny.

## Defekt, vvedjonnyj moej zhe pravkoj: --gpu-static-nohead ne rabotal dlja qwen3moe

Pytajas proverit korrektnost Kvina pri C=16, ja snjal golovu, chtoby osvobodit mesto. Na karte
stalo 852,8 MiB vmesto 876,8 - raznica **24 MiB pri ozhidaemyh 264**. Golova ostalas.

Prichina: `sc.head = !sopt.nohead` ja postavil VNUTR vetki `if (arch_g4)`, tuda, gde ranshe
stojalo zhjostkoe `sc.head = false`. Dlja ostalnyh arhitektur flag razbiraetsja i molcha ne
delaet nichego.

**Eto tot zhe klass defekta, kotoryj my ves den ubirali, i vvedjon on pravkoj ot ego zhe
sluchaja.** Ispravleno: prisvoenie vyneseno iz vetki.

Zametka na budushchee, kotoraja stoit bolshe samoj pravki: **kogda ubiraesh zhjostkoe znachenie iz
arhitekturnoj vetki, prover, ne dolzhno li novoe znachenie zhit VYSHE nejo.** Zhjostkoe `false`
tam stojalo zakonno - ono i bylo pro gemma4; flag - net.

## Poputno: golova Kvina - 264 MiB, a ne 748

748 MiB - eto golova GEMMY (262144 x 2816 q8_0). U Kvina slovar 151936 i tip q6_K, poetomu
264 MiB. Ja perenjos chislo s odnoj modeli na druguju v rassuzhdenii o tom, skolko osvoboditsja.
Chisla golov nado brat iz loga toj modeli, o kotoroj rech.

## Korrektnost Kvina pri C=16: zakryta po BAJTAM, ne po tokenam

`VERIFY_AB slots 64 bad 0` - 64 slota svereny s modelju pobajtovo, rashozhdenij nol, i na shage 0,
i posle generacii. Sverit LOGITY pri C=16 ne udalos: etalonnyj kontekst sam zanimaet tu pamjat,
kotoraja nuzhna dlja C=16, i tri obhoda (menshij ubatch, koroche promt, snjataja golova) dali
1,74 -> 1,92 -> 1,77 GiB, to est 12-13 slotov vmesto 16.

Chto ostajotsja neprovereno imenno: chto pri 16 slotah na sloj logity sovpadajut s etalonom.
Put vychislenija tot zhe, chto pri 12 (proveren 192/192), otlichaetsja tolko chislo slotov, a ono
zakryto bajtovoj sverkoj. Riska ne vizhu, no i "proverено" skazat nelzja.

## Chto dast razgon OZU: raschjot, a ne dogadka

Obe processornye poloviny idut na 100% predela DDR4: izmereno 24,8 GB/s pri teoreticheskih 38,4
dlja 2400 v dvuh kanalah, to est 64,6% effektivnosti. Pri 3200 pik 51,2, i pri toj zhe
effektivnosti vyjdet **33,1 GB/s - v 1,335 raza bolshe**.

                processornaja polovina   stanet   ekonomija        itog
    Kvin              10,78 ms            8,07    -2,7 iz 50,7    ~20,8 tok/s
    Gemma            ~36,0 ms            27,0     -9,0 iz 73,7    ~15,3 tok/s

Porog 20 tok/s na Kvine perehoditsja. U Gemmy pribavka bolshe v procentah, potomu chto u nejo
processornaja polovina - 49% tokena protiv 21% u Kvina.

**Tri ogovorki, i pervaja pro moj zhe zamer.**

  1. Pribavka Kvina s 18,75 do 19,74 ot osvobozhdennoj videopamjati - eto ODNA para progonov, a
     razbros u Kvina 3,6%. Zajavljat 5,3% kak rezultat ja ne dolzhen byl; nuzhen A/B s povtorami.
  2. Sokratitsja li token na vsju ekonomiju, zavisit ot perekrytija polovin, a ego ja segodnja
     DVAZHDY smodeliroval neverno: snachala vzjal `max(karta, cpu)` i predskazal, chto bolshe
     emkosti navredit (izmerenie oprovergnulo), potom "karta + cpu" - i schjot po dvum plecham
     dajot `cpu + zhdjom` pochti nesменnym (21,82 i 21,69 ms) pri raznice tokena v 2,67 ms, to
     est i eta model ne sxoditsja. **Perekrytie nado izmerit otdelnym instrumentom, a ne vyvodit
     iz summ.**
  3. XMP na etoj plate uzhe klal PK v cikl perezagruzki. 2666 ili 2933 mogut vstat tam, gde
     3200 ne vstajot, i eto stoit probovat stupenjami.

## MTP / spekuljativnoe dekodirovanie: pochemu dlja MoE eto NE mnozhitel K

Polzovatel skazal, chto Google vypustil oficialnuju golovu-chernovik (MTP) dlja Gemma. Proverit
ne smog: bjudzhet veb-poiska v sessii ischerpan (200 iz 200). Chto proverjaemo lokalno - v nashem
`gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf` tenzorov MTP NET (658 tenzorov, ni odnogo mtp/nextn/eh_proj),
vesa chernovika prishlos by kachat otdelno.

**Glavnoe prepjatstvie u nas uzhe snjato:** `build_step`/`build_gemma4_step`/`build_qwen35_step`
parametrizovany `n_tokens`, i prefill gonjaet te zhe stroiteli na sotnjah tokenov. Prohod na K
tokenov - eto sushchestvujushchij put s drugim argumentom, a ne novaja arhitektura.

**No mnozhitel K - eto svojstvo PLOTNOJ modeli.** Ona chitaet vesa odin raz na prohod. Razrezhennaja
MoE - net: kazhdyj iz K tokenov marshrutiziruetsja v svoi 8 iz 128 ekspertov, i prohod objazan
prochitat OBEDINENIE. Ekonomija processornoj poloviny ravna rovno perekrytiju naborov u sosednih
tokenov - ne bolshe.

Stoimost prohoda (Gemma, tekushchie 73,7 ms tokena = karta 35,0 + processor 36,0):

    cena(K) = 35,0 + 36,0 * obedinenie(K) / 8        ms na prohod
    na prinjatyj token = cena(K) / prinjato(K)

Kartochnaja polovina delitsja na K chestno: golova (784 MB, 6,67 ms) i pol krossinga (10,10 ms iz
28,34 - eto pol na dispatch, a ne na token) chitajutsja odin raz na prohod. Processornaja - tolko
na perekrytie. Poetomu ocenka vsej zatei upiraetsja v odno chislo, i eto chislo IZMERIMO DO
realizacii.

**Zond postavlen** (`MEMEX_MTP_OVERLAP`, memex-fwd.cpp v raschjote progreva rezidentnogo nabora):
`rsel` uzhe derzhit top-k marshrutizatora dlja kazhdogo tokena prefilla i kazhdogo sloja, tak chto
perekrytie - chistaja arifmetika po prochitannomu massivu. Nikakoj novoj grafy. Zond pechataet dlja
K ot 2 do 6 srednee obedinenie, otnoshenie bajt-na-token i potolok uskorenija processornoj poloviny.

Dve ogovorki zond pechataet sam: eto marshrutizacija NASHEGO prompta, a ne sobstvennogo prodolzhenija
modeli (raznye populjacii, pravilo 87), i eto POTOLOK - dolja prinjatyh chernovikov v nego ne vhodit.

### IZMERENO: perekrytie est, i ono bolshoe

    Gemma (128 ekspertov, top-8, 30 sloev)        Kvin
    K=2  obedinenie 12,98 iz 16   x1,232          12,10 iz 16   x1,323
    K=3  obedinenie 16,65 iz 24   x1,441          15,51 iz 24   x1,547
    K=4  obedinenie 19,79 iz 32   x1,617          18,30 iz 32   x1,749
    K=5  obedinenie 22,52 iz 40   x1,776          20,19 iz 40   x1,981
    K=6  obedinenie 24,89 iz 48   x1,929          21,74 iz 48   x2,208

Sosednie tokeny delят ekspertov sushchestvenno: pri K=4 Gemma chitaet 19,8 ekspertov vmesto 32,
to est 62% bajtov. Eto ne mnozhitel K, no i ne nol.

**Chto eto dajot Gemme** (prohod = karta 35,0 ms odin raz + processor 36,0 * obedinenie/8):

    K=4:  prohod 124,1 ms.  prinjato 4 -> 32,2 tok/s | 3 -> 24,2 | 2,5 -> 20,1 | 2 -> 16,1

**TOCHKA BEZUBYTOCHNOSTI - glavnoe chislo.** Nizhe nejo MTP delaet HUZHE, chem seichas (73,7 ms):

    K=2  nuzhno prinimat 1,27 iz 2  (63%)
    K=4  nuzhno prinimat 1,68 iz 4  (42%)
    K=6  nuzhno prinimat 1,99 iz 6  (33%)

Bolshoj K luchshe po OBOIM osjam srazu: i potolok vyshe, i trebovanie k dole prinjatyh nizhe.
Eto redkij sluchaj, kogda net kompromissa, i on prjamo govorit celitsja v K=4..6, a ne v K=2.

**Chto ostajotsja rabotoj.** `gpu_static.cpp:138` - kartochnyj put SOZNATELNO postroen pod
n_tokens == 1 ("Decode only, deliberately"). Processornye stroiteli grafov K tokenov uzhe umejut
(prefill imi i idjot), tak chto est rabochij etalon dlja sverki - rovno tot mehanizm, kotorym my
proverjali vsjo ostalnoe. Nuzhno: (1) vesa chernovika (v nashem GGUF ih net), (2) kartochnyj put na
K tokenov, (3) prijom/otkat s otkatom KV.

### Chernovik skachan i razobran: D:/mtp/MTP/mtp-gemma-4-26B-A4B-it-Q8_0.gguf

Iz `unsloth/gemma-4-26B-A4B-it-GGUF` - togo zhe repozitorija, otkuda nasha model. Arhitektura
`gemma4-assistant`, 49 tenzorov, 446 MB. Ne dvizhok, a VESA: nash dvizhok ostajotsja nash.

    4 bloka, n_embd 1024, n_ff 8192, okno [T,T,T,F] - povtorjaet risunok Gemmy
    token_embd  [1024, 262144] q8_0  285,2 MB   <- ETO OSNOVNAJA MASSA
    bloki       4 x ~35,7 MB          143,0 MB
    nextn.pre_projection  [5632,1024]   6,1 MB  <- styk so skrytym sostojaniem celi
    nextn.post_projection [1024,2816]   3,1 MB

**attn_k i attn_v OTSUTSTVUJUT sovsem** (`shared_kv_layers 4`): chernovik chitaet KV-kesh CELI, a
ne stroit svoj. Poetomu emu i ne nuzhen svoj prefill. U nas KV-kesh zhivjot na karte (gpu_static),
tak chto styk est.

**`output.weight` TOZHE otsutstvuet**: proekciej na slovar sluzhit tot zhe `token_embd`. Embedding
chitaet odnu stroku, a logity - vsju tablicu. Znachit na KAZHDYJ chernovoj token ~437 MB:
iz videopamjati 3,3 ms, iz hostovoj 17,6. **Chernovik objazan byt rezidentnym na karte.**

**Raschjot s prijomkoj 0,72** (chislo iz README unsloth, izmereno na B200 s target UD-Q4_K_M -
ih mnozhitel x1,62 k nam ne perenositsja, a dolja prijomki perenositsja). Cepochka obryvaetsja na
pervom otkaze, poetomu E = 1 + summa p^i:

    chernovikov  prohod    prinjato   itog
        1         96,7 ms    1,72     17,8 tok/s
        2        116,5       2,24     19,2
        3        134,0       2,61     19,5   <- plato
        4        149,5       2,88     19,3
        5        163,5       3,07     18,8

**~19,5 tok/s protiv nyneshnih 13,57, +44%.** Plato na trjoh chernovikah - dalshe marginalnyj
chernovik prinositsja rezhe, chem stoit svoih bajtov.

**Krizis mesta i pochemu on mjagche, chem kazhetsja.** 446 MB na karte, gde uzhe 2575 MiB
(vnimanie+KV) plus plotnaja FFN 542 MiB. Chto-to pridjotsja vyselit. No pri prohode na K tokenov
lyubaja vyselennaja rezidentnaja vesch chitaetsja raz na PROHOD, a ne na token: plotnaja FFN stoit
22,9 ms na prohod, to est pri trjoh chernovikah - 8,8 ms na token vmesto 22,9. **Spekuljativka
sama udeshevljaet svoi sobstvennye vyseleniya**, i eto nado uchest v vybore, chto derzhat.
Otdelnyj hod, esli mesta ne hvatit: perekvantovat `token_embd` chernovika v q4_K, 285 -> 151 MB.

**Rabota, kotoruju eto trebuet ot nas:** (1) zagruzchik arhitektury `gemma4-assistant`,
(2) kartochnyj put na K tokenov - `gpu_static.cpp:138` soznatelno postroen pod odin token,
(3) prijom/otkat s otkatom KV. Etalon dlja sverki est: processornye stroiteli grafov K tokenov
uzhe umejut, imi idjot prefill.

### IZMERENO VREMENEM: cena prohoda na K tokenov (MEMEX_SPEC_WIDTH, bench/spec_width.ps1)

Zond stroit grafy shiriny 1..6 rjadom s rabochim i gonjaet kazhdyj best-of-5. Vremja ustrojstva ne
zavisit ot znachenij (pravilo 73), poetomu kormim hvost promta.

**Pervyj zamer byl s primesju, i zond ejo sam pokazal.** Pri n_tokens > 1 kartochnyj put sloev
otklyuchaetsja SAM (`card = gstat && layers_on() && n_tokens == 1`), tak chto shirina 1 shla s
kartoj, a shiriny >1 - bez. Otnoshenie meshalo dva effekta. Kljuch -NoCard ubiraet kartu sovsem;
tolko eti chisla merjat perekrytie i nichego bolshe (vezde "sloi CPU", vezde 1650 uzlov):

    Gemma, chistyj kontrol        Kvin, chistyj kontrol
    K=1  133,38 ms  1,000          106,53 ms  1,000
    K=2  155,15     0,582          135,31     0,635
    K=3  188,07     0,470          157,95     0,494
    K=4  207,77     0,389          195,52     0,459
    K=5  243,78     0,366          221,18     0,415
    K=6  284,76     0,356          246,54     0,386

Prohod na 4 tokena stoit 0,389 ot chetyrjoh odinochnyh - **deshevle, chem predskazyval
marshrutizator** (0,618). Protivorechija net: granica po obedineniju otnositsja tolko k
EKSPERTNOMU chlenu, a vnimanie, plotnaja FFN i golova amortiziruyutsja polnostju.

Razlozhenie shoditsja s izvestnym bjudzhetom tokena i eto sverka, a ne podgonka:
    E(1) = 36,0 (eksperty), E(4) = 36,0 * 19,79/8 = 89,1
    A(1) = 133,4 - 36,0 = 97,4     A(4) = 207,8 - 89,1 = 118,7
    karta na K=1 ekonomit 133,4 - 69,8 = 63,6  =>  A_karta(1) = 33,8  ~= izvestnye 35,0 KARTA. OK.

**GLAVNYJ VYVOD, i on obratnyj tomu, chto ja govoril po modeli.** Bez perenosa kartochnogo puti
na K tokenov MTP delaet HUZHE:

    Gemma bez karty, D=3 chernovika, prijomka 0,72, E[prinjato] = 2,611
        207,8 / 2,611 = 79,6 ms na token = 12,6 tok/s   protiv nyneshnih 13,57  -- POTERJA

    S perenesjonnym kartochnym putjom (ocenka, karta ekonomit te zhe ~63,6 ms na prohod)
        (118,7 - 63,6 + 89,1) / 2,611 = 55,2 ms = ~18,1 tok/s  protiv 13,57  -- +33%

To est **perenos gpu_static na K tokenov ne "zhelatelen", a objazatelen**: on i est ves vygryш.
Ranshe ja ocenival 19,5 po modeli; izmerenie dajot ~18, i eto chislo teper opiraetsja na chasy.

Razbros: povtornyj progon toj zhe konfiguracii dal K=4 178,3 -> 182,7 (2,5%), no K=6 279 -> 217
(25%). **Shirinu 6 schitat ne izmerennoj**, K<=5 vosproizvodim.

## Kartochnyj sloj na K tokenov: hod raboty (nochnaja avtonomnaja sessija)

**Zachem** izmereno vyshe: bez perenosa MTP delaet huzhe (12,6 protiv 13,57), s perenosom ~18.

**Chto sdelano.** `layer_width` v konfige GpuStatic i flag `--gpu-static-width K`. Vosem
odnotokennyh mest vo vnimanii obobshcheny s VETVLENIEM po W, chtoby pri W == 1 sobiralsja tot zhe
kod, chto do MTP - verificirovannyj put nelzja bylo pravit na meste:

    reshape(q, hd, nh, 1)      -> W          reshape(k, hd, nkvh, 1)   -> W
    reshape(v, hd, nkvh, 1)    -> W          Kc: reshape -> permute(0,2,1,3)
    Vc: reshape -> permute(1,2,0,3)          Q:  reshape -> permute(0,2,1,3)
    kdst/vdst: ekstent 1 -> W                kqv: reshape_2d -> cont_2d(permute)

Plus: t_lx_/t_pos_/t_mask_ po shirine, maska strokami (ploskaja kopija tolko kogda stroka hosta
rovno nasha), sklejka vyhoda PO VELICHINAM ([ostatok x W][ffn_norm x W][pre_ffw_norm_2 x W]
[logity x W]) i takaja zhe narezka ggml_view_2d v grafe dekoda, pol bufera chtenija po sloju.

**Vstroena SVERKA, i ona sdelala vsju rabotu.** V razvjortke shirin stroitsja VTOROJ graf toj zhe
shiriny s gstat = nullptr, i logity sravnivajutsja poelementno v odnom processe na odnih vhodah.
Bezopasno po poriadku: kazhdyj graf pishet i chitaet tolko svoi pozicii n..n+K-1 plus promt.

**Chto ona pokazala, po poriadku - i eto zhurnal oshibok, a ne uspehov:**

  1. Pervyj progon: "konechnyh 0 iz 1048576" - vsjo nekonechno. Zond skazal NE SVERENO vmesto
     zeljonoj galochki, i eto edinstvennaja prichina, po kotoroj dalshe voobshche bylo chto iskat.
  2. Vtoroj progon toj zhe komandy: konechno, no L2 25,58%. **Nevosproizvodimost mezhdu
     odinakovymi progonami** - podpis chtenija neinicializirovannoj pamjati.
  3. Gipoteza "kartochnyj KV pust" - OPROVERGNUTA: upload_kv stoit na 7407, do razvjortki.
  4. Gipoteza "fail_msg_ otravljaet vsjo posle sebja" (do_layer zanuljaet vyhod i otvechaet
     nuljami na VSJO, vklyuchaja golovu) - pravdopodobna po mehanizmu, no `failure()` PUST.
  5. Postrochnaja sverka dala L2 = -1 na vseh strokah, chto znachit nulevoj ZNAMENATEL, to est
     nulevoj ETALON. Pechat kazhdoj storony otdelno (summa kvadratov, NaN, Inf, nuli) - vot chto
     nado bylo sdelat pervym: bez nejo "L2 -1" odinakovo vygljadit dlja "etalon nulevoj" i
     "sravnivat nechego".
  6. S MEMEX_SPEC_LOCATE zondy delajut NaN OBE storony - **lokalizator lomaet to, chto merit.**
  7. **NAJDENA PRICHINA:** `graf sloja: 38 uzlov` pri shirine 4 - stolko zhe, skolko pri shirine 1.
     Znachit `cfg_.layer_width` vnutri build_layer_graphs raven EDINICE, i karta schitaet odin
     token tam, gde graf dekoda podajot chetyre. Pri etom `layer_width()` snaruzhi vozvrashchaet 4
     (inache karta ne vzjalas by za K=4) - to est shirina doshla do ACCESSORA, no ne do
     POSTROITELJA. Dobavlena samoidentifikacija `LAYER_WIDTH %d` v stderr (pravilo 68).

**Sostojanie: put ne verificirovan, vklyuchat nelzja.** Flag `--gpu-static-width` sushchestvuet i
karta na njom ne padaet, no dajot drugoj otvet. Znachenie po umolchaniju 1, poetomu vsjo
ostalnoe rabotaet kak ranshe.

## NAJDEN REALNYJ DEFEKT: harness nikogda ne zapolnjal mask_swa i seq_ids

`set_inputs` v harnesse (`--gen`) byl UREZANNOJ kopiej svobodnoj `set_graph_inputs`: zapolnjal
tokeny, pozicii i `mask`, no NE `mask_swa` i NE `seq_ids`. U qwen3moe okonnoj maski net, poetomu
defekt nikogda ne projavljalsja. **U gemma4 dvadcat pjat sloev iz tridcati chitajut imenno
mask_swa** - i chitali to, chto ostalos v bufere.

Priznak, kotoryj ja polnocha prinimal za oshibku v perenose kartochnogo sloja: **odinakovye
progony davali to NaN, to konechnye no nevernye chisla.** Eto i byl neinicializirovannyj bufer.

Ispravleno: lambda harnessa teper zovjot `set_graph_inputs` - tu samuju funkciju, kotoraja i byla
sdelana svobodnoj so slovami "three callers need identical bytes". Posle etogo vsjo stalo
determinirovannym: pereborka dajot bitovo te zhe cifry.

**CHTO ETO ZNACHIT DLJA PROSHLYH CIFR.** Skorost - eto skorost: te zhe operacii nad temi zhe
bajtami, poetomu 13,57 tok/s i vsja tablica bjudzheta tokena v sile. No **ljuboe utverzhdenie o
KORREKTNOSTI gemma4, poluchennoe cherez vetku --gen, nedejstvitelno** - tam v okonnoj maske byl
musor. Zondy "vse 0,0000%" byli polucheny odnorazovym sravneniem v main (ono zovjot
set_graph_inputs), a ne harnessom, tak chto oni ostajutsja v sile. Qwen ne zatronut voobshche.

## Kartochnyj sloj na K tokenov: gde ostanovilos

Sverka vstroena v razvjortku: vtoroj graf toj zhe shiriny s gstat = nullptr, poelementno, v odnom
processe. Kazhdaja stroka tablicy teper zaverjaet sebja sama (NaN/Inf/summa kvadratov) - bez etogo
ja pol nochi pechatal otnoshenija, ne prochitav vyhod ni razu.

**Kontrol pri shirine 1 - vot chto dalo otvet.** Karta protiv processora RASHODITSJA i pri shirine
odin: attn_out-0 20,5%, logity 5,57%. Znachit takie chisla NORMALNY dlja karty (fused_rms_norm ne
bitovo raven pare rms_norm+mul, kesh f16), i pravilnyj vopros - ne "nol li L2", a "to zhe li ono
pri shirine 4":

                  logity     stroka 0
    shirina 1     5,57%      5,57%
    shirina 4    10,91%      5,53%   <- stroka 0 SOVPALA s bazoj
                             stroki 1..3: 23,71%, 5,64%, 10,38%

**Stroka 0 verna, ostalnye degradirovali.** Po sobstvennomu razlichajushchemu pravilu eto maska,
pozicii ili zapis v kesh - NE forma i ne perestanovka. Otdelno proverено i OPROVERGNUTO: `ggml_cont`
vokrug trjoh perestanovok (kak v etalone) ne izmenil rezultat NI NA BIT, to est Vulkan neplotnyj
istochnik obrabatyval verno.

Vremja pri shirine 4 s kartoj: prohod 149,2 ms, 37,3 ms na token, otnoshenie 0,344.

**Sostojanie: --gpu-static-width po umolchaniju 1, put ne verificirovan, vkljuchat nelzja.**
Sledujushchij shag nazvan: stroki 1..3 - maska, pozicii ili zapis v kesh.

### Instrumenty, dobavlennye za noch
    MEMEX_SPEC_WIDTH=K   razvjortka ceny prohoda 1..K so samozaverkoj kazhdoj stroki
    MEMEX_SPEC_ALLLOG=1  logity vseh strok (inache tolko poslednjaja)
    MEMEX_SPEC_LOCATE=1  sravnenie zondov po imeni - nazyvaet stadiju i sloj
    --gpu-static-width K shirina kartochnogo grafa sloja
    bench/spec_width.ps1 (-NoCard dlja chistogo kontrolja), bench/mtp_overlap.ps1
    bench/sleep_watchdog.ps1 + D:/MemeX/results/.no-sleep kak vykljuchatel

### Popravka k predydushchemu abzacu i GLAVNYJ vyvod ob etalone

Shirina 2 dala stroku 0 = 12,24% i stroku 1 = 6,65%. Znachit "stroka 0 verna, ostalnye net" bylo
SOVPADENIEM pri shirine 4, a ne priznakom: rashozhdenie rastjot s shirinoj i zadevaet vse stroki.
Vyvod pro "masku, pozicii ili zapis v kesh" na etom osnovanii - snjat.

**I tut vidno defekt v samoj postanovke, moj.** Ja vsju noch schital processornyj graf shiriny > 1
ETALONOM. On ni chem ne vyveren: pri n_tokens > 1 ego gonjaet tolko prefill (a tam n_past = 0,
to est net ni odnoj prochitannoj iz kesha pozicii) i `build_verify` spekuljativnogo dekodera,
kotoryj sam nikogda ne proverjalsja protiv tokenov. Sravnivat kartu s nim - eto sravnivat dva
neproverennyh puti i nazyvat raznicu oshibkoj odnogo iz nih.

**Nastojashchij etalon nazvan i on samodostatochen: CHETYRE POSLEDOVATELNYH SHAGA po odnomu
tokenu objazany dat te zhe logity, chto odin prohod na chetyre.** Eto ne tolko pravilnaja sverka -
eto ROVNO to uslovie, na kotorom stoit spekuljativnoe dekodirovanie. Esli ono ne vypolnjaetsja,
lomaetsja ne kartochnyj put, a vsja zateja.

Poetomu sledujushchij shag - ne iskat dalshe v kartochnom vnimanii, a postroit etu sverku:
K odinochnyh shagov protiv odnogo prohoda shiriny K, SNACHALA na chistom processornom puti
(bez karty vovse). Ona skazhet, kotoryj iz dvuh putej voobshche neveren.
