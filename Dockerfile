FROM python:3.12-slim
RUN pip install --no-cache-dir google-colab-cli==0.7.5 keyrings.alt \
 && useradd -m -u 1000 colab
USER colab
WORKDIR /home/colab
ENV PYTHON_KEYRING_BACKEND=keyrings.alt.file.PlaintextKeyring
ENTRYPOINT ["colab"]
CMD ["--help"]
