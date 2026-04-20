"""Smoke-test for the vllm install — tiny model, single prompt.

Run inside the vllm venv:
    source /workspace/venv-vllm/bin/activate
    cd /tmp  # NOT /workspace — see note below
    python /workspace/tools/vllm_demo.py

Note: do not run python from /workspace. It contains a `vllm/` subdir (the git
repo root), which has no __init__.py and so Python's PEP 420 namespace-package
resolver picks it up and shadows the real editable install in site-packages —
`import vllm` then silently resolves to an empty namespace package.
"""

from vllm import LLM, SamplingParams


def main() -> None:
    llm = LLM(
        model="facebook/opt-125m",
        gpu_memory_utilization=0.3,
        max_model_len=512,
        enforce_eager=True,
    )
    prompts = ["Hello, my name is", "The capital of France is"]
    params = SamplingParams(temperature=0.8, top_p=0.95, max_tokens=32)
    for out in llm.generate(prompts, params):
        print(f"[prompt] {out.prompt!r}")
        print(f"[output] {out.outputs[0].text!r}\n")


if __name__ == "__main__":
    main()
