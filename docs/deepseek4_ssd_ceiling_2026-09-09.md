# DeepSeek-V4-Flash (deepseek4, 90 GB UD-IQ2_XXS) na SSD: potolok dekoda i optimalnyj konfig

Data: 9-10 sentjabrja 2026. Zhelezo fiksirovano: 8 jader, OZU 32 GB (~27 GiB svobodno), polosa OZU
14.8 GB/s, SSD C: 0.46 GB/s (SATA-klass), RX 6500 XT 4 GB. Model skopirovana na C:. Vetka koda:
`agent/ds4-ssd-opt` (worktree `D:/MemeX/src/ik_llama.cpp/.claude/wt_ssdopt`), 2 kommita poverh
baseline 4d692b04, ~750 strok, vsjo flag-gated, NE sobrano i NE zamereno mnoj (sborki/zamery -
u koordinatora). Chisla nizhe - tolko izmerennye 9 sentjabrja plus arifmetika ot nih.

## 1. Izmereno (istina)

| plecho (tokens 8, gen 16, holodno)                | tok/s | promahov/tok | ms/promah | primechanie |
|---------------------------------------------------|-------|--------------|-----------|-------------|
| mmap, bez stora                                    | 0.62  | ? (~60-80)   | ~14-20    | 2.3M page-faultov/fazu, 1613 ms/tok |
| stor C=48(+16 zap.), bez predzagruzki             | 0.233 | 67.4         | 48        | 3241 ms sinhr. iz 4286 |
| stor C=48(+22), identity-R1 K=2 B=16 + recency-gate | 0.106 | 32.1       | 44        | 263 chtenij/tok, 43.6 ispolzovano, 219 VPUSTUJU |

## 2. Fizika (pochemu tak i chto vozmozhno)

Geometrija: 43 MoE-sloja x 256 ekspertov x 7.19 MiB = 77.3 GiB ekspertov (83 GB); ostalnoe
fajla ~7.9 GB = statika (MLA/router/obshchij ekspert/golova/embed) - i ona chitaetsja KAZHDYJ
token celikom (~7 GB minus embed). Na token: 258 ekspertov x 7.19 MiB = 1.81 GiB routed + ~7 GB
statiki.

Nizhnjaja granica CPU (vsjo v OZU): (7 + 1.9) GB / 14.8 GB/s ~ 0.6 s/token => **~1.6 tok/s -
absoljutnyj potolok na etom CPU dazhe s beskonechnym diskom.** Golova na karte srezaet ~70 ms,
statika-na-karte ne vlezaet (7 GB > 3.8 GB VRAM) i dlja MLA/hyper-connections kartochnogo bloka net.

Stena OZU: pod eksperty ostajotsja ~19-21 GiB (32 - statika 7.4 - OS/KV/compute ~3). Eto 26-27%
ekspertov - i u mmap (page-cache), i u stora (C+Z = 70 slotov/sloj = 21 GiB). **Pokrytie u nih
ODINAKOVOE po postroeniju; podnjat C vyshe 48+22 nelzja - statika pojdjot s diska** (auto-C=60 pri
"svobodno 27 GiB" - eto trjoshing, ispravleno: statika teper v zapase auto-C).

Stena SSD: promah = 7.19 MiB / 0.46 GB/s = 15.6 ms pri polnoj polose. Pri dole popadanij h vremja
diska = (1-h) x 258 x 15.6 ms = (1-h) x 4.0 s. Bez perekrytija s chjotom: T = 0.6 + (1-h)x4.0.
h=74% (izmereno u stora) => 1.65 s => 0.61 tok/s = ROVNO mmap. S idealnym perekrytiem
T = max(0.6, (1-h)x4.0): h=74% => 1.05 s => 0.95 tok/s; h=85% => 0.6 s => 1.6 tok/s.

