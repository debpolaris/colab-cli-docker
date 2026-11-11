FROM python:3.12-slim
RUN pip install --no-cache-dir google-colab-cli==0.7.5 \
 && pip uninstall -y pyarrow keyrings.alt \
 && useradd -m -u 1000 colab
USER colab
WORKDIR /home/colab
ENTRYPOINT ["colab"]
CMD ["--help"]
