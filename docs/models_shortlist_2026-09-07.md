# Aktualnye modeli dlja dvizhka (agent-poisk, sent 2026)

Reshaet odno chislo: skorost ~ aktiv-params x bpw / 24.8 GB/s, I ves model <=24 GB (inache HDD <2 tok/s).
Pobediteli = MoE ~3B aktiv I <=24 GB. Eto pochti tolko semejstvo Qwen3-MoE (uzhe podderzhano).

## TIER 1 - vlezaet, bystro, ARH UZHE PODDERZHANA (pochti besplatno):
1. **Qwen3-30B-A3B-Instruct-2507** ⭐ - luchshij vybor. 30.5B/3.3B aktiv, Q4_K_M ~18.6GB, ~15-19 tok/s.
   arch qwen3moe. Repo: unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF
2. Qwen3-Coder-30B-A3B-Instruct - koding, tot zhe profil, ~15-19 tok/s. unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF
3. Qwen3-30B-A3B-Thinking-2507 - reasoning, tot zhe arh besplatno.
4. Ministral 3 14B (dek 2025) - dense, llama-arh, Q4 ~8.5GB no 14B dense -> ~8-9 tok/s.
5. Gemma 3 12B - gemma4-arh, ~8 tok/s. 27B fits no ~3.5 (dense penalty).

## TIER 2 - vlezaet+bystro, NUZHNA NOVAJA ARH (vysokaja cennost):
6. **gpt-oss-20b** - luchshaja investicija v novuju arh. 21B/3.6B aktiv, MXFP4 ~12GB, ~15-18 tok/s,
   ogromnaja populjarnost. arch gpt-oss (novyj graf-builder, dni). unsloth/gpt-oss-20b-GGUF
7. ERNIE-4.5-21B-A3B - 21B/3B, Q4 ~13GB, ~15 tok/s. arch ernie4_5-moe (novaja).

## TIER 3 - bolshie/vpechatljajut no NE stoit (spill HDD <2 tok/s):
Qwen3-Next-80B-A3B (arh besplatna qwen3next, no 80B spill - kuriozny eksperiment IQ2 ~25GB),
GLM-4.5-Air/4.6 (glm4moe novaja + spill), Llama4 Scout/Maverick (llama4 novaja, 17B aktiv),
Mistral 24B dense (llama, fits no ~4-5), DeepSeek V3/Kimi K2 (beznadjozhno). Phi-4 (phi3 novaja).

## ITOG: 1) Qwen3-30B-A3B trio (besplatno, ~15-19). 2) Ministral14B+Gemma12B (dense, ~8).
3) Odna novaja arh - gpt-oss-20b (luchshij ROI). 4) SEO-fejki "GLM-5.2/Kimi K3/Qwen3.8" - IGNOR.