Pravilo 50%: na diske, ogranichennom polosoj, kazhdoe chtenie predzagruzki VPUSTUJU stoit stolko
zhe, skolko promah. Predzagruzka okupaetsja tolko esli P(ispolzovan) > 0.5 na KAZHDOE vydannoe
chtenie. Identity-R1 dal 43.6/263 = 16.6% => proigrysh (0.106 izmereno). Trenirovannyj R1
x1.5 => ~25% - vsjo eshchjo proigrysh, esli ne ogranichit ochered. Otsjuda konfig nizhe: R1 tolko
dlja top-4 po uverennosti + predel ocheredi + tochnaja (100%) hash-predzagruzka.

Pochemu stor proigryval mmap pri ravnom pokrytii: 48 ms/promah protiv ~15 - sinhronnoe chtenie
trjoh kuskov po odnomu s glubinoj ocheredi 1 (~150 MB/s), a mmap fol'tit s 8 potokov (QD 8) i
poluchaet polosu diska. Eto ustranjaet `--expert-store-miss-batch` (OVERLAPPED, QD do 18).

## 3. Chto sdelano v kode (vetka agent/ds4-ssd-opt), vsjo flag-gated

Kommit b3d52d62:
- `--expert-store-miss-batch` - promahi sloja odnim paketom (OVERLAPPED|NO_BUFFERING, 3 x top-k
  chtenij v ocheredi). Te zhe smeshchenija/dliny => bit-v-bit. Ozhidanie: 48 -> ~16-20 ms/promah,
  stor 0.233 -> ~0.45-0.55 (pri toj zhe dole popadanij), t.e. paritet s mmap, ne pobeda.
- `--prefetch-hash` - u deepseek4 3 hash-sloja vybirajut ekspertov tablicej po id tokena; posle
  sampla eksperty sledujushchego shaga izvestny TOCHNO -> v I/O-potok do grafa. 0 vpustuju.
  Vklad ogranichen: 18 iz 258 obrashchenij/token (7%).
- `--prefetch-inflight N` - predel ocheredi R1-chtenij (sinhronnye promahi ne zhdut za predzagruzkoj).
- `--expert-store-auto` uchityvaet statiku pod mmap; pri javnom C - preduprezhdenie s predelom.

Kommit (sledujushchij, "#2"):
- `--mmap-touch` / `--mmap-touch-hash` - dlja PUTI-POBEDITELJA (mmap): uzel mezhdu top-k i
  mul_mat_id prosit OS zachitat stranicy TOCHNO vybrannyh ekspertov celikom (PrefetchVirtualMemory,
  18 diapazonov, asinhronno) vmesto ~1800 4-KiB faultov na ekspert. Tot zhe page-cache, ta zhe
  LRU, bajty te zhe. Eto prjamo bjot v "2.3M faultov/fazu". -hash: + hash-sloi sledujushchego tokena.
- `--gpu-static` dlja deepseek4 (tolko golova; POPRAVKA po GGUF: output.weight = Q4_K 129280x4096
  ~300 MB, ne 1 GB => vyigrysh ~20 ms/token, ~1.3%; argmax-check).
- `--prefetch-depth D --prefetch-deep-hi N` - celi il+K+1..il+K+D, top-N kazhdaja (fora 3-5 sloev).

NE sdelano i pochemu:
- VRAM-jarus ekspertov (IQ2_XXS mul_mat_id na Vulkan): schjot ekspertov na CPU - ~130 ms/token iz
  1600, karta uskorit dolju popadanij v jarus (~30%) => ~40 ms; plus osvobodit ~3 GB OZU (+4%
  pokrytija). Sumarno <5% - ne stoit grafovoj hirurgii (razdelenie sel na kartu/CPU, dva mul_mat_id).
- Holodnyj hvost menshego kvanta: menjaet bajty (tolko argmax-check) I na C: svobodno 16.8 GB -
  kopii 50-77 GB polozhit nekuda; D: - HDD 0.07 GB/s, huzhe SSD.
