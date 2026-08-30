"""How many tokens must a promoted expert stay resident before it has paid for itself?

Every term here is measured, not assumed, and each is named with where it came from. The point of
writing it as arithmetic rather than prose is METHODS 34 and 57: check the target against the
physical limit BEFORE hunting for a policy that reaches it.

The asymmetry that decides the whole question. In SpecPrefetch the expert has to reach the
accelerator either way - it lives on flash, and prefetching only moves the transfer earlier. In our
split it does NOT: a non-resident expert is not loaded on demand, it is computed by the CPU out of
RAM that already holds it. So a promotion here is ADDED work, not rescheduled work, and it only
pays if the CPU time it saves over the expert's whole residency exceeds the transfer it costs once.
"""

# ---- measured inputs, each with the line of STATE.md it comes from
EXPERT_BYTES_PER_TOKEN = 911.6e6   # STATE: eksperty 911.6 MB na tokjen, 48 sloev x 8 iz 128
N_LAYER, N_USED, N_EXPERT = 48, 8, 128
HOST_BW = 24.8e9                   # METHODS: 24.8 GB/s v vosem potokov, izmereno
TOKEN_MS = 61.2                    # zamorozhennoe plecho: 16.347 tok/s

# Razlozhenie odnoj podkachki. STATE "Baza byla nevernoj na 46%": izmereno 1,30 ms (ne 1,89 -
# staryj znamenatel delil total S pervichnoj zalivkoj na rate BEZ nejo), iz nih objasneno 0,74.
PROMO_MS        = 1.30             # izmereno na generacii
PROMO_READ_MS   = 0.10             # read_plain: mmap -> zakreplennaja pamjat, 2.51 MB / 24.8 GB/s
PROMO_PCIE_MS   = 0.64             # 2.51 MB / 3.94 GB/s, ochered DMA
PROMO_FENCE_MS  = 0.10             # submit + zabor, IZMERENO raznostju: shest podkachek pod odnim
                                   # zaborom dali 1,300 -> 1,196 na podkachku
PROMO_UNKNOWN_MS = PROMO_MS - PROMO_READ_MS - PROMO_PCIE_MS - PROMO_FENCE_MS   # 0,46 ms

# Etot ostatok - edinstvennyj neizmerennyj chlen, i ot togo, chej on, zavisit vsjo. Esli on na
# hostovoj shine (v stroke pro PCIe stoit "tri zapisannye kopii"), on ne skryvaetsja nikogda i
# vhodit v pol. Esli on na potoke ili na ustrojstve - skryvaetsja. STATE nazyvaet sledujushchim
# instrumentom "zamerit read_plain otdelno" imenno poetomu.
FLOOR_LO = PROMO_READ_MS                          # ostatok skryvaem
FLOOR_HI = PROMO_READ_MS + PROMO_UNKNOWN_MS       # ostatok na hostovoj shine

expert_uses = N_LAYER * N_USED
expert_mb = EXPERT_BYTES_PER_TOKEN / expert_uses
cpu_ms_per_use = expert_mb / HOST_BW * 1e3

print("odin ekspert = %.3f MB; CPU chitaet ego za %.4f ms" % (expert_mb / 1e6, cpu_ms_per_use))
print("za tokjen CPU tratil by %.1f ms na vseh %d ekspertov (STATE: ~36 ms pri nule popadanij)"
      % (cpu_ms_per_use * expert_uses, expert_uses))

print("\nskolko RAZ ekspert dolzhen byt vostrebovan posle prodvizhenija, chtoby ono okupilos:")
for name, cost in (("polnaja izmerennaja cena, kak segodnja", PROMO_MS),
                   ("pol, esli ostatok 0.46 na hostovoj shine", FLOOR_HI),
                   ("pol, esli ostatok skryvaem (tolko read_plain)", FLOOR_LO)):
    print("   %-46s %5.1f obrashchenij" % (name, cost / cpu_ms_per_use))

print("\nskolko TOKENOV rezidentnosti eto znachit pri emkosti C na sloj")
print("   (rezidentnyj ekspert vostrebuetsja %d*popadanij/C raz za tokjen)" % N_USED)
print("   %4s %8s %10s %10s %10s" % ("C", "popadanij", "1.30 ms", "0.56 ms", "0.10 ms"))
for C, hit in ((12, 0.62), (16, 0.70), (24, 0.80)):
    uses_per_token = N_USED * hit / C
    row = [cost / cpu_ms_per_use / uses_per_token
           for cost in (PROMO_MS, FLOOR_HI, FLOOR_LO)]
    print("   %4d %8.0f%% %10.0f %10.0f %10.0f" % (C, 100 * hit, *row))

print("\nA teper naoborot: chto stoit odna podkachka na sloj na tokjen (forma SpecPrefetch)")
per_tok = (N_LAYER - 1)
for name, cost in (("polnaja izmerennaja", PROMO_MS),
                   ("pol, ostatok na shine", FLOOR_HI),
                   ("pol, ostatok skryvaem", FLOOR_LO)):
    ms = per_tok * cost
    print("   %-22s %d podkachek x %.3f ms = %6.1f ms na tokjen pri tokene v %.1f ms  (x%.2f)"
          % (name, per_tok, cost, ms, TOKEN_MS, (TOKEN_MS + ms) / TOKEN_MS))
