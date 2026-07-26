# Supertonic 3 TTS server (ONNX, CPU-only). OpenShift-friendly UBI9 Python.
FROM registry.access.redhat.com/ubi9/python-311:latest
# HF weights are pulled at runtime → cache in a writable (arbitrary-uid) dir
ENV HF_HOME=/tmp/hf XDG_CACHE_HOME=/tmp/cache
RUN pip install --no-cache-dir 'supertonic[serve]'
EXPOSE 7788
CMD ["supertonic", "serve", "--host", "0.0.0.0", "--port", "7788"]
