# docker-sipp

A Docker image of [SIPp](https://github.com/SIPp/sipp), built on Ubuntu from MiaRec's fork, [miarec/sipp](https://github.com/miarec/sipp): an upstream release with MiaRec's fixes (see [Why the fork](#why-the-fork)). MiaRec's end-to-end tests use it as the SIP and RTP call partner.

## Image tags

```text
ghcr.io/miarec/sipp:<SIPp version>-<base>
```

For example, `ghcr.io/miarec/sipp:3.8.0-miarec.2-ubuntu2404` is SIPp 3.8.0 with MiaRec's fixes of the fork's tag `v3.8.0-miarec.2`, on Ubuntu 24.04. The tags of the upstream releases, such as `3.8.0-ubuntu2404`, are from earlier versions of this repository. Each tag is multi-arch: `linux/amd64` and `linux/arm64`. The per-architecture tags, such as `3.8.0-miarec.2-ubuntu2404-arm64`, are intermediate build results. Don't use them.

The workflow pushes the tag of the current version again on each change to `master`, so that tag also gets the latest Ubuntu security updates. The tags of earlier versions stay in the registry, but no longer get updates.

## What the image contains

- `sipp` in `/usr/local/bin`, with TLS (OpenSSL), SCTP, PCAP playback, and GSL distributions. These are the features of Ubuntu's `sip-tester` package. The `Dockerfile` lists the CMake options.
- `tcpdump`, to capture packets in the container.
- `tzdata`, so that the image has `/etc/localtime`, set to UTC. SIPp needs it to make a TCP connection again: see [Known issues](#known-issues).
- The tools of the Ubuntu base image, such as `sh`, `getent`, `hostname`, `tail`, `stat`, and `base64`.
- `tini` as the entry point. It reaps the processes that `docker exec` leaves behind, and it stops the container at once on `docker stop`. Don't add `--init` to `docker run` or `init: true` to Compose: the image already has an init.

The default command is `sleep infinity`. It keeps the container running, so that you can run SIPp in it with `docker exec`.

## Run the image

Run SIPp directly:

```bash
docker run --rm --network host ghcr.io/miarec/sipp:3.8.0-miarec.2-ubuntu2404 \
  sipp 192.0.2.10:5060 -sn uac -m 1
```

Use `--network host` when SIPp sends or receives RTP to or from other hosts. On a bridge network, Docker translates the addresses of the packets to and from other hosts, so the addresses in the SDP don't match the addresses that the packets use.

Or start a long-running container and run SIPp in it:

```bash
docker run --detach --name sipp --network host \
  --volume "$PWD/scenarios:/scenarios:ro" \
  ghcr.io/miarec/sipp:3.8.0-miarec.2-ubuntu2404
docker exec sipp sipp 192.0.2.10:5060 -sf /scenarios/uac.xml -m 1
```

To capture packets in the container, run `tcpdump`. It needs the `NET_RAW` capability, which Docker grants by default.

## Why the fork

SIPp 3.8.0 doesn't take a multipart SDP that it sends, such as a SIPREC INVITE with its metadata, for an offer: it takes such a body only when it receives one. A SIPREC client that offers SRTP with two `a=crypto` lines then takes the answer for an offer, and keeps encrypting with the key of the first line, also when the answer takes the second one. The peer then drops every packet. The fork fixes it in commit [831f7a0](https://github.com/miarec/sipp/commit/831f7a05739e0673411223f28f68d2402084cf3f), with the regression test `regress/srtp-multipart-offer`, which the image build runs.

SIPp 3.8.0 starts the RTP sequence number of each stream at 0, so its first wrap comes after 65536 packets, almost 22 minutes at 20 ms a packet. A test of a receiver's rollover counter (RFC 3711, section 3.3.1) then takes that long. The fork adds the option `-rtp_seq <n>`, the first sequence number of each stream, in commit [97b1f00](https://github.com/miarec/sipp/commit/97b1f0046a28264217ec14c3f34e01fba09f944b), with the regression test `regress/srtp-rtp-seq`, which the image build runs.

The fork's tags are `v<upstream release>-miarec.<n>`. They aren't sent upstream.

## Why SIPp 3.8.0 and not Ubuntu's package

Ubuntu 24.04 packages SIPp 3.7.2 as `sip-tester`. SIPp 3.7.0 to 3.7.2 limit how fast one process sends `rtp_stream` RTP. After each packet, `rtpstream_playrtptask()` in `src/rtpstream.cpp` waits in `select()` for up to 10 ms, and it holds the process-wide `uacAudioMutex` while it waits. One SIPp process therefore sends at most about 100 `rtp_stream` packets a second in total, whatever the number of calls or `-rtp_threadtasks`. A call with a 20 ms packet time needs 50 packets a second, so more than two calls at once get less than that.

SIPp 3.7.3 fixed the bug in commit [54f008c6](https://github.com/SIPp/sipp/commit/54f008c6ea94806535bbc052bdfc9da69e1c9ad8), "Don't block on select() in rtpstream_playrtptask". The smoke test proves that the bug is absent: see [Test the image](#test-the-image).

SIPp 3.7.9 stops a call's `rtp_stream` RTP for good after an ICMP port unreachable. SIPp's RTP socket is a connected UDP socket, so the kernel reports the ICMP error of one packet on the next `send()`, as `ECONNREFUSED`. SIPp 3.7.9 takes that error as permanent, and closes the socket. The call then sends no RTP, also after a re-INVITE gives SIPp a new remote port. This happens when the peer closes its media port during the call, for example when an SBC deletes the call after a media timeout and a re-INVITE creates it again. SIPp 3.8.0 fixed the bug in commit [ef2d956](https://github.com/SIPp/sipp/commit/ef2d9564fb694befaba05f326ff81110b81aa97b), "rtp_stream: go on playing when the peer's port is not open yet": it sends the packet again. This image uses SIPp 3.8.0.

## Build the image

You need Docker with BuildKit, which is the default builder since Docker 23.

```bash
./build.sh
```

The script builds the image for the platform of your host, tags it as `ghcr.io/miarec/sipp:<SIPp version>-ubuntu<Ubuntu version>`, and prints the tag. It reads the versions from the `ARG` lines at the top of the `Dockerfile`. The script takes these environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `IMAGE` | `ghcr.io/miarec/sipp` | The repository part of the tag. |
| `TAG_SUFFIX` | none | Text to append to the tag, such as `-arm64`. |
| `IMAGE_REVISION` | The commit at `HEAD` | The value of the `org.opencontainers.image.revision` label. |

To print the tag without a build, run `./build.sh --print-tag`.

The build clones the fork at the tag `v<SIPP_VERSION>`, checks that the tag is at `SIPP_COMMIT`, builds SIPp with CMake, and runs the SIPp unit tests and the regression tests of the fork's fixes.

## Test the image

You need Docker, Bash, and Python 3.

```bash
tests/smoke-test.sh ghcr.io/miarec/sipp:3.8.0-miarec.2-ubuntu2404
```

The test checks that the image has the tools that the end-to-end tests run, and that SIPp has TLS, SCTP, and PCAP support.

Then it proves that SIPp makes a TCP connection again when the peer closed it during a call:

1. A SIPp UAS starts on a Docker network of its own, and listens on TCP.
2. A SIPp UAC ([`tests/scenarios/uac-reconnect.xml`](tests/scenarios/uac-reconnect.xml)) calls it over TCP, with `-reconnect_close false -max_reconnect 1` and the message trace (`-trace_msg`).
3. The UAS restarts during the call, which closes the connection. After its restart, it answers a BYE ([`tests/scenarios/uas-bye.xml`](tests/scenarios/uas-bye.xml)).
4. The test fails if the UAC doesn't send its BYE on a new connection and get the 200 OK.

Then it proves that SIPp sends RTP at the full rate for several calls at once:

1. The test writes an A-law WAV file.
2. A SIPp UAS ([`tests/scenarios/uas.xml`](tests/scenarios/uas.xml)) starts on a Docker network of its own.
3. `tcpdump` starts in the network namespace of the UAS, and records each packet that reaches the RTP ports of the UAS.
4. A SIPp UAC ([`tests/scenarios/uac.xml`](tests/scenarios/uac.xml)) makes several calls at once. Each call loops the WAV file with `<exec rtp_stream="/audio/alaw.wav,-1,8,PCMA/8000"/>`.
5. The test counts the packets of each call. It fails if a call gets less than the minimum rate, if a call stops sending early, or if a call is missing.

The test takes these environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `CALLS` | `8` | The number of calls at once. |
| `TALK_SECONDS` | `10` | How long each call sends RTP. |
| `MIN_RATE` | `45` | The minimum packets a second for each call. A 20 ms packet time gives 50. |

SIPp 3.7.2 fails the test with the default settings, because 8 calls share about 100 packets a second.

## Continuous integration

The `Image` workflow ([`.github/workflows/image.yml`](.github/workflows/image.yml)) builds the image on an `ubuntu-24.04` runner for amd64 and on an `ubuntu-24.04-arm` runner for arm64, and runs the smoke test on each.

- On pull requests, the workflow builds and tests the image, but doesn't push it.
- On pushes to `master` that change the image, its build, or its tests, the workflow pushes the per-architecture tags, and then the multi-arch tag.
- When you run the workflow manually (`workflow_dispatch`) on `master`, it builds, tests, and pushes. A manual run on another branch only builds and tests.

The first push creates the GHCR package `miarec/sipp`. After the first push, check that the package is public in its settings, and change its visibility if it isn't. Anyone can pull a public image without logging in.

## Bump the SIPp version

1. In [miarec/sipp](https://github.com/miarec/sipp), bring the fix or the upstream release to `master`, and tag the commit `v<upstream release>-miarec.<n>`, such as `v3.8.0-miarec.2`. Push the tag to the fork only, never upstream.
2. In the `Dockerfile`, change `SIPP_VERSION` to the tag without the `v`, and `SIPP_COMMIT` to the tag's commit, together:

   ```bash
   git ls-remote https://github.com/miarec/sipp 'refs/tags/v3.8.0-miarec.2^{}'
   ```

3. Add the regression test of a new fix to the build of the `Dockerfile`, after `ctest`, as `regress/srtp-multipart-offer` is.
4. Read the release notes for changes to the CMake options, and check whether the release fixes a [known issue](#known-issues). Remove the workaround of an issue that the release fixes.
5. Build and test the image locally, and then open a pull request. The merge to `master` publishes the new tag. The tags of earlier versions stay in the registry.

To change the Ubuntu version, change `UBUNTU_VERSION`. Check the names of the runtime library packages in the `Dockerfile`, because they can change between Ubuntu releases. For example, Ubuntu 24.04 renamed `libssl3` to `libssl3t64`.

## Known issues

### SIPp 3.8.0's unit tests don't link with link-time optimization

The `Dockerfile` builds SIPp with Debian's hardening flags from `dpkg-buildflags`, but turns off link-time optimization (LTO) with `optimize=-lto`. Ubuntu 24.04's `dpkg-buildflags` turns LTO on by default (`-flto=auto`), and SIPp's own build doesn't use it.

With LTO, the link of SIPp 3.8.0's unit tests, `sipp_unittest`, fails. GCC checks the C++ One Definition Rule across the source files at link time, and finds two different types named `SrtpSuite`: one in `src/call.cpp`, the table of SRTP suites that SIPp uses, and one in the unit tests of `src/jlsrtp.cpp`, inside `#ifdef GTEST`. GCC reports it as a `-Wodr` warning, and SIPp's `CMakeLists.txt` builds with `-Werror`, so the warning stops the build. The `sipp` binary has only the first type, and links with LTO too, but the image build runs the unit tests, so it needs both to link.

Without LTO, the build is the same as SIPp's own build. The shipped `sipp` binary loses the cross-file optimization of LTO, which doesn't matter for a test tool.

A SIPp release that renames the test type, or puts it in an anonymous namespace, fixes it. Then remove `optimize=-lto` from the `Dockerfile`.

### SIPp 3.8.0 doesn't make a TCP connection again without /etc/localtime

The image installs `tzdata`, so that it has `/etc/localtime`. The Ubuntu base image has no `/etc/localtime`.

SIPp has no file name of its own here. The bug is in how it reads `errno`, and a missing `/etc/localtime` is one way to change `errno` at the wrong time:

1. With `-reconnect_close false`, SIPp keeps the calls of a TCP connection that the peer closed, and sends their next request on a new connection. The write of that request to the closed connection fails with `EPIPE`: `SIPpSocket::write_primitive()` in `src/socket.cpp`.
2. With the message trace on (`-trace_msg`), `SIPpSocket::write()` then writes the failed message to the trace. The trace line starts with the time, from `CStat::formatTime()` in `src/stat.cpp`, which calls `localtime()`.
3. Without `TZ`, glibc's `localtime()` checks its default time zone file, `/etc/localtime`, on each call. When the file is missing, glibc uses UTC, but each call sets `errno` to `ENOENT`.
4. `SIPpSocket::write_error()` reads `errno`, not the error of the write. It makes the connection again only for `EPIPE`, `ECONNRESET`, `ECONNREFUSED`, or `ENOTCONN`. For `ENOENT`, it warns `Unable to send TCP message: No such file or directory`, and the call fails.

Any other call that sets `errno` between the write and `write_error()` would have the same effect. Without the message trace, nothing calls `localtime()` there, and SIPp makes the connection again.

To check whether a SIPp release fixes it, build the image without `tzdata` and run the [smoke test](#test-the-image): the TCP reconnection test fails with the bug. A release that passes `write_error()` the `errno` of the write fixes it. Then remove `tzdata` from the `Dockerfile`, unless the image needs it for another reason.

## License

The files in this repository are under the [MIT License](LICENSE). SIPp is under the GNU General Public License, version 2 or later. The image carries the SIPp source that it was built from, a tarball of the fork's tag without its git history, in `/usr/share/doc/sipp/`, and its `org.opencontainers.image.licenses` label names SIPp's license.
