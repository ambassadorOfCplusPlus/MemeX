# Optimizacija NE-VLEZAJUSHCHIH (agent, sent 2026)

## #1 HIGHEST-ROI: Windows page-cache eviction via VirtualUnlock (7.7 -> ~8.5-9.5)
- dontneed_fragment na Windows = PUSTAJA zaglushka (llama-mmap.cpp:551-554); ves pajplajn
  vytesnenija #ifdef __linux__ (llama.cpp:5108). No-copy = rab OS LRU, ne mozhet osvobodit kesh.
- FIKS: realizovat Win dontneed_fragment cherez VirtualUnlock(addr, len) (clean file-backed ->
  standby, bez pagefile, re-fault deshjov; ignor ERROR_NOT_LOCKED). + osvobodit STATIK-stranicy
  (uzhe na karte pri --gpu-static, v ozu dubli ~5-6 GB) -> +20-23% jomkosti kesha pod goryachih.
- CHISTO nashe: memex-fwd-owned vyzov posle --gpu-static offload -> VirtualUnlock static/non-expert
  range (invert expert-indeksa), ne trogat Linux-pipeline. Bez lishnih chtenij = edinstvennoe chto
  vazhno po fizike. DELAT PERVYM.

## Rang:
1. Win VirtualUnlock evict static-on-GPU stranic (^) - DA, beznagruzochno, ~+1.5 tok/s
2. SSD-only miss-spill (mmap residency + SSD hvost, reuse build_warm/read_slot/is_warm) - 23ms->3.4ms
   miss, cold-start i bolshie modeli (DeepSeek)
3. Cold-expert VirtualUnlock po Layer::score - marginalno
4. Low-bit cold-expert kopija (FLAT ne po heat - signal ploskij) - --expert-store-repack-lo, gated+verify
5. R1-predictor prefetch - NET na HDD (2.62->1.81); tolko SSD-tier + cold-start ~+0.5

## PRAVDA: HDD potolok ~2-4 tok/s pri 95-99% hit. 7.7 uzhe vyshe naivnoj HDD-fiziki blagodarja
static-na-karte + page-cache. #1 podnimet residency besplatno. 10x rychag OFF-engine: REAP (model
vlezaet), SSD/NVMe (6.4x hvost), bolshe OZU. Predskatel/prefetch ne prjachet 23ms HDD-promah.
Fajly: memex-fwd.cpp, expert_store.cpp/.hpp; hooks llama-mmap.cpp:551, llama-model-loader.cpp:624-690.
