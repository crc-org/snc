FROM registry.access.redhat.com/ubi9:9.5 AS builder

RUN dnf install -y fuse-devel gcc git make

RUN git clone https://github.com/ftrvxmtrx/9pfs /src/9pfs

WORKDIR /src/9pfs

RUN git checkout af2e820f10af4781df8e55c05a79864a005817eb

RUN make