- Statika na kartu (7 GB) - ne vlezaet v 3.8 GB, i u MLA/mHC net kartochnogo bloka; eto mnogonochnyj port.

## 4. Optimalnyj konfig (obosnovannyj prognoz, PROVERIT zamerom)

Plecho A - mmap + touch (kandidat v pobediteli, nol riska otvetu):
    llama-memex-fwd -m <shard1> -f prompt --tokens 32 --gen 48 -t 8 -c 256 --no-repack --no-ref \
      --mmap-touch-hash [--gpu-static]
  Ozhidanie: 0.62 -> 0.7-0.85 (ubiraem fault-overhead i podnimaem QD na promahah; golova -70 ms).

Plecho B - stor s paketom, bez R1 (paritet s mmap, no upravljaemyj):
    ... --expert-store 48 --expert-store-decay 0.9 --expert-store-miss-batch --prefetch-hash
  Ozhidanie: 0.233 -> ~0.5-0.6 (48 -> ~16-20 ms/promah). C ne vyshe 48 (statika!).

Plecho C - stor + tochnostno-ogranichennyj R1 (edinstvennyj shans obojti mmap zametno):
    ... --expert-store 48 --expert-store-decay 0.9 --expert-store-miss-batch --prefetch-hash \
        --expert-prefetch r1_trained_k2.bin --prefetch-budget 16 --conf-hi 4 --conf-lo 16 \
        --prefetch-recency-gate 0.5 --prefetch-inflight 12 [--prefetch-depth 2 --prefetch-deep-hi 2]
  Ozhidanie: esli tochnost top-4 trenirovannogo R1 na NErezidentnyh > 50% - 0.7-0.9; inache
  ne luchshe plecha B. Reshaet kalibrovka (razdel 5), ne vera.

## 5. Kalibrovka -> obuchenie -> A/B (komandy)

1. Damp par (K=2 iz zagolovka identity-fajla; budget 0 = tolko zapis, SSD ne tratitsja):
    llama-memex-fwd -m <shard1> -f prompt --tokens 32 --gen 128 -t 8 -c 256 --no-repack --no-ref \
      --expert-store 48 --expert-store-decay 0.9 --expert-store-miss-batch \
      --expert-prefetch C:/Users/User11/.claude/jobs/a547d6bd/tmp/ds4_r1_identity.bin \
      --prefetch-budget 0 --prefetch-calib bench/ds4_ssd_opt/calib_k2.bin
   (identity-fajl: n_layer 43, n_in 257, n_out 256, K 2; sloi s parami: tgt 3..42 = 40 x 128 = 5120 par)
2. Obuchenie (numpy est):
    py bench/fit_prefetch_calib.py inspect --calib bench/ds4_ssd_opt/calib_k2.bin --budgets 2,4,6,8,16
    py bench/fit_prefetch_calib.py fit --calib bench/ds4_ssd_opt/calib_k2.bin \
       --out bench/ds4_ssd_opt/r1_trained_k2.bin --method ce --mu 2.0 --steps 300 --lr 0.02 \
       --holdout 0.25 --min-samples 24 --budgets 2,4,6,8,16 --main-budget 6 --decay 0.9 --gammas 0,0.5,1,2
   Chitat: "ispolzovano/predskazano" pri B=4 dlja obuchennogo - eto tochnost top-4. > 0.5 =>
   --conf-hi 4 okupaetsja; inache --conf-hi 2 ili R1 vykl (ostavit tolko hash + paket).
   Pri 128 tokenah u sloja ~96 par na 257x256 vesov - Wc uchit v osnovnom smeshchenie (exp_probs_b,
   kotorogo identity ne znaet); eto i est glavnyj sistematicheskij progal identity-R1 u deepseek4.
3. A/B odnoj seriej pod zamkom: mmap | mmap+touch | stor+paket | stor+paket+hash | stor+R1-trained
   (skript-obrazec: scratchpad run_ds4.ps1 etoj sessii; loga - bench/ds4_ssd_opt/).

