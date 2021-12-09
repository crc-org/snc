# This Dockerfile is used by openshift CI
# It builds an image containing snc code and nss-wrapper for remote deployments, as well as the google cloud-sdk for nested GCE environments.
FROM scratch AS builder
WORKDIR /code-ready/snc
COPY . .

FROM centos:8
COPY --from=builder /code-ready/snc /opt/snc
COPY --from=builder /code-ready/snc/images/openshift-ci/mock-nss.sh /bin/mock-nss.sh
COPY --from=builder /code-ready/snc/images/openshift-ci/google-cloud-sdk.repo /etc/yum.repos.d/google-cloud-sdk.repo

RUN yum update -y && \
    yum install --setopt=tsflags=nodocs -y \
    gettext \
    google-cloud-sdk-365.0.1 \
    nss_wrapper \
    openssh-clients && \
    yum clean all && rm -rf /var/cache/yum/*
RUN mkdir /output && chown 1000:1000 /output
USER 1000:1000
ENV PATH /bin
ENV HOME /output
WORKDIR /output
