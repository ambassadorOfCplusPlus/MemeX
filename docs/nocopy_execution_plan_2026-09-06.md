# No-copy predictor-resident: plan ispolnenija (2026-09-06 noch)

## Glavnaja popravka (dizajn-agent, proverено po MSDN + STATE)
- **Dvojnoj kopii UZHE net** (ubrana 4 sent). Segodnja ExpertStore = ODNA kopija v privatnom
  bufere ~21 GiB, chitaetsja prjamym ReadFile mimo mmap (ESTORE_VERIFY 0 plohih).
- Cel polzovatelja "30 GB bez kopij" = **odna kopija zhivjot v page-cache mmap modeli**,
  privatnogo bufera net voobshche. Osvobozhdaet ~21 GiB -> v kesh vlezaet ~28/33 GiB ekspertov.
- Rezidentnost bez privilegij: **PrefetchVirtualMemory** (vtjanut predskazannye stranicy) +
  **VirtualUnlock** (vygnat holodnye v standby, bez zapisi v pagefile). VirtualLock NE nuzhen
  (bloker byl nazvan neverno: eto kvota rabochego nabora, ne SeLockMemoryPrivilege; pinit vredno).

## Chestnyj potolok
- D: = HDD 7200, 23,3 ms/sluchajnoe chtenie = 0,07 GB/s. 480 ekspertov/token x 1,4 MB.
  Promahi: 5% -> ~1,5 tok/s; 1% -> ~4 tok/s. **No-copy ~2x na polu ~2 tok/s, ne 10x.**
- **10x rychag = ne dvizhok, a menshij kvant / REAP-obrezka / model na SSD** (6,4x bystree hvost).
- Izmereno: agressivnyj prefetch na tjoplom HDD DELAET HUZHE (2,62->1,81) - zabivaet disk.
  option (b) na HDD dolzhen zhjostko ogranichivat vydachu ili molchat v tjoplom rezhime.

## Poshagovo (kazhdyj shag: build_safe + REGRESSIJA 16/16 na 3 arh)
1. **§2 BAZLAJN (nol koda).** `run_nocopy_baseline.ps1`: Coder-Next IQ4_XS, --gpu-static
   --gpu-static-layers, BEZ --expert-store, LLAMA_MMAP_PREFETCH=0. Progrev + 2 steady.
   Parsit STATIC_AB our_tok_s (statika+eksperty-mmap = cel) i ref_tok_s (CPU-kontrol).
   Proverit: pechataetsja li STATIC_AB pri --no-ref; esli net - ubrat --no-ref.
   OZHIDANIE: ~1,5-4 tok/s, osvobozhdaet 21 GiB. Esli >= 2,62 - uzhe pobeda bez koda.
2. **reserve-fiks** (esli §2 huzhe ozhidaemogo iz-za pejdzhinga): auto_capacity:263 vychitaet
   tolko reserve(2048). Izmerit static+KV+compute rabochij nabor, podnjat reserve tak chtoby
   privatnyj bufer + mmap-non-expert vlezli. NE hardkodit chislo vslepuju - izmerit.
3. **option (b) --mmap-resident-predict** (tolko esli §2 pokazhet LRU-zagrjaznenie):
   predskazatel R1 -> PrefetchVirtualMemory na expert-mmap stranicy (adres:
   tensor->data + e*nb[2], page-align), vmesto fill_slot na privatnye sloty. Perepolzovat
   K-ahead I/O potok. Strogij HDD issue-cap. Gate za --decode-check (bit-identichno no-store).
4. **option (c) VirtualUnlock evictor**: v pustoe telo Windows dontneed_fragment
   (llama-mmap.cpp ~551). Tolko esli (b) pokazhet chto LRU vytesnjaet gorjachee.

## Fakty dlja ispolnenija
- binar: D:\MemeX\src\ik_llama.cpp\build-vk\bin\Release\llama-memex-fwd.exe
- model: D:\Qwen3-Coder-Next-UD-IQ4_XS.gguf
- STATIC_AB print: memex-fwd.cpp:10059, gate `gsp && gsp->stats().calls>0`
- auto_capacity: expert_store.cpp:263 ; reserve default 2048: memex-fwd.cpp:4729
- graf perekljuchaet expert-tenzory na sloty tolko pri store on: memex-fwd.cpp ~3289-3298
- lock: C:\Users\User11\Desktop\MemeX\bench\lock.ps1
