"""
Inference worker — loads Gemma 3 (GGUF Q8) and exposes inference::run_inference
over the iii RPC mesh.

The engine address is read from III_URL so this worker can run on any VM.
"""

import os
from typing import Any, Dict

from iii import InitOptions, Logger, register_worker
from transformers import AutoModelForCausalLM, AutoTokenizer

iii = register_worker(
    os.environ.get("III_URL", "ws://localhost:49134"),
    InitOptions(worker_name="inference-worker"),
)
logger = Logger()

MODEL_ID  = os.environ.get("MODEL_REPO", "ggml-org/gemma-3-270m-GGUF")
GGUF_FILE = os.environ.get("MODEL_FILE", "gemma-3-270m-Q8_0.gguf")

logger.info("Loading %s / %s ...", MODEL_ID, GGUF_FILE)
tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, gguf_file=GGUF_FILE)
model     = AutoModelForCausalLM.from_pretrained(MODEL_ID, gguf_file=GGUF_FILE)
logger.info("Model loaded.")

tokenizer.chat_template = (
    "{{ bos_token }}"
    "{%- if messages[0]['role'] == 'system' -%}"
    "{%- if messages[0]['content'] is string -%}"
    "{%- set first_user_prefix = messages[0]['content'] + '\n\n' -%}"
    "{%- else -%}"
    "{%- set first_user_prefix = messages[0]['content'][0]['text'] + '\n\n' -%}"
    "{%- endif -%}"
    "{%- set loop_messages = messages[1:] -%}"
    "{%- else -%}"
    "{%- set first_user_prefix = '' -%}"
    "{%- set loop_messages = messages -%}"
    "{%- endif -%}"
    "{%- for message in loop_messages -%}"
    "{%- if (message['role'] == 'user') != (loop.index0 % 2 == 0) -%}"
    "{{ raise_exception('Conversation roles must alternate user/assistant/...') }}"
    "{%- endif -%}"
    "{%- set role = 'model' if message['role'] == 'assistant' else message['role'] -%}"
    "{{ '<start_of_turn>' + role + '\n' + (first_user_prefix if loop.first else '') }}"
    "{%- if message['content'] is string -%}{{ message['content'] | trim }}"
    "{%- else -%}{%- for item in message['content'] -%}"
    "{%- if item['type'] == 'text' -%}{{ item['text'] | trim }}{%- endif -%}"
    "{%- endfor -%}{%- endif -%}"
    "{{ '<end_of_turn>\n' }}"
    "{%- endfor -%}"
    "{%- if add_generation_prompt -%}{{ '<start_of_turn>model\n' }}{%- endif -%}"
)


def run_inference_handler(payload: Dict[str, Any]) -> Dict[str, Any]:
    messages       = payload.get("messages", [])
    max_new_tokens = int(payload.get("max_tokens", 256))

    text   = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = tokenizer(text, return_tensors="pt").to(model.device)
    output = model.generate(
        **inputs,
        max_new_tokens=max_new_tokens,
        do_sample=False,
        pad_token_id=tokenizer.eos_token_id,
    )
    result = tokenizer.decode(output[0][inputs["input_ids"].shape[-1]:], skip_special_tokens=True)
    logger.info("inference::run_inference done, output_len=%d", len(result))
    return {"response": result, "model": GGUF_FILE}


iii.register_function("inference::run_inference", run_inference_handler)
logger.info("inference-worker ready — listening for calls")
