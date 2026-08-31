# Uchenyj predskazatel rezidentnogo nabora: izmereno, i vyvod otricatelnyj

Vsjo nizhe - na trassah nashej modeli, otlozhennye tokeny, LFU/nedavnost/orakul poschitany
NA TOJ ZHE trasse v TOM ZHE progone (chisla iz raznyh trass ne sravnivajutsja - STATE ob etom
predupredzhdaet javno).

## 1. Chto uzhe lezhalo, i chto prishlos sobrat

**Uzhe lezhalo, i eto zakryvalo pervyj shag celikom.** `tr_act.bin` (856 MB, 20 avgusta,
sobran drugim potokom dlja zadachi pro razrezhennost) nesjot rovno paru iz statji: uzel
`ffn_inp_normed` [2048, n_tok] - vhod marshrutizatora - i `ffn_moe_topk`, 48 sloev, 1110 tokenov.
Na njom byla proverena vsja ideja, do togo kak chto-libo sobiralos.

Dve lovushki formata:
- aktivacija zapisana DVAZHDY: `moe-trace.cpp` matchit uzel po PREFIKSU imeni, a `ggml_cast`
  otdajot svoemu vyhodu to zhe imja. Zapisi pobitovo odinakovy (max|a-b| = 0). METHODS 9.
- sloj 47 prihodit s ODNIM tokenom (METHODS 7) i, vzjatyj kak minimum, obnuljaet vse 48.

**Sobrano** tolko radi objoma i domenov: 6 progonov, 3 domena (kod / angl. proza / russkij),
2481-3731 tokenov kazhdyj, vsego ~17 300 tokenov, po 2,5 minuty na progon. Chetyre iz nih nesut
i polnye raspredelenija marshrutizatora (uchitel dlja KL-lossa iz statji), esli ponadobitsja.

## 2. Signal est, i on krupnyj

Poslojnoe linejnoe otobrazhenie iz vhoda marshrutizatora sloja L v ekspertov sloja L+1
(ridge = predel po rangu, to est verhnjaja granica ljubogo rank-r adaptera):

    R@8 = 62,1%   R@12 = 73,9%   R@16 = 80,2%   R@24 = 87,3%   (chastota: 29,2 / 38,1 / 45,9 / 57,8)

Staryj otricatelnyj zamer "sloj L ne predskazyvaet L+1, 6,0% protiv pola 6,25%" ne protivorechit:
on meril ID protiv ID. Skrytoe sostojanie - drugoj istochnik, i on rabotaet.

## 3. Forma iz statji na nashej modeli ne rabotaet

Statja delit OBA matrix A i B mezhdu slojami. U nas:

    poslojnyj (predel)              R@16 = 80,2%
    obshchij A r=128, poslojnyj B          77,3%
    obshchij A r=64,  poslojnyj B          74,2%
    obshchij A r=32,  poslojnyj B          70,5%
    OBSHCHIE A i B (forma statji)          37,5%   <- nizhe chastotnoj bazovoj linii (45,9%)

Eto tot zhe nash rezultat, chto indeks eksperta znachit raznoe v kazhdom sloe. Obshchaja golova
objazana byt poslojnoj; obshchim mozhet byt tolko proekcija A.

## 4. Zapas po vremeni - ne uzkoe mesto

    zapas 1 sloj  R@16 = 80,2%      zapas 4 sloja  78,1%
    zapas 2 sloja        79,5%      zapas 8 sloev  76,1%

Vosem sloev ~10 ms, i tochnost teryaet 4 punkta. Vremeni na peredachu mozhno vzjat skolko ugodno.

## 5. Cena podkachki: razlozhena, neizvestnogo chlena net

Izmereno samim dvizhkom, vosem progonov (`_psab_*.out`), i eto uzhe lezhalo na diske:

    chtenie (memcpy otobrazhenie -> zakreplennaja, 7,37 GB/s odnopotochno)  0,341 ms  razbros 12,9%
    zapis kopii                                                            0,009
    submit + zabor (PCIe vnutri ozhidanija)                                0,949     razbros 2,4%
    ostatok                                                                0,007
                                                                           -----
                                                                           1,306 ms  razbros 4,7%

Chtenie idjot po toj zhe hostovoj shine, chto i schjot processora - ne skryvaetsja nikogda.
Submit s zaborom ustranim, no tolko toj rabotoj, kotoroj net (svoj zabor, peredacha vladenija
ocheredi, asinhronnaja DMA); poka `batch_end` sinhronno zhdjot - eto pol.

## 6. Kurs obmena, i proverka arifmetiki

