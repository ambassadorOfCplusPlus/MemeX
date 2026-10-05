# deepseek4 build_deepseek4_step — Stage 1 (agent aa2e51e644f677ae5, 7 sent)

Signatura (mirror build_dense_step, drop qwen-knobs):
```cpp
bool build_deepseek4_step(Graph* g, ggml_backend_buffer_type_t buft, const HParams& h,
                          const Dsv4Weights& w, Cache& kv, int n_tokens, int n_past, int n_kv,
                          bool all_logits = false, bool keep_probes = false);
```

## Verified ggml sigs (ggml/include/ggml.h)
- ggml_hc_pre(ctx, x, scale, bias, int S, int n_iters, float eps) — 2682; returns all=pre|post|comb packed
- ggml_hc_post(ctx, x, post, res, comb) — 2691
- ggml_mul_multi_add(ctx, a[n0,n1,n2], b[1,n1,n2]) -> [n0,n2] — 1131 (== weight_and_fold)
- ggml_rope_ext_inplace(ctx, a, pos, freq, n_dims, mode, n_ctx_orig, freq_base, freq_scale, ext, attn, bf, bs) — 2091
- ggml_soft_max_ext(ctx, a, mask, scale, max_bias) — 2013; ggml_soft_max_add_sinks(a, sinks) void mutate — 2020
- ggml_mul_mat_id(ctx, as, b, ids) — 1649
- ggml_sqrt_softplus(ctx, a) — 1237 (SQRT_SOFTPLUS gating)
- ggml_scale_bias(ctx, a, s, b) = s*a+b — 1705; ggml_sigmoid 1370; ggml_repeat_4d 1282; ggml_top_k 2467
- GGML_OP_ROPE_BACK enum 648; un-rope trick: rope_ext_inplace then ->op=GGML_OP_ROPE_BACK; ->op_params[15]=1 (build_deepseek4.cpp:1236-1239)
- norm(c,x,w,eps)=ggml_mul(ggml_rms_norm(x,eps),w); fnorm=fused

## UNSURE (proverit pri integracii)
1. W (latent width) = L.wkv->ne[1] (avtoritetno), NE h.n_lora_kv+h.n_rope_head. Assert ravenstvo raz.
2. kv_a_norm normit ves W (kak reference), rope tolko pervye n_rope_head. Esli intent norm tolko nope - nevverno.
3. expert_weights_scale: HParams net polja, zahardkozheno norm=on scale=off. Dobavit esli GGUF scale!=1.
4. norm vs fnorm: ispolzoval nefused norm (build_step). Reference fnused. Perekljuchit esli koherentnost plyvet.
5. soft_max_ext mask [n_kv,nt] protiv kq [n_kv,nt,n_head] - broadcast, proverit.
6. hash-sloi: trebuet L.router!=null, inache otkaz. collect pometil router opcionalnym. Reshit do vkljuchenija hash.

## CACHE (kritichno)
MLA latent = odin tenzor/sloj [W, n_ctx, 1], K==V (n_head_kv==1). Sushchestvujushchij Cache uzhe
delaet k[il]=new_tensor_3d(F16, L.head_dim, n_ctx, L.n_head_kv). => NOVAJA struktura NE nuzhna ESLI
LayerGeom deepseek4 zapolnen: head_dim=W (=n_lora_kv+n_rope_head), n_head_kv=1, has_kv=true. Togda
k[il]=[W,n_ctx,1]. v[il] vydeljaetsja no ne ispolzuetsja (bezobidno). g->reads NE zapolnjat (KvRead
zhdjot transponirovannyj V; MLA ne imeet) => PERESTRAIVAT graf kazhdyj shag (ne re-aim).
Dtype: Cache F16; roped F32 latent kastuetsja v F16 na cpy. Pri drejfe po dline - F32 latent.

## TOP-3 verojatno nevernyh mest (validacija tolko po koherentnosti - etalon forka padaet)
1. Un-rope (ROPE_BACK, op_params[15]=1) - hrupkaja idioma, esli kernel ne chtit partial flag - povorot neveren.
2. mHC all-slicing + Sinkhorn: zavisit ot upakovki ggml_hc_pre [hc*nt|hc*nt|hc*hc*nt]; esli layout drugoj - musor.
3. F16 latent + kq_scale=1/sqrt(W): F16 okruglenie K==V, dlinnaja generacija plyvet. Pri drejfe - F32.

## POLNYJ KOD - v rezultate agenta aa2e51e644f677ae5 (task transcript). Integrirovat ottuda
(pomni: &amp;->& &lt;-<  &gt;->> pri kopirovanii iz transcripta). Helpery: dsv4_hc_pre/dsv4_hc_post/dsv4_hc_head.
Vstavit posle build_dense_step; wire ArchModel arch_deepseek4 + dispatch build_deepseek4_step;
LayerGeom deepseek4: head_dim=W, n_head_kv=1, has_kv=true.
