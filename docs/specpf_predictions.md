# Predskazanija do zamera - uchenyj predskazatel rezidentnogo nabora (SpecPrefetch)

Zapisano do togo, kak byl zapushchen hotja by odin zamer. Data: 2026-08-31.

## Chto uzhe najdeno na diske (do sbora dannyh)

- `D:\MemeX\results\tr_act.bin` (856 MB, 20 avgusta) UZHE soderzhit rovno tu paru, kotoruju
  trebuet SpecPrefetch: uzel `ffn_inp_normed` [2048, n_tok] - vhod marshrutizatora - i
  `ffn_moe_topk` [8, n_tok], dlja vseh 48 sloev, 1110 tokenov (batchi 512/512/86).
  Kazhdaja aktivacija zapisana DVAZHDY (prefiks imeni sovpal s tenzorom i s ego f32-kopiej
  posle ggml_cast) - zapisi pobitovo odinakovy, brat kazhduju vtoruju.
- `tr_p_code.bin` / `tr_p_ru.bin` / `tr_p_en.bin` - polnye raspredelenija marshrutizatora
  (uchitel iz statji), no BEZ skrytyh sostojanij. Odnogo fajla s oboimi net.

## Parametrizacija iz statji (prochitana, ne ugadana)

    z_hat^{l+1} = B A X^l,   A in R^{r x D},  B in R^{E x r},  oba OBSHCHIE dlja vseh sloev
    P_hat = softmax(z_hat);  uchitel P_T^{l+1} = softmax(X^{l+1} Wg^{l+1 T})
    L = mean_l mean_tok KL(P_T || P_hat)
    AdamW, lr 1e-4, cosine, warmup 0.03, clip 0.5, bf16, ODNA epoha
    r ne nazvan; 12.95M parametrov na Qwen3-VL-MoE-30B, 1.63M na DeepSeek-VL2-Tiny

## Predskazanija

**P1. Signal est.** Linejnoe otobrazhenie iz skrytogo sostojanija sloja L v ocenki ekspertov
sloja L+1, podognannoe POSLOJNO, sushchestvenno pobjot chastotnye bazovye linii.
Ozhidaju R@8 = 45-65%, R@16 = 70-85%, R@24 = 82-92% na otlozhennyh tokenah.
Osnovanie: ostatochnyj potok nepreryven, X^{l+1} = X^l + delta, a marshrutizator - linejnaja
funkcija ot X^{l+1}. Staryj otricatelnyj zamer (6.0% protiv pola 6.25%) meril ID protiv ID.

**P2. Tochnaja forma iz statji - OBSHCHIJ B - u nas provalitsja.** Odno otobrazhenie 2048->128
na vse 47 perehodov dast R@16 v predelah +-5 punktov ot chastotnoj bazovoj linii, to est
priblizitelno 45-55%. Osnovanie: nash sobstvennyj zamer - indeks eksperta znachit raznoe v
kazhdom sloe, i puling sloev razrushaet strukturu, a ne dobavljaet dannyh.

**P3. Obshchij A + poslojnyj B** budet v predelah 3 punktov ot polnogo poslojnogo linejnogo
otobrazhenija pri r >= 64. Uzkoe mesto ranga zdes ne svjazyvaet.

**P4. Dannyh malo.** 1110 tokenov protiv 262k parametrov na sloj - poslojnaja podgonka
pereobuchitsja: zazor mezhdu train i test bolshe 10 punktov po R@16 bez regularizacii.
Ridge objazatelen. Poetomu sbor novyh trass vsjo ravno ponadobitsja.

**P5. Naivnaja forma politiki ne oplachivaetsja.** "Perevybirat top-C predskazatelem kazhdyj
tokjen" dast 3-6 zamen na sloj na tokjen, to est 150-290 podkachek na tokjen pri C=16 protiv
6.9 segodnja. Pri 0.637 ms PCIe kazhdaja eto 95-185 ms na tokjen pri tokene v 61 ms. To est
poleznaja forma - eto sglazhennaja ocenka s ogranicheniem na chislo podkachek.

**P6. Reshajushchee chislo - popadanija pri RAVNYH podkachkah.** Ozhidaju +5...+15 punktov nad
recency-weighted LFU pri ravnom chisle podkachek okolo rabochej tochki (~2 podkachki na tokjen,
period 32). **Esli menshe +4 punktov - rabotu v dvizhke delat ne stoit**, potomu chto izmerennyj
kurs 2.25 punkta popadanij = 1.55 tok/s, a porog shuma 4.2%.

