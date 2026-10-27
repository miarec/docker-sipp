# SIPp built from the upstream release source, on Ubuntu.
#
# The versions below are the only place that defines them. build.sh reads them
# to name the image <SIPP_VERSION>-ubuntu<UBUNTU_VERSION without the dot>, for
# example 3.8.0-ubuntu2404. To bump SIPp, change SIPP_VERSION and SIPP_SHA256
# together: see "Bump the SIPp version" in README.md.
ARG UBUNTU_VERSION=24.04
ARG SIPP_VERSION=3.8.0
ARG SIPP_SHA256=a3e3993bf9369caaae1f5366507d429acb9669dcf678cfacfd01c907102f74c3

FROM ubuntu:${UBUNTU_VERSION} AS build
ARG SIPP_VERSION
ARG SIPP_SHA256

# hadolint ignore=DL3008
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        cmake \
        curl \
        dpkg-dev \
        g++ \
        libgsl-dev \
        libgtest-dev \
        libncurses-dev \
        libpcap-dev \
        libsctp-dev \
        libssl-dev \
        ninja-build \
        pkgconf \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL -o sipp.tar.gz \
        "https://github.com/SIPp/sipp/releases/download/v${SIPP_VERSION}/sipp-${SIPP_VERSION}.tar.gz" \
    && echo "${SIPP_SHA256}  sipp.tar.gz" | sha256sum --check --strict \
    && tar -xzf sipp.tar.gz --strip-components=1 \
    && mkdir /source \
    && mv sipp.tar.gz "/source/sipp-${SIPP_VERSION}.tar.gz"

# The same features as Ubuntu's sip-tester package: TLS (always on, OpenSSL
# here), SCTP, PCAP playback, and GSL distributions, with Debian's hardening
# flags, without link-time optimization: see "Known issues" in README.md.
# The release tarball has no bundled GTest, so the unit tests use Ubuntu's
# libgtest-dev.
RUN eval "$(DEB_BUILD_MAINT_OPTIONS="hardening=+all optimize=-lto" dpkg-buildflags --export=sh)" \
    && cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DUSE_SCTP=1 \
        -DUSE_PCAP=1 \
        -DUSE_GSL=1 \
        -DUSE_SYSTEM_GTEST=ON \
    && cmake --build build --target sipp sipp_unittest \
    && ctest --test-dir build --output-on-failure \
    && strip build/sipp \
    && { build/sipp -v || [ $? -eq 99 ]; } | grep -F "SIPp v${SIPP_VERSION}-"

FROM ubuntu:${UBUNTU_VERSION}
ARG UBUNTU_VERSION
ARG SIPP_VERSION

# The runtime libraries of SIPp (libtinfo and libncursesw are already in the
# base image), tcpdump to capture packets in the container, and tini to run
# as PID 1. The base image has sh, getent, hostname, tail, stat, and base64.
# tzdata gives the image /etc/localtime, for UTC. Without it, SIPp fails a
# send on a TCP connection that the peer closed instead of making the
# connection again: see "Known issues" in README.md.
# hadolint ignore=DL3008
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libgsl27 \
        libpcap0.8t64 \
        libsctp1 \
        libssl3t64 \
        tcpdump \
        tini \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/build/sipp /usr/local/bin/sipp
# SIPp is GPL-2.0-or-later: the image carries the source that it was built
# from, the verified release tarball, next to the binary.
COPY --from=build /source/ /usr/share/doc/sipp/
# "sipp -v" exits with 99. A missing runtime library makes it exit with 127 and
# fails the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN { sipp -v || [ $? -eq 99 ]; } | grep -F "SIPp v${SIPP_VERSION}-"

LABEL org.opencontainers.image.title="sipp" \
      org.opencontainers.image.description="SIPp ${SIPP_VERSION} built from the upstream source on Ubuntu ${UBUNTU_VERSION}" \
      org.opencontainers.image.version="${SIPP_VERSION}" \
      org.opencontainers.image.source="https://github.com/miarec/docker-sipp" \
      org.opencontainers.image.licenses="GPL-2.0-or-later" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:${UBUNTU_VERSION}"

# tini reaps the SIPp and tcpdump processes that "docker exec" leaves behind
# and stops the container at once on "docker stop". The default command keeps
# the container running for "docker exec".
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]
