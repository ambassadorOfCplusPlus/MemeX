# Predskazanie: blokirujushchee ozhidanie vmesto spina v batch_end

Zapisano DO sborki i do ljubogo zamera. 31 avgusta.

## Chto izmeneno

`ggml_backend_vk_batch_end` zhdal zabor cherez `ggml_vk_wait_for_fence`, a tot krutitsja na
YIELD. Teper - `waitForFences` s blokirovkoj, i u peredach svoj zabor vmesto obshchego s
vychisleniem.

Stennoe vremja peredachi ne menjaetsja voobshche. Menjaetsja tolko to, chto jadro otpuskaetsja
na vremja ozhidanija vmesto togo, chtoby gorét vhulostuju 0,949 ms na kazhduju podkachku.

## Predskazanie, i ono govorit "ne izmerish"

Osnovanie - zamer zamorozhennogo nabora: pri perehode ot 6,91 podkachki na tokjen k nulju
dzhojn-ozhidanie upalo na 3,95 ms, to est 6,6 ms spina vernuli 3,95 ms tokjena (koefficient
0,60). Esli mehanizm tot zhe, ekonomija = 0,60 x 0,949 x podkachek_na_tokjen.

    plecho        podkachek/tok   spin/tok   zhdu ekonomii   zhdu tok/s   ot 60,9 ms
    period 32          ~1,2        1,14 ms      0,68 ms        +1,1%        60,2 ms
    period 3            6,91       6,56         3,94           +6,9%        57,0 ms

**To est na novom umolchanii (32) izmenenie dolzhno okazatsja NEIZMERIMYM** - +1,1% pri pole
shuma 4,2%. Merit ego nado na period 3, gde effekt v shest raz krupnee.

Esli na period 3 vyjdet menshe +3%, mehanizm "spin otnimaet jadro u processornoj polovinny"
neveren, i togda vyigrysh zamorozhennogo nabora objasnjaetsja chem-to drugim - a eto vazhnee
samogo izmenenija, potomu chto na tom mehanizme stoit vybor umolchanija.

Esli vyjdet okolo +6,9% - mehanizm podtverzhdjon, i togda asinhronnaja otpravka (submit bez
ozhidanija voobshche) dolzhna zabrat ostavshiesja 0,949 x 0,40 = 0,38 ms na podkachku sverhu.

## Chego eto izmenenie NE delaet

Ne ubiraet 0,949 ms iz ceny podkachki. Podkachka po-prezhnemu zanimaet 1,306 ms stennogo
vremeni, i kurs "odna podkachka = 3,55 punkta popadanij" ne menjaetsja. Menjaetsja tolko to,
komu dostajotsja jadro vo vremja ozhidanija.
