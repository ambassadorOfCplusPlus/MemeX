# gpt-oss (LLM_ARCH_OPENAI_MOE) — чертёж порта в memex-fwd

Составлено ночью 7 сент 2026 по разведке форка. Форк ГРУЗИТ gpt-oss сам
(MXFP4 поддержан: GGML_TYPE_MXFP4=39 + dequantize_row_mxfp4; llama_rope_type даёт NEOX),
поэтому нужен ТОЛЬКО граф build_gptoss_step + collect + реестр — как было с phi3.
Референс графа: `src/graphs/build_openai.cpp` (чистый, 65 строк).

## Тензоры (стандартные имена, подтверждено load-tensors 2425-2450)
Не-слоевые: token_embd.weight, output_norm.weight, output.weight.
На слой:
- attn_norm.weight
- attn_q.weight + attn_q.bias, attn_k.weight + .bias, attn_v.weight + .bias
- attn_output.weight + attn_output.bias
- **attn_sinks.weight {n_head}** — обучаемый sink на голову
- **post_attention_norm.weight** (пред-MoE норма; НЕ ffn_norm! у OPENAI_MOE нет ffn_norm в
  таблице имён — llama-model.cpp:1620, create_openai_moe_tensors llama-load-tensors.cpp:4233.
  ВНИМАНИЕ: не спутать с create_dflash_tensors:2421 — это НЕ gpt-oss, а draft-модель dflash с
  ffn_gate/up/down; имена там похожи, но норма ffn_norm и FFN плотный. Ревью поймало.)
- ffn_gate_inp.weight + ffn_gate_inp.bias  (роутер + биас)
- ffn_gate_exps.weight + ffn_gate_exps.bias
- ffn_up_exps.weight   + ffn_up_exps.bias
- ffn_down_exps.weight + ffn_down_exps.bias
(вариант: fused ffn_up_gate_exps — обработать опционально; unsloth F16 — раздельные.)

## HParams
Стандарт: n_embd, n_head, n_head_kv, head_dim (gpt-oss = 64), n_ff (expert ff),
n_expert=32, n_expert_used=4, rope_base, rms_eps, n_ctx_train.
SWA: gpt-oss.attention.sliding_window (=128), паттерн 2 (ЧЁТНЫЕ слои — sliding).
**УПРОЩЕНИЕ v1: SWA можно ПРОПУСТИТЬ** — окно 128 не влияет на контекст < 128 токенов,
т.е. короткий тест даёт идентичный результат при полном внимании на всех слоях. SWA — TODO
для длинного контекста (LayerKind::ATTN_SWA на чётных, как gemma4).

## Граф (порт build_openai.cpp)
kq_scale = 1/sqrt(n_rot). Для каждого слоя:
1. x = rms_norm(inpL, attn_norm)
2. q = mul_mat(wq,x)+bq; k = mul_mat(wk,x)+bk; v = mul_mat(wv,x)+bv  (БИАСЫ есть!)
3. reshape в головы, rope NEOX (q,k) полный head_dim
4. внимание причинное; **sinks в softmax**: у нас ЕСТЬ `ggml_soft_max_add_sinks`
   (ggml.h:2020) и `ggml_soft_max_ext` (2013). Применить sinks к kq перед/через soft_max
   (см. как build_std_attention передаёт model.layers[il].attn_sinks в soft_max).
5. attn_out = mul_mat(wo, kqv) + bo; residual add.
6. MoE: x2 = rms_norm(ffn_norm); logits = mul_mat(gate_inp,x2)+gate_inp_b;
   gating = SOFTMAX_WEIGHT, norm_w=FALSE, scale_w=FALSE (build_openai стр.46):
   probs = softmax(logits); selected = top_k(probs, 4); weights = probs[selected] БЕЗ ренорма.
   Эксперты: up = mul_mat_id(up_exps,xe,ids) + gather(up_exps_b,ids);
             gate = mul_mat_id(gate_exps,xe,ids) + gather(gate_exps_b,ids);
             h = **ggml_swiglu_oai(gate, up, alpha=1.702, limit=7.0)** (ggml.h:1416);
             eo = mul_mat_id(down_exps, h, ids) + gather(down_exps_b, ids);
             moe = sum_k(weights_k * eo_k).
   residual add. НЕТ shared эксперта.
7. Голова: rms_norm(out_norm) -> mul_mat(out).

## Риск / где легко ошибиться (как с deepseek4)
- **per-expert биасы**: bias [n_ff|n_embd, n_expert]; gather по selected ids (get_rows на
  reshape) и add к mul_mat_id-выходу [.., n_used, n_tokens]. Формы — главный источник багов.
- **порядок аргументов ggml_swiglu_oai(gate_arm, up_arm)** — сверить с ggml.c.
- **sinks**: применяются к знаменателю softmax; свериться с реализацией soft_max_add_sinks.
- **gating без ренорма** (norm_w=false) — не делить на sum, в отличие от qwen3moe/deepseek4.
- Биасы attn q/k/v/o — не забыть (в наших build_step их нет).

## Реализация как у phi3
Как арх phi3: GptossWeights + collect_gptoss + build_gptoss_step + ArchId::GPTOSS + реестр
{"gpt-oss",...} + arch_gptoss_model (MoE, can_probes/can_repeat; can_store ПОЗЖЕ — 32 эксперта
малы, влезают в ОЗУ) + build_any branch + main dispatch + --gen gate + n_expert-guard уже
исключает плотные (gpt-oss MoE, guard проходит).

Модель: unsloth/gpt-oss-20b-GGUF F16 (~12.85 GB, эксперты MXFP4) качается на D:\gpt-oss-20b.gguf.
Малый, влезает в ОЗУ -> быстрая итерация отладки (в отличие от 90 ГБ deepseek4).
