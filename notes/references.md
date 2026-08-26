# References

## Paper and official code

- [arXiv:2411.04975v3](https://arxiv.org/abs/2411.04975) — SuffixDecoding (HTML: https://arxiv.org/html/2411.04975v3)
- [Project page](https://suffix-decoding.github.io/)
- [snowflakedb/ArcticInference](https://github.com/snowflakedb/ArcticInference)
- [vLLM suffix docs](https://docs.vllm.ai/en/latest/features/speculative_decoding/suffix.html)
- [vLLM PR #25784](https://github.com/vllm-project/vllm/pull/25784)

## llama.cpp family

- [ggml-org/llama.cpp speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md) — ngram-mod / ngram-simple / draft-mtp; **no suffix type**
- [ikawrakow/ik_llama.cpp#1602](https://github.com/ikawrakow/ik_llama.cpp/issues/1602) — feature request
- [ikawrakow/ik_llama.cpp#1646](https://github.com/ikawrakow/ik_llama.cpp/pull/1646) — merged 2026-04-18; `common/suffix-tree.{h,cpp}`
- [ik_llama speculative docs](https://github.com/ikawrakow/ik_llama.cpp/blob/main/docs/speculative.md)
- [llama.cpp SYCL MMVQ PR #21845](https://github.com/ggml-org/llama.cpp/pull/21845) — speculative verify cost on Arc

## Models / speculators

- Qwen3.8-27B GGUF (Bartowski Q8_0, Unsloth Q6 XL) — native MTP
- [unsloth/gpt-oss-20b-GGUF](https://huggingface.co/unsloth/gpt-oss-20b-GGUF)
- [RedHatAI/gpt-oss-20b-speculator.eagle3](https://huggingface.co/RedHatAI/gpt-oss-20b-speculator.eagle3) — skip until model-free is measured; llama.cpp notes MoE EAGLE-3 can be net-negative
