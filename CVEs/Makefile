.PHONY: scan-pre-patch \
	patch scan-post-patch \
	download-deps \
	kustomize-build-all \
	generate-image-list-from-manifests \
	trivy-download-db \
	scan-vulns \
	concat-multiple-kfd-images-list

KFD_VERSIONS := $(shell find . -maxdepth 1 -mindepth 1 -type d -name "v*"  | cut -d/ -f2 | sort )
DRY_RUN := 1
PATCH_FILE_IMAGE_LIST_TO_PATCHING := all_kfd_images.txt
TRIVY_CACHE_DIR := /tmp/.cache/trivy

all: trivy-download-db scan-pre-patch concat-multiple-kfd-images-list patch scan-post-patch

scan-pre-patch:
	@for version in $(KFD_VERSIONS); do \
		( \
			[ ! -e $$version/built.yaml ] && $(MAKE) download-deps KFD_VERSION=$$version; \
			[ ! -e $$version/built.yaml ] && $(MAKE) kustomize-build-all KFD_VERSION=$$version; \
			[ ! -e $$version/images.txt ] && $(MAKE) generate-image-list-from-manifests KFD_VERSION=$$version; \
			$(MAKE) scan-vulns KFD_VERSION=$$version LIST_FILE=$$version/images.txt OUTPUT_FILE=$$version/FURY-CVEs.md;  \
		) & \
	done; \
	wait

concat-multiple-kfd-images-list:
	@for version in $(KFD_VERSIONS); do \
	  cat $$version/images.txt >> $(PATCH_FILE_IMAGE_LIST_TO_PATCHING).tmp; \
	done
	sort --unique "$(PATCH_FILE_IMAGE_LIST_TO_PATCHING).tmp" --output $(PATCH_FILE_IMAGE_LIST_TO_PATCHING)
	rm $(PATCH_FILE_IMAGE_LIST_TO_PATCHING).tmp

patch:
	DRY_RUN=$(DRY_RUN) TRIVY_CACHE_DIR=$(TRIVY_CACHE_DIR) ./patch_images_with_copacetic.sh -i "$(IMAGE_TO_PATCH)" -l "$(PATCH_FILE_IMAGE_LIST_TO_PATCHING)" -o "$(PATCH_REPORT_OUTPUT_FILE)"

scan-post-patch:
	@for version in $(KFD_VERSIONS); do \
  		( \
			sed s#"registry.sighup.io/fury"#"registry.sighup.io/fury-secured"# $$version/images.txt > $$version/images-patched.txt; \
			$(MAKE) scan-vulns KFD_VERSION=$$version LIST_FILE=$$version/images-patched.txt OUTPUT_FILE=$$version/FURY-SECURED-CVEs.md;  \
		) & \
	done; \
	wait

download-deps:
	furyctl -c $(KFD_VERSION)/furyctl.yaml -o $(KFD_VERSION) download dependencies

kustomize-build-all:
	# to remove KFD unused cluster-autoscaler images
	KFD_VERSION=$(KFD_VERSION)
	echo "" > $(KFD_VERSION)/built.yaml
	for kustomize in `find $(KFD_VERSION)/.furyctl/sighup/vendor/modules \
		-not -path "*/cluster-autoscaler/base/*" \
		-not -path "*/tests/*" \
		-not -path "*/examples/*" \
		-name "kustomization.y*ml" \
		\( -path "*/cluster-autoscaler/$$(echo $${KFD_VERSION} | cut -d'.' -f1,2)*/*" -or -not -path "*/cluster-autoscaler/*" \)`; do \
			`find $(KFD_VERSION)/.furyctl/bin -name kustomize -type f` build `dirname $$kustomize` >> $(KFD_VERSION)/built.yaml; \
	done

generate-image-list-from-manifests:
	awk '$$0 ~ /registry.sighup.io/ {if($$1 == "image:"){print $$2}}' $(KFD_VERSION)/built.yaml | sort --unique > $(KFD_VERSION)/images.tmp.txt  #match image:
	awk '$$0 ~ /registry.sighup.io/ {if($$2 == "image:"){print $$3}}' $(KFD_VERSION)/built.yaml| sort --unique >> $(KFD_VERSION)/images.tmp.txt  #match - image:
	awk -F= '$$2 ~ /registry.sighup.io/ {print $$2}' $(KFD_VERSION)/built.yaml | sort --unique >> $(KFD_VERSION)/images.tmp.txt 				 #match --ARG=IMAGE
	awk '$$0 ~ /registry.sighup.io/ {if($$1 == "repository:"){repository=$$2;getline;tag=$$2; print repository":"tag}}' $(KFD_VERSION)/built.yaml | sort --unique >> $(KFD_VERSION)/images.tmp.txt #match image.repository+image.tag

	sort --unique $(KFD_VERSION)/images.tmp.txt --output $(KFD_VERSION)/images.txt && rm $(KFD_VERSION)/images.tmp.txt

trivy-download-db:
	trivy image --download-db-only --db-repository registry.sighup.io/fury-secured/aquasecurity/trivy-db:2 --no-progress --cache-dir $(TRIVY_CACHE_DIR)
	trivy image --download-java-db-only --java-db-repository registry.sighup.io/fury-secured/aquasecurity/trivy-java-db:1 --no-progress --cache-dir $(TRIVY_CACHE_DIR)

scan-vulns:
	TRIVY_CACHE_DIR=$(TRIVY_CACHE_DIR) ./scan_vuln.sh -v "$(KFD_VERSION)" -l "$(LIST_FILE)" -o "$(OUTPUT_FILE)";
