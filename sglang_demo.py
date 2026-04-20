"""Smoke-test for the sglang install — tiny model, two prompts.

Run inside the sglang venv:
    source /workspace/venv-sglang/bin/activate
    python /workspace/tools/sglang_demo.py

Uses sgl.Engine (offline batch) instead of the HTTP server so the script is
fully self-contained. The __main__ guard is required: sglang spawns workers
via multiprocessing "spawn", and without the guard the children re-enter
Engine() and fork-bomb.
"""

import sglang as sgl


def main() -> None:
    llm = sgl.Engine(
        model_path="facebook/opt-125m",
        mem_fraction_static=0.3,
        disable_cuda_graph=True,
    )
    try:
        prompts = ["Hello, my name is", "The capital of France is"]
        sampling = {"temperature": 0.8, "top_p": 0.95, "max_new_tokens": 32}
        for prompt, out in zip(prompts, llm.generate(prompts, sampling)):
            print(f"[prompt] {prompt!r}")
            print(f"[output] {out['text']!r}\n")
    finally:
        llm.shutdown()


if __name__ == "__main__":
    main()
