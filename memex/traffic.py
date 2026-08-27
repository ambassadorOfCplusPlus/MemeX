# Per-token traffic for an MoE GGUF, split into the half that is read every token no matter what
# and the half that depends on routing.
#
# Why this and not file size. On the 30B the experts are 14.6 GB of a 15.3 GB file, which reads as
# "the experts are the cost". They are not: only 8 of 128 are touched per layer, so their traffic
# is 911 MB, while attention is small on disk and read in full every single time - 510 MB. Storage
# and traffic are different quantities, and only traffic sets the speed of a memory-bound decoder.
#
# The static half is also the better thing to put in VRAM: it needs no residency policy, no
# prediction and no eviction, and on the 30B it buys more per megabyte than experts do.

import struct, sys, os
from collections import defaultdict

TN = {0:'f32',1:'f16',2:'q4_0',3:'q4_1',6:'q5_0',7:'q5_1',8:'q8_0',10:'q2_K',11:'q3_K',
      12:'q4_K',13:'q5_K',14:'q6_K',15:'q8_K',16:'iq2_xxs',17:'iq2_xs',18:'iq3_xxs',
      19:'iq1_s',20:'iq4_nl',21:'iq3_s',22:'iq2_s',23:'iq4_xs',24:'i8',25:'i16',26:'i32',
      29:'bf16',144:'iq4_ks',145:'iq5_ks',143:'iq3_ks',223:'iq4_xs_r8'}
# Types the Vulkan backend implements. Checked by grepping ggml-vulkan.cpp: IQ4_XS 25 mentions,
# Q8_0 45, Q6_K 21, IQ4_KS zero. A model whose static half is in an unsupported type cannot put
# that half on the card without requantising it first, which is the thing worth knowing early.
VK_OK = {'f32','f16','bf16','q4_0','q4_1','q5_0','q5_1','q8_0','q2_K','q3_K','q4_K','q5_K',
         'q6_K','iq4_nl','iq4_xs','iq1_s','iq2_xxs','iq2_xs','iq2_s','iq3_xxs','iq3_s'}

# (block elements, bytes per block) per ggml type. A type missing here yields a refusal rather
# than a guess, because a wrong block size produces a plausible number.
BLK = {0:(1,4), 1:(1,2), 29:(1,2),
       2:(32,18), 3:(32,20), 6:(32,22), 7:(32,24), 8:(32,34),
       10:(256,84), 11:(256,110), 12:(256,144), 13:(256,176), 14:(256,210), 15:(256,292),
       16:(256,66), 17:(256,74), 18:(256,98), 19:(256,50), 20:(32,18), 21:(256,110),
       22:(256,82), 23:(256,136),
       143:(256,110), 144:(256,136), 145:(256,82), 152:(256,168), 156:(256,110)}
# 152 = IQ5_KS, 156 = IQ3_KS in ik_llama's enum. Sizes from the measured bits-per-weight ladder
# (iq5_ks 5.266 bpw, iq3_ks 3.195), not guessed: 256 * 5.266 / 8 = 168.5 bytes per block.
# 145 corrected: it is IQ2_KS (2.195 bpw -> 82 bytes), not iq5_ks as the table previously said.


