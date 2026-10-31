# SIPp built from MiaRec's fork, miarec/sipp: an upstream release with
# MiaRec's fixes, on Ubuntu. See "Why the fork" in README.md.
#
# The versions below are the only place that defines them. build.sh reads them
# to name the image <SIPP_VERSION>-ubuntu<UBUNTU_VERSION without the dot>, for
# example 3.8.0-miarec.2-ubuntu2404. SIPP_VERSION is a tag of the fork,
# v<SIPP_VERSION>, at the commit SIPP_COMMIT. To bump SIPp, change the two
# together: see "Bump the SIPp version" in README.md.
ARG UBUNTU_VERSION=24.04
ARG SIPP_VERSION=3.8.0-miarec.2
ARG SIPP_COMMIT=97b1f0046a28264217ec14c3f34e01fba09f944b
ARG SIPP_REPOSITORY=https://github.com/miarec/sipp

FROM ubuntu:${UBUNTU_VERSION} AS build
ARG SIPP_VERSION
ARG SIPP_COMMIT
ARG SIPP_REPOSITORY

# hadolint ignore=DL3008
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        cmake \
        dpkg-dev \
        g++ \
        git \
        libgsl-dev \
        libgtest-dev \
        libncurses-dev \
        libpcap-dev \
        libsctp-dev \
        libssl-dev \
        ninja-build \
        pkgconf \
    && rm -rf /var/lib/apt/lists/*

# The tag must be at SIPP_COMMIT: a tag that moved fails the build. SIPp's
# CMake build names the version after the tag (git describe), and takes
# pugixml from its submodule. The image keeps the source that it was built
# from, without the git history, as a tarball.
WORKDIR /src
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN git clone --quiet --depth 1 --branch "v${SIPP_VERSION}" "${SIPP_REPOSITORY}" . \
    && test "$(git rev-parse HEAD)" = "${SIPP_COMMIT}" \
    && git submodule update --quiet --init --depth 1 third_party/pugixml \
    && mkdir /source \
    && tar -czf "/source/sipp-${SIPP_VERSION}.tar.gz" --exclude=.git --transform "s,^\.,sipp-${SIPP_VERSION}," .

# The same features as Ubuntu's sip-tester package: TLS (always on, OpenSSL
# here), SCTP, PCAP playback, and GSL distributions, with Debian's hardening
# flags, without link-time optimization: see "Known issues" in README.md.
# The unit tests use Ubuntu's libgtest-dev, not the gtest submodule. The
# regression tests of the fork's fixes and options run too.
RUN eval "$(DEB_BUILD_MAINT_OPTIONS="hardening=+all optimize=-lto" dpkg-buildflags --export=sh)" \
    && cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DUSE_SCTP=1 \
        -DUSE_PCAP=1 \
        -DUSE_GSL=1 \
        -DUSE_SYSTEM_GTEST=ON \
    && cmake --build build --target sipp sipp_unittest \
    && ctest --test-dir build --output-on-failure \
    && SIPP="$PWD/build/sipp" regress/srtp-multipart-offer/run | tee /dev/stderr | grep -q '^Testing srtp-multipart-offer: \.$' \
    && SIPP="$PWD/build/sipp" regress/srtp-rtp-seq/run | tee /dev/stderr | grep -q '^Testing srtp-rtp-seq: \.$' \
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
# from, the tarball of the fork's tag, next to the binary.
COPY --from=build /source/ /usr/share/doc/sipp/
# "sipp -v" exits with 99. A missing runtime library makes it exit with 127 and
# fails the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN { sipp -v || [ $? -eq 99 ]; } | grep -F "SIPp v${SIPP_VERSION}-"

LABEL org.opencontainers.image.title="sipp" \
      org.opencontainers.image.description="SIPp ${SIPP_VERSION} built from miarec/sipp on Ubuntu ${UBUNTU_VERSION}" \
      org.opencontainers.image.version="${SIPP_VERSION}" \
      org.opencontainers.image.source="https://github.com/miarec/docker-sipp" \
      org.opencontainers.image.licenses="GPL-2.0-or-later" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:${UBUNTU_VERSION}"

# tini reaps the SIPp and tcpdump processes that "docker exec" leaves behind
# and stops the container at once on "docker stop". The default command keeps
# the container running for "docker exec".
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]
