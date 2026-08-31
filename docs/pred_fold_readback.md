# Predskazanie: chtenie, slozhennoe v komandnyj bufer grafa

Zapisano DO sborki i do zamera. 31 avgusta.

## Chto izmeneno

`compute(il, k)` delala dva kruga na ustrojstvo: `graph_compute` otpravljaet i zhdjot zabor,
potom `tensor_get` otpravljaet i zhdjot vtoroj. Teper kopija rezultata zapisyvaetsja v TOT ZHE
komandnyj bufer, chto i posledinj uzel grafa, i zabor grafa ejo pokryvaet.

Pereklychatel `MEMEX_FOLD_READBACK=0` vozvrashchaet staryj put, obe vetki v odnom binarnike,
vetka nazyvaet sebja strokoj `FOLD_READBACK on|off`.

## Chislo, ot kotorogo schitaju

Izmereno, tri repliki, razbros 2,8%:

    chtenie  5,45 ms/tokjen = 113 us na sloj za 46 KB

113 us - eto ne polosa (46 KB po shine eto ~8 us), a dva kruga: izmerennyj pol odnogo
submit+zabor na etom ustrojstve - 59 us.

## Predskazanie

Skladyvanie ubiraet ODIN krug iz dvuh. Znachit stroka `out` dolzhna upast s 5,45 do **okolo nulja**
(ostajotsja tolko zamer pustogo `if`), a stroka `graph` - **vyrasti primerno na 2,7 ms**, potomu
chto kopija teper vnutri nejo. Chistaja ekonomija - **okolo 2,7 ms na tokjen**.

    do:    graph 15,63  out 5,45   job 21,60
    zhdu:  graph 18,3   out ~0,0   job 18,9

Tokjen 61,0 -> 58,3 ms, to est **15,97 -> 16,7 tok/s, okolo +4,4%**. Eto NA GRANICE pola shuma
4,2%, poetomu merit nado tremja replikami i smotret na razlozhenie dispatcha, a ne tolko na tok/s:
stroki `graph` i `out` dolzhny dvinutsja imenno tak, kak napisano vyshe, i ih summa - upast.

**Esli `out` upala, a `graph` vyrosla na te zhe 5,45 - ekonomii net**, i eto znachit, chto vtoroj
krug ne byl otdelnym krugom, a prosto zhdal tu zhe rabotu. Togda vsja stroka `out` byla ne
nakladnymi, a nastojashchim ozhidaniem vychislenija, i iskat nado v jadrah.

**Esli tok/s ne dvinulas, a summa graph+out upala** - znachit vremja ushlo v drugoe mesto tokjena
(skoree vsego v dzhojn-ozhidanie), i togda vyigrysh est, no ego zabiraet processornaja polovina.
Eto tozhe otvet, i on ne huzhe.

## Korrektnost

Obiazatelna do ljuboj cifry skorosti: 192 iz 192 tokenov i 0 rashozhdenij po 48 slotam. Skladyvat
chtenie mozhno TOLKO na poslednem uzle - bolee rannij submit skopiroval by vyhod, kotoryj graf
eshchjo ne dopisal. Esli sovpadenie tokenov slomaetsja, delo imenno v etom.
