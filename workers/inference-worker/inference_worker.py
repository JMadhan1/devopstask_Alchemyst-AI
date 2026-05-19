"""
Inference worker — loads Gemma 3 270M GGUF via llama-cpp-python and exposes
inference::run_inference over the iii RPC mesh.

Uses llama-cpp-python instead of transformers+gguf to avoid the gguf PyPI
package's broken __version__ string that breaks transformers' import check.
"""

import os
import logging

from iii import InitOptions, Logger, register_worker
from huggingface_hub import hf_hub_download
from llama_cpp import Llama

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

III_URL  = os.environ.get("III_URL",    "ws://localhost:49134")
MODEL_ID  = os.environ.get("MODEL_REPO", "ggml-org/gemma-3-270m-GGUF")
GGUF_FILE = os.environ.get("MODEL_FILE", "gemma-3-270m-Q8_0.gguf")

iii    = register_worker(III_URL, InitOptions(worker_name="inference-worker"))
logger = Logger()

logger.info(f"Downloading {MODEL_ID} / {GGUF_FILE} from HuggingFace …")
model_path = hf_hub_download(repo_id=MODEL_ID, filename=GGUF_FILE)
logger.info(f"Model cached at {model_path} — loading into llama.cpp …")

llm = Llama(
    model_path=model_path,
    n_ctx=2048,
    n_threads=int(os.environ.get("N_THREADS", "2")),
    verbose=False,
)

logger.info("Model loaded and ready.")


def run_inference_handler(payload: dict) -> dict:
    """
    payload: { "messages": [{"role": "user"|"assistant", "content": "..."}],
               "max_tokens": 256 }
    returns: { "response": "...", "model": GGUF_FILE }
    """
    messages       = payload.get("messages", [])
    max_new_tokens = int(payload.get("max_tokens", 256))

    if not messages:
        return {"error": "No messages provided"}

    output = llm.create_chat_completion(
        messages=messages,
        max_tokens=max_new_tokens,
        temperature=0.0,   # greedy for reproducibility
    )

    response_text = output["choices"][0]["message"]["content"]
    logger.info(f"inference::run_inference done, output_len={len(response_text)}")

    return {"response": response_text, "model": GGUF_FILE}


iii.register_function("inference::run_inference", run_inference_handler)
logger.info("inference-worker ready — listening for calls")