**P7. Skorost, esli P6 sjadet na +10 punktah.** Kurs iz zadaniia: ~22 punkta popadanij = ~7 ms =
~2 tok/s, to est 0.09 tok/s na punkt. +10 punktov = +0.9 tok/s = 16.4 -> 17.3, okolo +5.5%.
Eto tolko-tolko vyshe vnutrisessionnogo pola v 4.2%.

**P8. Domennyj sdvig.** Predskazatel, obuchennyj na kode, poterjaet na russkom menshe, chem
teorjaet chastotnyj nabor (izmereno: 24.1% protiv 25.0% u sluchajnogo), potomu chto on chitaet
soderzhimoe tokena, a ne ego istoriju. Ozhidaju poterju menshe 10 punktov pri perenose kod->ru.

---

# Vtoroj nabor predskazanij: gorizont, tokjennyj zapas, golosovanie

Zapisano do zapuska sootvetstvujushchih plech.

## Popravka k razlozheniju ceny podkachki (do predskazanij, potomu chto oni na njom stojat)

Hodili DVA nevernyh razlozhenija 1,30 ms, i oba nado bylo zamenit odnim iz STATE:

    chtenie read_plain (mmap -> zakreplennaja pamjat)  0,10 ms   2,51 MB / 24,8 GB/s
    PCIe                                              0,64      2,51 MB / 3,94 GB/s
    submit + zabor                                    0,10      IZMERENO raznostju: shest
                                                                podkachek pod odnim zaborom
                                                                dali 1,300 -> 1,196
    NEIZVESTNO                                        0,46      edinstvennyj nezamerennyj chlen
                                                      ----
                                                      1,30      izmereno na generacii

**P9 (ne predskazanie, a popravka).** Pol ceny podkachki ne 0,333 i ne 0,949, a **ot 0,10 do
0,56 ms**, i vilka celikom v tom, komu prinadlezhat neizvestnye 0,46. Znachit okupaemost
podkachki **ot 1,0 do 5,9 obrashchenij**, a ne 3,5. Nizhnij konec menjaet vyvod kachestvenno:
pri 1,0 obrashchenii dazhe potokjennaja podkachka okupaetsja, i togda tochnost predskazatelja
stanovitsja obnalichivaemoj. Ostatok 0,46 - eto teper samyj cennyj neizmerennyj chlen proekta.

## Predskazanija

**P10. Krivaja po TOKJENNOMU zapasu.** Predskazanie ekspertov sloja j na tokene t+d po skrytomu
sostojaniju tokena t. Zhdu R@16: d=0 80%, d=1 62-66%, d=2 58-62%, d=3 56-60%, d=5 54-58%,
d=8 52-56%. To est rezkij obryv na PERVOM tokene i pochti ploskuju krivuju dalshe. Osnovanie:
vnutri tokena predskazyvaetsja sostojanie, kotoroe uzhe pochti izvestno; cherez tokjen ostajotsja
tolko lokalnaja tema, a ustojchivost vybora po k izmerena ploskoj (47,8% na k=1, 52,3% na k=20).
Pol krivoj dolzhen byt VYSHE staticheskoj chastoty (45,9%), potomu chto skrytoe sostojanie
nesjot lokalnuju temu, kotoroj u chastotnoj tablicy net.

**P11. Golosovanie k iz m protiv odnogo vystrela.** Pri RAVNOM chisle podkachek golosovanie dast
+1...+3 punkta. Ne bolshe: sglazhennaja ocenka - eto uzhe pochti to zhe, chto chastotnoe okno, a
predema97 izmerena kak ravnaja LFU. Esli golosovanie dast bolshe +4, ja oshibsja imenno v tom,
chto schital sglazhivanie i golosovanie odnim priemom.

**P12. Kontrol peremeshivaniem - eto glavnoe plecho, i ja zhdu, chto ono ubjot gorizont.**
Pri gorizonte K=32 ocenka na peremeshannyh skrytyh sostojanijah budet v predelah **3 punktov**
ot nastojashchej, to est gorizontnyj predskazatel okazhetsja chastotnoj tablicej v shljape.
Pri K=1 razryv budet bolshoj (bolshe 25 punktov). Perelom zhdu okolo K=8.
Osnovanie: objedinenie vyborov za 32 tokena - eto 36 ekspertov iz 128 (izmereno), to est pochti
tret vseh, i ono pochti ne zavisit ot togo, s kakogo tokena okno nachalos.

