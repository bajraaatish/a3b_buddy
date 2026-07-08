#!/usr/bin/env python3
"""Persistent Kokoro TTS helper for a3b-buddy.

Spawned by KokoroTTSProvider.swift and kept alive for the app's lifetime so
the ~310MB ONNX model loads exactly once. Line-delimited JSON protocol:

  stdin  (request):   {"id": <int>, "text": <str>}
  stdout (startup):   {"ready": true}
  stdout (response):  {"id": <int>, "wav": <path>, "generation_seconds": <float>,
                       "audio_seconds": <float>}
  stdout (failure):   {"id": <int>, "error": <str>}

The voice and speed come from environment variables so the Swift side is the
single source of truth for the chosen voice.

Expected layout (created by setup, checked by KokoroTTSProvider before spawn):
  ~/Library/Application Support/a3b-buddy/tts/
    kokoro-v1.0.onnx     model weights
    voices-v1.0.bin      voice embeddings
    venv/                python env with kokoro-onnx + soundfile
"""

import json
import os
import sys
import tempfile
import time

MODEL_DIRECTORY = os.path.expanduser("~/Library/Application Support/a3b-buddy/tts")
SELECTED_VOICE = os.environ.get("A3B_KOKORO_VOICE", "af_heart")
SPEECH_SPEED = float(os.environ.get("A3B_KOKORO_SPEED", "1.0"))


def respond(payload):
    print(json.dumps(payload), flush=True)


def main():
    import soundfile
    from kokoro_onnx import Kokoro

    kokoro = Kokoro(
        os.path.join(MODEL_DIRECTORY, "kokoro-v1.0.onnx"),
        os.path.join(MODEL_DIRECTORY, "voices-v1.0.bin"),
    )
    respond({"ready": True})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = request["id"]
            text = request["text"]

            generation_start = time.time()
            samples, sample_rate = kokoro.create(
                text, voice=SELECTED_VOICE, speed=SPEECH_SPEED, lang="en-us"
            )
            generation_seconds = time.time() - generation_start

            wav_file = tempfile.NamedTemporaryFile(
                prefix="a3b-tts-", suffix=".wav", delete=False
            )
            soundfile.write(wav_file.name, samples, sample_rate)

            respond({
                "id": request_id,
                "wav": wav_file.name,
                "generation_seconds": round(generation_seconds, 3),
                "audio_seconds": round(len(samples) / sample_rate, 3),
            })
        except Exception as error:  # keep serving after a bad request
            respond({"id": request_id, "error": str(error)})


if __name__ == "__main__":
    main()
