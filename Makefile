.PHONY: up down images status prepare stage merge watch-staging watch-prod reset test slides slides-pdf

up:            ; scripts/up.sh
down:          ; scripts/down.sh
images:        ; scripts/build-local.sh
status:        ; scripts/demo/status.sh
prepare:       ; scripts/demo/prepare.sh
stage:         ; scripts/demo/deploy-pr-to-staging.sh
merge:         ; scripts/demo/merge.sh
watch-staging: ; scripts/demo/watch.sh staging
watch-prod:    ; scripts/demo/watch.sh prod
reset:         ; scripts/demo/reset.sh

test:
	cd apps && go vet ./... && go test ./...
	kubectl kustomize deploy/overlays/staging >/dev/null
	kubectl kustomize deploy/overlays/prod >/dev/null

slides:     ; cd slides && npm run dev
slides-pdf: ; cd slides && npm run export