**P13. Sledstvie, esli P12 podtverditsja.** Togda u zadachi net "predskazatelja rezidentnogo
nabora" vovse: est tochnyj MGNOVENNYJ predskazatel (80% na svojom tokene) i chastotnaja tablica
na vsjo, chto dalshe odnogo tokena. I edinstvennoe, chto reshaet, - stoit li podkachka 0,10 ms
ili 1,30.

---

# P12 OPROVERGNUTO. I eto tretje oprovergnutoe predskazanie v etoj zadache.

**Da, eto tot samyj eksperiment.** Kolonka "gorizont" v `horizon_code.txt` - eto K iz
`fut_counts(ids, T, E, K)`, to est schjot vyborov sloja j po tokenam t..t+K-1. Imenno o njom
bylo P12. Dvusmyslennosti mezhdu dvumja dokumentami net; est prosto nevernoe predskazanie.

Predskazano: pri K=32 peremeshannoe v predelah **3 punktov** ot nastojashchego, perelom okolo K=8.
Izmereno (C=16):

    K      ocenka   peremeshan   razryv     chastota   ocenka - chastota
    1      80.22%     32.68%      47.5       42.43%        +37.79
    8      59.78%     37.28%      22.5       42.43%        +17.35
    16     54.54%     37.44%      17.1       42.43%        +12.11
    32     50.78%     38.77%      12.0       42.43%         +8.34
    64     48.48%     39.29%       9.2       42.43%         +6.04

Razryv suzhaetsja s K, kak ja i govoril, no k K=32 on **12 punktov, a ne 3**, i nikakogo
pereloma na K=8 net - tam 22,5. **P12 oprovergnuto, i P13 iz nego ne sleduet.**

**Ukazanie koordinatora, kotoroe ostree moego sobstvennogo chtenija.** Peremeshannoe sidit
**NIZHE** chastotnoj bazovoj linii pochti vezde (37,28 protiv 42,43 pri K=8, C=16). Model,
vyuchivshaja tolko chastotu, sovpala by s chastotnoj tablicej, a ne provalilas pod nejo. Proval
znachit, chto vhodozavisimaja chast ocenki nastojashchaja: peremeshivanie ne ubiraet ejo, a
prevrashchaet v shum poverh chastotnoj serediny. Eto ulika PROTIV mira P13, a ne za nego.

**Chto teper stoit na stole i chego ja ne uvidel.** Pri K=32 gorizontnyj predskazatel bjot
chastotnuju tablicu na **+8,34 punkta** pri C=16 - vyshe moego zhe poroga v +4 punkta iz P6.
I on dolzhen byt DESHJOV po podkachkam: ocenka, obuchennaja na objedinenie 32 tokenov, po
postroeniju medlennaja, tak chto ejo top-C pochti ne shevelitsja mezhdu tokenami. Moj frontier
gonjal tolko K=1 - samuju dergajushchujusja iz vseh vozmozhnyh ocenok - i ja prinjal ejo za
"predskazatel voobshche". Eto byla oshibka vybora plecha, a ne vyvod.

Reshaet po-prezhnemu frontier pri RAVNYH podkachkah, teper s semejstvami hor8/hor16/hor32/hor64.

## P14. Predskazanie pered zamerom read_plain (zapisano do progona)

Zhdu **verhnij konec: neizvestnye 0,46 ms okazhutsja pochti celikom hostovymi**, to est
read_plain na ekspert budet ne 0,10 ms, a **0,35-0,55 ms**, i pol podkachki sjadet okolo
0,45-0,65 ms, a ne 0,10.

Tri osnovanija, i tretje sильnее pervyh dvuh:
1. V razlozhenii STATE ryadom so strokoj PCIe stoit "**tri zapisannye kopii**". Esli dannye
   dejstvitelno prohodjat cherez hostovuju pamjat trizhdy, 0,10 ms - eto odna tret nastojashchego
   chtenija, i 3 x 0,10 = 0,30 pochti zakryvaet 0,46.
2. 0,10 ms poluchen delenijem 2,51 MB na 24,8 GB/s - eto **raschjot, a ne zamer**, i on
   predpolagaet potokovoe chtenie na vosem potokov. Podkachka odnogo eksperta - odin potok i
   2,5 MB, to est rezhim, v kotorom 24,8 GB/s nedostizhimy v principe.