## 6. Chestnyj verdikt

- Na ETOM zheleze potolok deepseek4 - **~0.6-1.0 tok/s**. 0.62 (mmap) - uzhe 60-100% ot nego.
  Bolshe 1.0 trebuet libo h > 85% (nevozmozhno pri 27% ekspertov v OZU bez tochnogo predskazatelja),
  libo drugogo zheleza: 64 GB OZU (h -> ~95%, T -> 0.6-0.8 s => 1.3-1.6 tok/s, potolok CPU) ili NVMe
  3+ GB/s (promah 2.4 ms => T ~ 0.6 + (1-h)x0.6 => ~1.3-1.5 tok/s).
- Stor MOZHET dognat mmap (paket promahov) i obojti ego tolko pri predzagruzke s tochnostju > 50%
  na nerezidentnyh - eto reshaet kalibrovka, i ja by ne obeshchal bolshe +20-30%.
- Samyj deshjovyj vyigrysh s nulevym riskom otvetu - `--mmap-touch-hash` na puti-pobeditele:
  ubiraet imenno tot fault-overhead, kotoryj nazvan uzkim mestom mmap. Ego i merit pervym.
- Otvet ne menjaetsja ni odnoj iz pravok stora/predskazatelja (oni vybirajut, CHTO i KOGDA
  chitat v zapasnoj slot, a ne KAKOJ ekspert schitaetsja); edinstvennoe isklyuchenie - golova na
  karte (porjadok summirovanija f32) - argmax-check.

## 7. SP-MoE (spekuljativka x async-prefetch x stor na verify-batche): fakty, fizika, plan

FAKT 1 (GGUF, header-only skan trjoh shardov 10 sent): MTP/nextn-golovy v etom kvante NET.
43 bloka (blk.0..42), 1328 tenzorov, net KV nextn_predict_layers, net eh_proj/shared_head/
enorm/hnorm; vne blokov tolko output.weight (Q4_K), output_hc_*, output_norm, token_embd (Q4_K).
Unsloth pri konvertacii MTP-modul vybrosil. => drafta iz sobstvennyh vesov net.
FAKT 2 (kod): load_draft (memex-fwd.cpp ~6621) prinimaet TOLKO qwen3-dense s tem zhe slovarjom;
u DeepSeek vocab 129280 (svoj BPE) - chuzhoj melkoj modeli s etim slovarjom net. => edinstvennyj
draft - self-speculative (n-gram / prompt-lookup po kontekstu), bez modeli, bez idle-okna I/O.
FAKT 3 (kod): spekuljativnyj cikl zhivjot v generate() (~6236-6462, Generator::build_verify/verify
~5180-5226) - eto put --chat/--predict, a zamer deepseek4 idjot cherez cikl --gen (~11030-11066)
bez spekuljacii; stor peredajotsja tolko grafam shiriny 1 (Generator::es, BuildOpts.es v dbo).
FAKT 4 (kod): do_map UZHE schitaet union po strokam batcha (vtoroe pojavlenie id v tom zhe uzle -
popadanie), t.e. "kazhdyj ekspert chitaetsja raz na batch" - vstroeno; ne hvataet: (a) zapasnyh
slotov >= n_used*W + B, (b) do_prefetch chitaet pred_logits kak odnu stroku [n_expert] - dlja
W strok nuzhen cikl po ne[1], (c) end_token odin raz na raund (drain+refresh), (d) es v verify-graf.

