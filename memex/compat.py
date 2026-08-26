"""Load a donor model across transformers versions.

`dtype=` is the transformers>=5 keyword; older releases (e.g. the preinstalled
one in Kaggle/Colab images) only accept `torch_dtype=`. Kernels without internet
cannot pip-install a newer version, so the code has to tolerate both.
"""
import os

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer


def split_gguf(path):
    """Accept either an HF folder or a path to a .gguf file.

    Local GGUF files (a llama.cpp collection) can be loaded by transformers,
    which de-quantises them to fp32 on the fly — so an existing model zoo is
    usable for experiments without re-downloading anything in HF format.
    Returns (folder, gguf_filename_or_None).
    """
    if path.lower().endswith(".gguf"):
        return os.path.dirname(path) or ".", os.path.basename(path)
    return path, None


def load_model(path, device="cpu", attn=None):
    folder, gguf = split_gguf(path)
    dtype = torch.float32 if device == "cpu" else torch.float16
    kwargs = {}
    if attn:
        kwargs["attn_implementation"] = attn
    if gguf:
        kwargs["gguf_file"] = gguf
    try:
        model = AutoModelForCausalLM.from_pretrained(folder, dtype=dtype, **kwargs)
    except TypeError:
        model = AutoModelForCausalLM.from_pretrained(folder, torch_dtype=dtype, **kwargs)
    return model.to(device).eval()


def load_tokenizer(path):
    folder, gguf = split_gguf(path)
    return (AutoTokenizer.from_pretrained(folder, gguf_file=gguf) if gguf
            else AutoTokenizer.from_pretrained(folder))
