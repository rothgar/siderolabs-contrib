# Rendered manifests are NOT committed. Run `make charts` before the first
# `omnictl cluster template sync` and any time you bump a pinned version.
#
# Requires: helm, curl.

DRA_DRIVER_VERSION ?= 0.4.1
LWS_VERSION        ?= 0.9.0
DRANET_VERSION     ?= v1.2.0

MANIFESTS := manifests
RENDERED  := \
	$(MANIFESTS)/dranet.yaml \
	$(MANIFESTS)/dra-driver-nvidia-gpu.yaml \
	$(MANIFESTS)/lws.yaml

.PHONY: charts clean

charts: $(RENDERED)
	@echo "==> ready to sync: omnictl cluster template sync --file cluster.yaml"

$(MANIFESTS)/dranet.yaml:
	@echo "==> dranet $(DRANET_VERSION)"
	curl -sSL -o $@ \
	  "https://raw.githubusercontent.com/kubernetes-sigs/dranet/$(DRANET_VERSION)/install.yaml"

$(MANIFESTS)/dra-driver-nvidia-gpu.yaml: $(MANIFESTS)/dra-driver-nvidia-gpu.values.yaml
	@echo "==> dra-driver-nvidia-gpu $(DRA_DRIVER_VERSION)"
	helm template dra-driver-nvidia-gpu \
	  "oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu" \
	  --version "$(DRA_DRIVER_VERSION)" \
	  --namespace nvidia-system \
	  --values $(MANIFESTS)/dra-driver-nvidia-gpu.values.yaml \
	  --include-crds > $@

$(MANIFESTS)/lws.yaml:
	@echo "==> lws $(LWS_VERSION)"
	helm template lws \
	  "oci://registry.k8s.io/lws/charts/lws" \
	  --version "$(LWS_VERSION)" \
	  --namespace lws-system \
	  --include-crds > $@

clean:
	rm -f $(RENDERED)
