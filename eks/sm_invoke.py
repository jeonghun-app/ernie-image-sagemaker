# Copyright (c) 2026 ernie-image-sagemaker contributors
# SPDX-License-Identifier: Apache-2.0
"""Call the ERNIE-Image SageMaker endpoint directly (no Lambda, no API Gateway), e.g. from a Pod on Amazon EKS.

Flow: prompt -> Amazon Translate (to English, skipped for English prompts) -> SageMaker InvokeEndpoint
      (Inference Component) -> PNG bytes.
Credentials: EKS Pod Identity or IRSA (boto3 picks them up automatically). No access keys in code.
IAM: sagemaker:InvokeEndpoint on the endpoint and inference component ARNs (+ translate:TranslateText unless English).

usage: python sm_invoke.py prompt.txt [--steps 10] [--size 1344x768] [--seed 1] [--concurrency 1 --total 1]
env  : SM_ENDPOINT_NAME, SM_INFERENCE_COMPONENT (required)
       AWS_REGION (else the SDK default region), SM_MAX_IN_FLIGHT (default 4),
       SM_SOURCE_LANG (prompt language, default ko; en = no translation)
requires: pip install boto3
"""
import argparse
import base64
import concurrent.futures as cf
import json
import os
import statistics
import sys
import threading
import time

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

REGION = os.environ.get("AWS_REGION") or None  # None: the SDK default region (profile, instance metadata)
ENDPOINT = os.environ["SM_ENDPOINT_NAME"]
IC = os.environ["SM_INFERENCE_COMPONENT"]
# Keep in-flight requests <= model copies (InstanceCount x 4). Extra requests queue on the GPUs and get slower.
MAX_IN_FLIGHT = int(os.environ.get("SM_MAX_IN_FLIGHT", "4"))
if MAX_IN_FLIGHT < 1:
    raise SystemExit("SM_MAX_IN_FLIGHT must be >= 1")
# The model expects English prompts. Other languages are translated with Amazon Translate first.
SOURCE_LANG = os.environ.get("SM_SOURCE_LANG", "ko")

translate = boto3.client("translate", region_name=REGION, config=Config(read_timeout=5, retries={"max_attempts": 2}))
# SageMaker real-time invocation is limited to 60 s; do not let the SDK retry a generation automatically.
runtime = boto3.client("sagemaker-runtime", region_name=REGION,
                       config=Config(read_timeout=65, retries={"max_attempts": 0}, max_pool_connections=64))
slots = threading.BoundedSemaphore(MAX_IN_FLIGHT)


def generate(prompt, size="1344x768", steps=10, seed=None, guidance_scale=4.0):
    """Return (png_bytes, info). Raises on failure."""
    t0 = time.time()
    if SOURCE_LANG == "en":
        prompt_en = prompt
    else:
        prompt_en = translate.translate_text(Text=prompt, SourceLanguageCode=SOURCE_LANG,
                                             TargetLanguageCode="en")["TranslatedText"]
    t1 = time.time()
    body = {"prompt": prompt_en, "size": size, "n": 1, "num_inference_steps": steps, "guidance_scale": guidance_scale}
    if seed is not None:
        body["seed"] = seed
    with slots:
        r = runtime.invoke_endpoint(EndpointName=ENDPOINT, InferenceComponentName=IC, ContentType="application/json",
                                    CustomAttributes="route=/v1/images/generations", Body=json.dumps(body))
    png = base64.b64decode(json.loads(r["Body"].read())["data"][0]["b64_json"])
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("invalid image")
    return png, {"prompt_translated": prompt_en, "translate_seconds": round(t1 - t0, 2),
                 "generate_seconds": round(time.time() - t1, 2)}


def classify(e):
    """Map errors to a retry decision for your backend."""
    if isinstance(e, ClientError):
        code = e.response["Error"]["Code"]
        if code in ("ThrottlingException", "ServiceUnavailable", "InternalFailure"):
            return code, "retry with backoff (1, 2, 4 s, max 3)"
        if code == "ModelError":
            return code, "retry once; check the endpoint log if repeated"
        return code, "do not retry (permission or input problem)"
    if isinstance(e, BotoCoreError):  # ReadTimeoutError etc.
        return type(e).__name__, "retry at most once (the image may already have been generated)"
    return type(e).__name__, "check input / response"


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt_file")
    ap.add_argument("--steps", type=int, default=10)
    ap.add_argument("--size", default="1344x768")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--concurrency", type=int, default=1)
    ap.add_argument("--total", type=int, default=1)
    ap.add_argument("--out", default="result")
    a = ap.parse_args()
    if a.concurrency < 1 or a.total < 1:
        ap.error("--concurrency and --total must be >= 1")
    with open(a.prompt_file, encoding="utf-8") as f:
        prompt = f.read().strip()

    def one(i):
        t = time.time()
        try:
            png, info = generate(prompt, a.size, a.steps, a.seed if a.total == 1 else i)
            path = f"{a.out}.png" if a.total == 1 else f"{a.out}_{i:03d}.png"
            with open(path, "wb") as f:
                f.write(png)
            return "200", time.time() - t, info
        except Exception as e:  # noqa: BLE001  report every failure per request, keep the others running
            code, action = classify(e)
            return code, time.time() - t, {"error": str(e)[:200], "action": action}

    t0 = time.time()
    with cf.ThreadPoolExecutor(a.concurrency) as ex:
        res = list(ex.map(one, range(1, a.total + 1)))
    wall = time.time() - t0
    if a.total == 1:
        print(json.dumps({"status": res[0][0], "seconds": round(res[0][1], 2), **res[0][2]}, ensure_ascii=False, indent=2))
    else:
        ok = sorted(s for c, s, _ in res if c == "200")
        codes = {}
        for c, _, _ in res:
            codes[c] = codes.get(c, 0) + 1
        print(f"concurrency={a.concurrency} total={a.total} results={codes} wall={wall:.1f}s "
              f"images/min={len(ok) / wall * 60:.2f}")
        if ok:
            p95 = ok[min(len(ok) - 1, round(0.95 * (len(ok) - 1)))]
            print(f"latency p50={statistics.median(ok):.1f}s p95={p95:.1f}s max={ok[-1]:.1f}s")
    sys.exit(0 if all(c == "200" for c, _, _ in res) else 1)