def read(path):
    f = open(path,'rb')
    if f.read(4) != b'GGUF': raise ValueError('ne GGUF')
    struct.unpack('<I', f.read(4))
    nt, = struct.unpack('<Q', f.read(8)); nk, = struct.unpack('<Q', f.read(8))
    def rs():
        n, = struct.unpack('<Q', f.read(8)); return f.read(n).decode('utf-8','replace')
    S = {0:'<b',1:'<B',2:'<h',3:'<H',4:'<i',5:'<I',6:'<f',7:'<?',10:'<q',11:'<Q',12:'<d'}
    def rv(t):
        if t == 8: return rs()
        if t == 9:
            et, = struct.unpack('<I', f.read(4)); n, = struct.unpack('<Q', f.read(8))
            return [rv(et) for _ in range(n)]
        fmt = S[t]; return struct.unpack(fmt, f.read(struct.calcsize(fmt)))[0]
    kv = {}
    for _ in range(nk):
        k = rs(); t, = struct.unpack('<I', f.read(4)); kv[k] = rv(t)
    ts = []
    for _ in range(nt):
        nm = rs(); nd, = struct.unpack('<I', f.read(4))
        dims = [struct.unpack('<Q', f.read(8))[0] for _ in range(nd)]
        tt, = struct.unpack('<I', f.read(4)); off, = struct.unpack('<Q', f.read(8))
        ts.append([nm, dims, tt, off])
    f.close()
    ts.sort(key=lambda x: x[3])
    # Size from shape and type, NOT from the gap to the next tensor's offset. The gap method looks
    # right and is right most of the time, which is what makes it dangerous: it silently assigns
    # any unallocated space to whichever tensor precedes it. On Coder-Next IQ4_XS it reported
    # post_attention_norm.weight - a vector - as 2967.8 MB, and would have put 88% of that model's
    # per-token traffic in a category that does not exist. A norm weight cannot be three gigabytes,
    # and that impossibility is the only reason the error was caught.
    for i in range(len(ts)):
        nm, dims, tt, off = ts[i][:4]
        bs, ts_ = BLK.get(tt, (0, 0))
        if bs == 0:
            ts[i].append(-1)      # unknown type: refuse a number rather than invent one
            continue
        n = 1
        for d in dims: n *= d
        ts[i].append(n // bs * ts_ if n % bs == 0 else (n + bs - 1) // bs * ts_)
    # A tensor whose type is not in BLK gets -1, and -1 must stop the analysis rather than flow
    # into the sums. It flowed once: mx9 printed negative megabytes and two billion experts because
    # tip152 was missing from the table and the -1 was quietly added up. That is exactly the failure
    # METHODS 46 was written against - a derivation that produces a plausible-looking number instead
    # of refusing. Negative bytes were absurd enough to catch; a merely wrong total would not have
    # been.
    unknown = sorted({TN.get(t[2], f"tip{t[2]}") for t in ts if t[4] < 0})
    if unknown:
        n_bad = sum(1 for t in ts if t[4] < 0)
        raise ValueError(
            f"neizvestnye tipy tenzorov: {','.join(unknown)} ({n_bad} tenzorov). "
            f"Dobavte ih v BLK (blok elementov, bajt na blok) - schitat bez nih nelzja, "
            f"summa budet nevernoj i pravdopodobnoj.")
    return kv, ts

def analyse(path):
    kv, ts = read(path)
    g = lambda s: next((v for k,v in kv.items() if k.endswith(s)), None)
    L    = g('.block_count')
    used = g('.expert_used_count') or 0
    nexp = g('.expert_count') or 0
    hk   = g('.attention.head_count_kv'); hk = hk[0] if isinstance(hk,list) else hk
    h    = g('.attention.head_count');    h  = h[0]  if isinstance(h,list)  else h
    ne   = g('.embedding_length')
    hd   = g('.attention.key_length') or (ne // h if (ne and h) else 0)
    name = os.path.basename(path)
    print(f'\n=== {name}')
    print(f'    sloev {L}, ekspertov {nexp}, aktivnyh {used}, golov Q {h} / KV {hk}, head_dim {hd}')

    grp = defaultdict(lambda: [0, set()])
    for nm, dims, tt, off, sz in ts:
        ty = TN.get(tt, f'tip{tt}')
        if   'exps' in nm or '_exp' in nm:      k = 'eksperty'
        elif 'attn' in nm:                       k = 'vnimanie'
        elif 'gate_inp' in nm:                   k = 'marshrutizator'
        elif nm.startswith('output.'):           k = 'golova'
        elif 'token_embd' in nm:                 k = 'embed'
        else:                                    k = 'prochee'
        grp[k][0] += sz; grp[k][1].add(ty)

    MB = 1024.0**2
    n_inst = (L or 0) * (used or 0)
    per_exp = grp['eksperty'][0] / max(1, (L or 1) * (nexp or 1))
    ex_traffic = n_inst * per_exp
    # token_embd is read one row at a time, so it is storage and not traffic.
    static = grp['vnimanie'][0] + grp['golova'][0] + grp['marshrutizator'][0] + grp['prochee'][0]
    tot = static + ex_traffic

    print(f'    {"":16}{"v fajle":>12}{"na tokjen":>12}   tipy')
    for k in ('vnimanie','golova','marshrutizator','prochee','embed','eksperty'):
        if k not in grp: continue
        sz, tys = grp[k]
        if   k == 'eksperty': tr = ex_traffic
        elif k == 'embed':    tr = 0.0
        else:                 tr = sz
        bad = '' if all(t in VK_OK for t in tys) else '  <<< NE VULKAN'
        print(f'    {k:16}{sz/MB:10.1f} MB{tr/MB:10.1f} MB   {",".join(sorted(tys))}{bad}')
    print(f'    {"-"*54}')
    print(f'    {"statika":16}{"":12}{static/MB:10.1f} MB   {100*static/tot:.0f}% trafika')
    print(f'    {"eksperty":16}{"":12}{ex_traffic/MB:10.1f} MB   {100*ex_traffic/tot:.0f}%'
          f'   ({used} iz {nexp}, po {per_exp/MB:.2f} MB)')
    print(f'    {"itogo":16}{"":12}{tot/MB:10.1f} MB  = {tot/1024**3:.3f} GB'
          f'  -> {1000*tot/1024**3/24.8:.1f} ms/tok na CPU')

    # The KV cache is not one number per model. Three things break the naive formula, and all
    # three appear in the models on this disk:
    #   - head_count_kv can be an array, different per layer (gemma4: 8 on windowed layers, 2 on
    #     full ones), so a scalar reading of it is wrong for every layer but one;
    #   - a sliding window makes a layer's cache constant in the context length rather than linear
    #     in it, and those layers often carry a smaller head_dim as well (gemma4: 256 vs 512);
    #   - a hybrid model may have layers with no KV cache at all (qwen35moe: 30 of 40 layers are
    #     SSM/linear attention with a fixed-size recurrent state).
    # Reading head_count_kv as a scalar over all layers overstated gemma4 by 14x and qwen35moe by
    # 4x, which is the difference between "does not fit in VRAM" and "fits with room to spare".
    hk_arr  = g('.attention.head_count_kv')
    swa_pat = g('.attention.sliding_window_pattern')
    swa_win = g('.attention.sliding_window') or 0
    hd_swa  = g('.attention.key_length_swa') or hd
    n_attn_layers = sum(1 for nm,_,_,_,_ in ts if '.attn_q.weight' in nm or '.attn_qkv.weight' in nm)
    n_real_attn   = sum(1 for nm,_,_,_,_ in ts if '.attn_k.weight' in nm)

    def kv_at(ctx):
        total = 0; grow = 0
        for il in range(L or 0):
            heads = hk_arr[il] if isinstance(hk_arr, list) and il < len(hk_arr) else hk
            if not heads: continue
            windowed = bool(swa_pat[il]) if isinstance(swa_pat, list) and il < len(swa_pat) else False
            # A layer with no attn_k has no KV cache of its own (SSM/linear attention).
            if not any(f'blk.{il}.attn_k.weight' == nm for nm,_,_,_,_ in ts): continue
            d    = hd_swa if windowed else hd
            span = min(ctx, swa_win) if (windowed and swa_win) else ctx
            sz   = 2 * heads * d * 2 * span
            total += sz
            if not windowed: grow += sz
        return total, grow

    print(f'    sloev s KV: {n_real_attn} iz {L}'
          + (f', okno {swa_win} na {sum(1 for x in swa_pat if x)} slojah' if isinstance(swa_pat,list) else '')
          + (f', {(L or 0)-n_real_attn} bez kesha (SSM/linejnoe)' if n_real_attn < (L or 0) else ''))
    for c in (2048, 8192, 16384, 32768):
        t, gr = kv_at(c)
        print(f'      -c {c:6d}: KV {t/MB:8.1f} MB'
              f'  (rastushchaja chast {gr/MB:.0f} MB, postojannaja {(t-gr)/MB:.0f} MB)')
    kv_tok = kv_at(16384)[0] / 16384.0

    VRAM = 3980 * MB
    left = VRAM - static - kv_at(16384)[0]
    print(f'    plan: statika {static/MB:.0f} + KV@16k {kv_at(16384)[0]/MB:.0f}'
          f' = {(static+kv_at(16384)[0])/MB:.0f} MB iz 3980'
          f'  ->  na ekspertov ostajotsja {left/MB:.0f} MB'
          f' ({int(max(0,left)/max(1,per_exp))} sht, {100*max(0,left)/max(1,grp["eksperty"][0]):.0f}%)')

for p in sys.argv[1:]:
    try: analyse(p)
    except Exception as e: print(f'\n=== {os.path.basename(p)}\n    OSHIBKA: {e}')