Odin punkt popadanij = 3,84 obrashchenija x 0,0957 ms = **0,368 ms na tokjen**. Znachit

    odna podkachka na tokjen stoit 3,55 punkta popadanij segodnja
                                   0,97 punkta na polu

Proverka protiv zamera, sdelannogo RANSHE etoj modeli: period3 protiv frozen - 6,91 podkachki
minus 2,3 punkta popadanij dajot +8,18 ms, to est 14,50 tok/s protiv **izmerennyh 14,14**.
Rashozhdenie 2,5% pri pole shuma 4,2%.

## 7. Frontier pri RAVNYH podkachkah: predskazatel ne bjot chastotu

C=16, 811 otlozhennyh tokenov, 46 sloev. Verhnjaja ogibajushchaja chastotnyh politik protiv
luchshego iz semejstv predskazatelja, pri odinakovom chisle podkachek na tokjen:

    podkachek/tok    chastota    luchshij predskazatel    raznica
        0,00          42,02%          43,07%              +1,04   (predema97, zamorozhennyj)
        0,34          43,72           43,57               -0,14
        0,74          43,86           43,92               +0,06
        1,47          44,26           44,64               +0,38
        2,89          45,55           45,25               -0,28
        5,79          47,57           46,83               -0,66
       11,51          50,15           49,61               -0,52

**Maksimum vyigrysha - +1,04 punkta, i on v tochke nulevyh podkachek.** Po kursu eto
+0,10 tok/s, to est **+0,6% pri vnutrisessionnom pole shuma 4,2%**. Moj sobstvennyj porog iz P6
byl +4 punkta. **Ne dostignut, i dazhe blizko.**

Vse chetyre gorizontnyh semejstva (obuchennye predskazyvat spros za sledujushchie K tokenov,
imenno chtoby byt medlennymi) idut po nulju ili v minus: hor32 +0,56 pri nule podkachek i
-0,19...-6,94 vezde dalshe. Kontrol peremeshivaniem vedjot sebja kak kontrol: -2...-16,7.

**Pochemu +8,34 punkta iz `horizon_code.txt` ne perenosjatsja.** Tam predskazatel sravnivalsja
so STATICHESKOJ chastotnoj tablicej, poschitannoj na obuchajushchih tokenah. V frontier chastotnye
politiki ONLAJNOVYE - oni vidjat nastojashchie vybory v okne pered soboj. Predskazatel takogo
preimushchestva ne imeet. I ego +8,34 trebujut perevybora KAZHDYJ tokjen: hor32 s periodom 1
dajot 49,56% cenoj **43,40 podkachki na tokjen**.

## 8. Chto na samom dele lezhit na stole, i skolko ego

Orakul pri TEH ZHE podkachkah (a ne bespriceljnyj):

    podkachek/tok   orakul   chastota   razryv        cena razryva
        2,55        54,11%    45,01%     9,10 punkta   +0,96 tok/s  (+5,8%)
        5,78        58,66     47,50     11,16          +1,19        (+7,2%)
       11,89        64,08     50,31     13,77          +1,50        (+9,1%)

**Poetomu "tridcat punktov ne tronuty" - eto ne to chislo.** 85,7% orakula izmerjalis pri
neogranichennom chisle podkachek. Pri bjudzhete, kotoryj mashina real'no platit, razryv
**9-11 punktov**, i stoit on +5,8...+7,2%. Razryv nastojashchij. No predskazatel iz skrytogo
sostojanija berjot iz nego okolo odnogo punkta, potomu chto orakulu pomogaet znanie BUDUSHCHEGO,
a odin sloj skrytogo sostojanija dajot znanie NASTOJASHCHEGO.

## 9. Vyvod

**V dvizhok ne vodit.** Shag 4 zadania ne vypolnjaetsja po rezultatu shaga 3, kak zadanie i
predpisyvaet: oflajn-ocenka reshaet, stoit li rabota v dvizhke, i ona govorit "net" - +0,6%
protiv pola 4,2%.

Ostajutsja dva ne-predskazatelnyh vyvoda, oba s chislami:
1. **Umolchanie `--resident-period 3` - hudshee.** frozen 16,41/16,49 (razbros 0,5%) protiv
   period3 14,10/14,19 (0,6%), oba plecha chistye: **+16,3%** za odnu stroku. Periody 16/32/64
   po-prezhnemu ne rezultat (razbrosy 12,6% i 5,8%, u 64 odna replika).
2. **Sledujushchij rychag - 0,949 ms submit+zabora, a ne politika.** Ubrat ego - eto 3,55 -> 0,97
   punkta za podkachku, to est vtroe deshevle churn. Eto edinstvennoe, chto delaet 9-11 punktov
   razryva orakula dostizhimymi hot' kakoj-nibud politikoj.
