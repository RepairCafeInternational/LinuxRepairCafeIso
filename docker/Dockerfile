FROM debian:trixie-slim

# Set noninteractive mode for apt
ENV DEBIAN_FRONTEND=noninteractive

# Install specific versions of required tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        xorriso=1.5.6-1.2+b1 \
        isolinux=3:6.04~git20190206.bf6db5b4+dfsg1-3.1 \
        squashfs-tools=1:4.6.1-1 \
        bash=5.2.37-2+b5 \
        apt-utils \
        && rm -rf /var/lib/apt/lists/*

# Default to bash shell
CMD ["/bin/bash"]