3. Ukazanie koordinatora pro pervoe kasanie stranic: mmap-stranicy modeli, k kotorym eshchjo ne
   obrashchalis, stoyat page fault na kazhdye 4 KB. Eto rovno tot chlen, kotoryj v odnom itoge
   nevidim, a v naklone otdeljaetsja.

Poetomu merit nado **naklonom po chislu ekspertov, a ne odnim itogom**, i otdelno progret
protiv holodnyh stranic - raznica etih dvuh naklonov i est cena pervogo kasanija.

Esli naklon dast 0,10-0,15 ms na ekspert (nizhnij konec), ja oshibsja, i togda okupaemost
podkachki - odno obrashchenie, a potokjennaja podkachka zhivaja.

---

# RAZRESHENO ZAMEROM, KOTORYJ UZHE LEZHAL NA DISKE. Koordinator prav, ja net.

Prezhde chem stroit zond dlja read_plain ja poiskal stroku v results/ - i ona tam byla,
v vosmi progonah svipa perioda (`_psab_*.out`). **Eto tretij raz za proekt, kogda dannye
sobiralis zanovo pri tom, chto uzhe lezhali pod drugim imenem** (METHODS 76).

    plecho        chtenie  GB/s   submit+zabor  ostatok   vsego
    period16_1      0.307  8.17         0.940    0.005    1.259
    period3_1       0.351  7.13         0.952    0.007    1.320
    period64_1      0.348  7.20         0.935    0.007    1.298
    ... vosem progonov
    srednee         0.341  7.37         0.949    0.007    1.306
    razbros         12.9%  14.1%         2.4%    30.2%     4.7%

**Kto byl prav v chjom.**

- **Koordinator prav polnostju po submit+zaboru: 0,949 ms, izmereno, razbros 2,4%.** Moja
  "popravka" byla nevernoj. Ja vzjal iz STATE vyvod "submit s zaborom stoil 0,10 ms na
  podkachku" - a 0,10 eto ne cena submita s zaborom, eto SKOLKO EJO UBRALO paketirovanie.
  Vyvod v STATE byl sdelan iz raznosti (1,300 -> 1,196) i molcha priravnjal "chto ubralos"
  k "chto stoit". Ne ubralos ostalnoe potomu, chto cena v OZHIDANII, a ne v chisle zaborov:
  batch_end sinhronno zhdjot zabor, i men'she zaborov ne znachit menshe ozhidanija.
- **Ja prav po chteniju, i P14 podtverzhdeno po nizhnemu kraju.** Predskazano 0,35-0,55 ms
  vmesto pricenennyh 0,10; izmereno **0,341**. I prichina ta, chto ja nazval vtorym punktom:
  0,10 schitalos po 24,8 GB/s vosmipotochnogo streama, a izmerennaja polosa odnopotochnogo
  memcpy na 2,51 MB - **7,37 GB/s**, to est v 3,4 raza nizhe.
- **Neizvestnogo chlena ne sushchestvuet.** ОSTATOK 0,007 ms. Vsja "vilka v faktor shest" iz
  moego P9 byla artefaktom nevernogo razlozhenija, a ne nastojashchej neopredeljonnostju.
- **Moja gipoteza pro fread iz GGUF byla nevernoj i proverena do togo, kak vojti v vyvod.**
  read_plain imeet dve vetvi; progony idut s --no-repack, znachit experts_plain=true,
  model_path pust, i rabotaet vetka memcpy. Odin grep po logu progona zakryl vopros.

**Itogovaja arifmetika, teper vsja na izmerennom:**

    chtenie (memcpy, 1 potok, 7,37 GB/s)   0,341 ms   HOSTOVAJA SHINA, ne skryvaetsja nikogda
    zapis kopii                            0,009
    submit + zabor (PCIe vnutri nego)      0,949      ustranimo, no rabotoj, kotoroj net
    ostatok                                0,007
                                           -----
                                           1,306 ms

    okupaemost: segodnja 13,6 obrashchenij (39 tokenov rezidentnosti pri C=16)
                pol      3,7 obrashchenij  (11 tokenov)

**Forma SpecPrefetch mertva v ljubom sluchae:** 47 podkachek na tokjen stoyat 61,4 ms segodnja
i 16,8 ms na polu, protiv tokena v 61,2 ms. Rezidentnost v odin tokjen daljoka ot 11 v 3-10 raz.
Zhivo drugoe - MEDLENNYJ nabor, vybrannyj tochno, i eto rovno gorizontnyj predskazatel iz P12.
