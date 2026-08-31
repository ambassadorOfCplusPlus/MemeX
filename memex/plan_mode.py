"""Avtomaticheskij vybor rezhima ispolnenija - arifmetika iz ARCHITECTURE 8.42.

Pishetsja na Python PERVYM i proverjaetsja protiv izmerennyh sluchaev, potomu chto eto chistaja
arifmetika i ejo mozhno ispytat, ne trogaja ni dvizhok, ni mashinu. Port v C++ - posle togo, kak
vse chetyre izvestnyh sluchaja sojdutsja.
"""

# --- izmerennye velichiny mashiny (STATE.md) ---
RAM_GBS      = 24.8      # polosa OZU
VRAM_GBS     = 131.0     # polosa videopamjati
SSD_MISS_MS  = 6.0       # promah v SSD na odnogo eksperta
HDD_MISS_MS  = 25.0
PROMO_MS     = 1.306     # polnaja cena prodvizhenija eksperta, izmerena
CROSS_US     = 177.0     # peresechenie granicy CPU/GPU na sloj


class Plan:
    def __init__(self):
        self.exec_mode   = None    # 'cpu' | 'static+experts'
        self.capacity    = 0       # ekspertov na sloj v VRAM
        self.tier        = None    # 'page_cache' | 'ssd'
        self.predictor   = False
        self.why         = []

    def say(self, s): self.why.append(s)


def plan(*, static_bytes, kv_bytes_per_tok, n_ctx, expert_bytes, n_layer,
         n_expert_used, file_bytes, vram_bytes, ram_bytes, disk='ssd'):
    p = Plan()
    kv = kv_bytes_per_tok * n_ctx

    # --- 1. Statika. Otdacha 1,00 bajta chtenija na bajt rezidentnosti - vyshe net ni u chego.
    if static_bytes + kv > vram_bytes:
        p.exec_mode = 'cpu'
        p.say("statika %.0f MiB + KV %.0f MiB ne vlezaet v %.0f MiB VRAM" %
              (static_bytes/2**20, kv/2**20, vram_bytes/2**20))
        p.say("rezhim tolko processor: eksperty BEZ statiki izmereny na -10,4% - huzhe, chem nichego, "
              "potomu chto vnimanie vsjo ravno schitaetsja na CPU i granica platitsja kazhdyj sloj")
        return p
    p.exec_mode = 'static+experts'
    p.say("statika %.0f MiB + KV %.0f MiB na kartu (otdacha 1,00)" %
          (static_bytes/2**20, kv/2**20))

    # --- 2. Ostatok VRAM pod ekspertov. Otdacha 0,27 - vtoraja po velichine.
    rest = vram_bytes - static_bytes - kv
    p.capacity = int(rest // (n_layer * expert_bytes))
    p.say("ostatok %.0f MiB -> C = %d ekspertov na sloj" % (rest/2**20, p.capacity))

    # --- 3. Jarus. Reshaet ne razmer fajla sam po sebe, a to, vo chto obhoditsja PROMAH.
    if file_bytes <= ram_bytes - 4 * 2**30:
        p.tier = 'page_cache'
        miss_ms = expert_bytes / (RAM_GBS * 1e9) * 1e3
        p.say("fajl %.1f GB vlezaet v OZU %.1f GB minus zapas - promahi idut v stranichnyj kesh" %
              (file_bytes/2**30, ram_bytes/2**30))
    else:
        p.tier = 'ssd'
        miss_ms = SSD_MISS_MS if disk == 'ssd' else HDD_MISS_MS
        p.say("fajl %.1f GB BOLSHE OZU %.1f GB - promah idjot na disk" %
              (file_bytes/2**30, ram_bytes/2**30))

    # --- 4. Predskazatel. Odna drob, i ona reshaet vsjo.
    #
    # Odin punkt popadanij = (n_used * n_layer / 100) obrashchenij, kazhdoe cenoj miss_ms.
    # Podkachka stoit PROMO_MS. Znachit ejo cena V PUNKTAH POPADANIJ:
    demands_per_point = n_used_demands = (n_expert_used * n_layer) / 100.0
    point_ms = demands_per_point * miss_ms
    promo_points = PROMO_MS / point_ms
    p.predictor = promo_points < 1.0
    p.say("promah = %.4f ms; odin punkt popadanij = %.3f ms; podkachka = %.2f punkta" %
          (miss_ms, point_ms, promo_points))
    p.say("predskazatel %s: %s" % (
        "VKLJUCHIT" if p.predictor else "NE nuzhen",
        "podkachka deshevle punkta popadanij, tochnost obnalichivaetsja" if p.predictor
        else "podkachka dorozhe punkta - chastotnaja tablica optimalna, uchenyj vybor ne otbivaetsja"))
    return p


if __name__ == '__main__':
    MiB = 2**20; GiB = 2**30
    cases = [
        # (imja, ozhidanie)
        ("mx1 30B, nasha karta", dict(
            static_bytes=838*MiB, kv_bytes_per_tok=96*1024, n_ctx=4096,
            expert_bytes=2.374*MiB, n_layer=48, n_expert_used=8,
            file_bytes=15.4*GiB, vram_bytes=3.6*GiB, ram_bytes=31.9*GiB),
         dict(exec_mode='static+experts', tier='page_cache', predictor=False)),
        ("Coder-Next 80B, nasha karta", dict(
            static_bytes=965*MiB, kv_bytes_per_tok=96*1024, n_ctx=4096,
            expert_bytes=2.2*MiB, n_layer=48, n_expert_used=10,
            file_bytes=38.7*GiB, vram_bytes=3.6*GiB, ram_bytes=31.9*GiB),
         dict(exec_mode='static+experts', tier='ssd', predictor=True)),
        ("mx1 30B, karty net (0,5 GB)", dict(
            static_bytes=838*MiB, kv_bytes_per_tok=96*1024, n_ctx=4096,
            expert_bytes=2.374*MiB, n_layer=48, n_expert_used=8,
            file_bytes=15.4*GiB, vram_bytes=0.5*GiB, ram_bytes=31.9*GiB),
         dict(exec_mode='cpu')),
        ("mx1 30B, dlinnyj kontekst 16k", dict(
            static_bytes=838*MiB, kv_bytes_per_tok=96*1024, n_ctx=16384,
            expert_bytes=2.374*MiB, n_layer=48, n_expert_used=8,
            file_bytes=15.4*GiB, vram_bytes=3.6*GiB, ram_bytes=31.9*GiB),
         dict(exec_mode='static+experts', tier='page_cache', predictor=False)),
    ]
    bad = 0
    for name, kw, want in cases:
        p = plan(**kw)
        print("=== %s" % name)
        for w in p.why: print("   ", w)
        if p.exec_mode == 'static+experts':
            print("    C =", p.capacity)
        for k, v in want.items():
            got = getattr(p, k)
            if got != v:
                print("    NE SOSHLOS: %s = %r, zhdali %r" % (k, got, v)); bad += 1
        print()
    print("nesovpadenij:", bad)
