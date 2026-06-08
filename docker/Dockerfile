FROM debian:trixie-slim

# Set noninteractive mode for apt
ENV DEBIAN_FRONTEND=noninteractive

# Install specific versions of required tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        xorriso \
        isolinux \
        squashfs-tools \
        bash \
        apt-utils \
        && rm -rf /var/lib/apt/lists/*

# Default to bash shell
CMD ["/bin/bash"]