FIZIKA na SSD, ogranichennom polosoj (chisla 9 sent: h=74%, promah 15.6 ms pri polnoj polose,
statika+plotnyj schjot ~0.6 s/token):
  raund shiriny W=K+1: T = 0.6 (statika chitaetsja RAZ na raund - eto i est amortizacija)
                         + (1-h) x U x 15.6 ms, U = objedinenie ekspertov batcha po vsem slojam.
  Dlja MoE 6-iz-256 holodnye eksperty sosednih tokenov pochti ne peresekajutsja (peresekajutsja
  gorjachie, a oni i tak rezidentny) => U ~ W x 258 - malo => diskovye bajty NA RAUND rastut ~W.
  Vydano tokenov za raund pri verojatnosti prinjatija a: E = (1-a^(K+1))/(1-a).
  K=3: a=0.9 => E=3.44, T ~ 0.6 + 0.26x~900x15.6ms = 4.3 s => 1.25 s/tok => ~0.8 tok/s (LUCHSHE 0.62);
       a=0.6 => E=2.18 => 1.97 s/tok => 0.51 (HUZHE); a=0.3 (n-gram na svobodnom tekste) => E=1.4
       => 3.0 s/tok => 0.33 (SILNO HUZHE).
  Vyvod: SP-MoE okupaetsja tolko pri a >= ~0.8, t.e. s nativnoj MTP-golovoj (85-90%), kotoroj v
  etom GGUF net. S n-gram-draftom - chistyj proigrysh: otvergnutye stroki batcha - eto realnye
  bajty s SSD vpustuju, a SSD i est uzkoe mesto. Idle-okna I/O u n-gram-drafta net (draft - mks).
  Chto proverit PEREd ljubym kodom (nol koda, 1 progon): MEMEX_MTP_OVERLAP=1 na prefille
  (memex-fwd.cpp ~9998) pechataet objedinenie/serial dlja K=2..6 - esli otnoshenie pri K=4
  <= 0.5, amortizacija diskovyh bajtov realna i raschjot vyshe slishkom pessimistichen.

PLAN (esli vsjo zhe delat; fajly/tochki), v porjadke cennosti:
  P0. Zamer MEMEX_MTP_OVERLAP na deepseek4 (bez koda). Reshaet, est li chto amortizirovat.
  P1. Stor na grafah shiriny W (expert_store.cpp): do_prefetch - cikl po strokam pred_logits
      (ne[1]); make_store - spares >= n_used*W + B pri --draft-max; end_token() posle verify()
      (Generator::verify ~5219 i generate ~6360), a ne posle kazhdogo emit; MMAP-touch tozhe
      ok dlja n_tokens>1 (snjat uslovie n_tokens==1 v build_deepseek4_step ~3403).
      Eto zhe dajot STOR NA PREFILLE kuskami (sejchas prefill idjot cherez mmap i vymyvaet
      page-cache/statiku 58 GB na 32-tokennyj promt) - polezno nezavisimo ot SP-MoE.
  P2. Spekuljacija v puti --gen (memex-fwd.cpp ~11030): segodnja draft/verify tolko v generate();
      libo perenesti cikl --gen deepseek4 na generate() (Generator + BuildOpts.es/mt dlja
      shiriny W), libo vstroit verify-batch v cikl --gen. Ob'jom: srednij, 150-250 strok.
  P3. Self-speculative draft (novyj modul ~80 strok, sampler.hpp rjadom): prompt-lookup -
      poslednie n=3..2 tokena ishchutsja v kontekste, predlagajutsja K sledujushchih; bez modeli.
      Verifikacija - celevoj model, tochnost otveta ne menjaetsja (Leviathan/Chen, kak sejchas).
  P4. Tochnyj prefetch hash-sloev dlja VSEGO batcha (id vseh W tokenov izvestny do grafa):
      prefetch_token(batch, W) - 10 strok poverh prefetch_token.
  Chego NE delat: R1-prefetch "v okne drafta" - okna net (n-gram draft mgnovenen), a s modelnym
  draftom net slovarja.
REKOMENDACIJA: P0 -> esli overlap slabyj (ozhidaju), SP-MoE na etom zheleze zakryt raschjotom
(a>=0.8 nedostizhimo bez MTP-golovy). Sily - na zamer uzhe zakommichennyh flagov
(--mmap-touch-hash, --expert-store-miss-batch, --prefetch-hash) i kalibrovku R1 (razdel 5).
