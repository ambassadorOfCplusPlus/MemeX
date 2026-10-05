# deepseek4 (DeepSeek-V4-Flash) realnye gpiparametry (iz llama-cli -dr)

n_layer 43, n_embd 4096, vocab (sm nizhe), context 1048576
attention: head_count 64, head_count_kv 1 (MLA latent!), key_length 512, value_length 512
  q_lora_rank 1024, rope.dimension_count 64 (decoupled rope chast), sliding_window 128
  output_group_count 8, output_lora_rank 1024
rope: scaling YARN factor 16, orig_ctx 65536, yarn_beta_fast 32 slow 1, freq_base 10000
  compress_rope_freq_base 160000, compress_ratios[46] = [0,0,4,128,4,128,...] (per-sloj CSA/HCA)
rms_eps 1e-6
experts: count 256, used 6, shared 1, ff_len 2048, gating_func 4 (sigmoid), weights_scale 1.5,
  weights_norm true, swiglu_clamp arrays per-sloj
indexer: head_count 64, key_length 128, top_k 512
hyper_connection: count 4, sinkhorn_iterations 20, epsilon 1e-6
hash_layer_count 3

=> Mehanizmy dlja porta v build_step: MLA (q_a/q_b/kv_a/kv_b latent, decoupled YaRN rope),
razrezhjonnyj indexer (top_k), hyper-connections (Sinkhorn 20 iter), hash-routing, sigmoid-gating
s norm+scale, per-sloj compress tiers. Etalon: src/graphs/build_deepseek4.cpp (1684) + llama-dsv4.cpp (1799).
POTOLOK: 90GB IQ2 na HDD 0.07 GB/s = <1-2 tok/s. [[deepseek4-arch-2026-09-07]]
