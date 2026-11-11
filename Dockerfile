FROM python:3.12-slim
# 0.8.0 persists the OAuth token via keyring; containers lack a secret
# service, so a plaintext file backend is required.
ENV PYTHON_KEYRING_BACKEND=keyrings.alt.file.PlaintextKeyring
RUN pip install --no-cache-dir google-colab-cli==0.8.0 keyrings.alt \
 && pip uninstall -y pyarrow \
 && useradd -m -u 1000 colab
USER colab
WORKDIR /home/colab
ENTRYPOINT ["colab"]
CMD ["--help"]
