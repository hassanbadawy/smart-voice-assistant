# Supertonic 3 TTS server (ONNX, CPU-only). OpenShift-friendly UBI9 Python.
FROM registry.access.redhat.com/ubi9/python-311:latest

# Bake the Supertonic-3 weights INTO the image so no Hugging Face egress is
# needed at runtime — required for disconnected / air-gapped clusters (e.g. the
# bank cluster, where a runtime HF download hangs and the router returns 504).
# Both `download` (build time) and `serve` (runtime) resolve the model dir from
# SUPERTONIC_CACHE_DIR, so a fixed baked path makes the image self-contained.
ENV SUPERTONIC_CACHE_DIR=/opt/app-root/supertonic-models \
    HF_HOME=/tmp/hf \
    XDG_CACHE_HOME=/tmp/cache

# `supertonic download` fetches the pinned Supertonic-3 snapshot into
# SUPERTONIC_CACHE_DIR at build time. chgrp 0 / chmod g=u makes the weights
# readable by the arbitrary uid (group 0) OpenShift assigns at runtime.
RUN pip install --no-cache-dir 'supertonic[serve]==1.3.1' \
 && supertonic download \
 && rm -rf /tmp/hf /tmp/cache \
 && chgrp -R 0 "$SUPERTONIC_CACHE_DIR" \
 && chmod -R g=u "$SUPERTONIC_CACHE_DIR"

EXPOSE 7788
CMD ["supertonic", "serve", "--host", "0.0.0.0", "--port", "7788"]
