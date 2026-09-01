
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
