# Smart Voice Assistant — static UI + stdlib config/TTS-proxy server.
# UBI9 Python (OpenShift-friendly: runs as uid 1001, group 0).
FROM registry.access.redhat.com/ubi9/python-311:latest

WORKDIR /opt/app-root/src

# App is pure standard library — no pip install needed.
COPY --chown=1001:0 . /opt/app-root/src

# Make the app dir group-writable so config.yaml can be written under
# OpenShift's arbitrary uid (always a member of group 0).
USER 0
RUN rm -f config.yaml && chmod -R g+rwX /opt/app-root/src
USER 1001

EXPOSE 8080
CMD ["python", "server.py", "--host", "0.0.0.0", "--port", "8080"]
