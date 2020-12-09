ARG OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
FROM ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}

RUN curl -L https://github.com/mikefarah/yq/releases/download/3.4.1/yq_linux_amd64 > /usr/bin/yq && chmod +x /usr/bin/yq

RUN yq w -i ./release-manifests/0000_50_cluster-authentication-operator_02_config.cr.yaml 'spec.unsupportedConfigOverrides.useUnsupportedUnsafeNonHANonProductionUnstableOAuthServer' true

RUN rm /usr/bin/yq

RUN rm /release-manifests/0000_90_cluster-update-keys_configmap.yaml
RUN touch /release-manifests/image-references /release-manifests/release-metadata
