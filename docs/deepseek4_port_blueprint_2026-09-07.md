# deepseek4 port v nash dvizhok - stadijnyj chertjozh (agent-arhitektor 7 sent)

## Kljuchevoe otkrytie
- Razrezhjonnyj indexer + 3-jarusnyj kesh (CSA/HCA) = MJORTVYJ kod NIZHE n_swa (sliding_window).
  Dlja PROMPTA KOROCHE n_swa etalon vyrozhdaetsja v plotnoe MLA-vnimanie nad odnim rastushchim
  latentnym keshem - bit-identichno. => Stadija 1 MOZHET propustit indexer+kesh+kompressory.
- Hyper-Connections (mHC, Sinkhorn-normirovka hc_mult=4 potokov) OBJAZATELNY dlja korrektnosti
  (hard-throw esli hc_mult==0). Sinkhorn - gotovoe CPU-jadro (ggml_hc_pre/ggml_sinkhorn/ggml_hc_post).
- MoE-gejting = sqrt(softplus(logits)), NE softmax/sigmoid (hard-require SQRT_SOFTPLUS).
- Trjuk: RAZ-rope VYHODA vnimanija (GGML_OP_ROPE_BACK, op_params[15]=1) - l3gko zabyt, dast
  "svjazno no neverno".
- KV: n_head_kv==1, odin latentnyj bufer = I K I V (raw_k peredajotsja dvazhdy) - polovina KV-pamjati.

## Stadija 0 (chasy, mehanika) - verifikacija: model gruzitsja, hparams sovpadajut
1. HParams: +n_lora_q/n_lora_kv/n_rope_head/indexer_*/hc_mult/hc_sinkhorn_iters/hc_eps/o_group_count/
   o_lora_rank (Dsv4Extra sub-struct po ukazatelju). n_swa iz .attention.sliding_window.
   VAZHNO: iskljuchit deepseek4 iz proverki key_length!=value_length (memex-fwd.cpp:645, kak gemma4).
   dsv4_hc_mult==0 -> hard-otkaz. hash_layer_count!=0 -> Stadija1 assert==0 (proverit na fajle).
2. Dsv4Weights struct + collect_dsv4 (zerkalo Gemma4Weights/collect_gemma4). Imena tenzorov iz
   llama-model.cpp:1138-1197 + fallback-spelling (attn_kv/attn_kv_latent/attn_kv_a_mqa - probovat vse
   cherez print_present_tensors na REALNOM fajle PERED hardkodom).
3. ArchId::DEEPSEEK4 + registry + arch_deepseek4() (can_probes=true, ostalnoe OFF dlja St1). Dispatch
   5 tochek kak u arch_llama (6659, 6806, 7198-7223) + build_deepseek4_step deklaracija.

## Stadija 1 (2-4 sessii) - korrektnost: novyj build_deepseek4_step, plotnoe MLA, bez kesha
Tochnaja ggml-posledovatelnost sloja v otchjote agenta (task a3bb94bb5d70562d2 / etot doc-istochnik):
mHC-pre -> attn_norm -> Q(down->norm->up->reshape->partial-rope n_rope_head) -> KV-latent(same) ->
cache write (odin bufer) -> attn(Q vs full latent cache, K==V) -> soft_max_ext(1/sqrt(n_embd_head)) ->
UN-ROPE vyhoda -> grouped low-rank output proj (wo_a/wo_b) -> mHC-post. FFN: sqrt(softplus) gejting,
top-6 iz 256 + 1 shared, + vtoraja para mHC vokrug FFN, + build_hc_head v konce (sigmoid+bias, ne Sinkhorn).
Novyj Cache-variant: odin tenzor/sloj shirinoj n_embd_head=kv_lora_rank+n_rope_head, n_head_kv=1.

## PERVOE DEJSTVIE pered kodom St1:
- print_present_tensors + hparam-dump na D:\DeepSeek-V4-Flash (realnye imena/znachenija).
- Zapustit etalonnyj llama-cli na DeepSeek s PROMPTOM KOROCHE n_swa -> SVJAZNO li? (kak Mixtral,
  etalon mozhet byt sloman). Esli svjazno - decode-check target; esli musor - sudit po svjaznosti.

## Stadija 2 (mnogonedelnaja): indexer top-k, 3-jarusnyj kesh (llama-dsv4.cpp 1799 str - dominanta),
static-na-karte, no-copy eksperty. Vulkan-port 4 kastomnyh ops NE stoit na 4GB VRAM (ops krohotnye).

## POTOLOK: 90GB IQ2 na HDD 0.07 GB/s = <1-2 tok/s nezavisimo ot softa. [[deepseek4-arch-2026-09-07]]

## REALNYE imena tenzorov (iz gguf, sloj 0) - dlja collect_dsv4:
Global: token_embd, output, output_norm, output_hc_* (golova hc)
Per-sloj blk.%d.: attn_norm, attn_q_a, attn_q_a_norm, attn_q_b, attn_kv (KV-latent, spelling=attn_kv!),
  attn_kv_a_norm, attn_output_a, attn_output_b, attn_sinks(opt), ffn_norm, ffn_gate_inp,
  ffn_{gate,up,down}_exps (256), ffn_{gate,up,down}_shexp (1 shared), ffn_gate_tid2eid (HASH-routing!),
  hc_attn_{base,fn,scale}, hc_ffn_{base,fn,scale}.
Indexer/compressor tenzorov na sloe 0 NET (SWA-sloj, compress_ratios[0]=0). hash_layer_count=3 =>
pervye sloi hash-marshrutizacija (ggml_get_rows po tid2eid), ne router. n_swa=128 (dry-run).
