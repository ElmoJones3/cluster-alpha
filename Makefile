# Node lists come from mise.toml (CONTROL_PLANE_IP, optional space-separated WORKER_IP).
export TALOSCONFIG ?= ./secrets/talosconfig

.PHONY: help check-env encrypt decrypt reboot-all shutdown-all

help:
	@printf '%s\n' \
	  '  make encrypt         ./scripts/cipher.sh encrypt  (plaintext → *.enc.yaml)' \
	  '  make decrypt         ./scripts/cipher.sh decrypt  (needs SOPS_AGE_KEY_FILE)' \
	  '  make reboot-all      Reboot workers, then the control plane' \
	  '  make shutdown-all    Power off workers, then the control plane' \
	  '' \
	  'WORKER_IP is space-separated, e.g. WORKER_IP="10.0.0.10 10.0.0.11"' \
	  'shutdown-all uses --force (no drain): this is a full cluster power-off.' \
	  'Confirm shutdown with YES=1 to skip the prompt.'

encrypt:
	./scripts/cipher.sh encrypt

decrypt:
	./scripts/cipher.sh decrypt

check-env:
	@test -n "$(CONTROL_PLANE_IP)" || { echo "CONTROL_PLANE_IP is unset (load mise env)"; exit 1; }
	@test -f "$(TALOSCONFIG)" || { echo "missing $(TALOSCONFIG)"; exit 1; }

# Workers first so a rolling reboot still has a control plane until the end.
# --wait (talosctl default) returns after each batch is back before the next.
reboot-all: check-env
	@echo "Rebooting: $(strip $(WORKER_IP) $(CONTROL_PLANE_IP))"
	@if [ -n "$(strip $(WORKER_IP))" ]; then \
	  talosctl reboot --nodes "$$(echo $(WORKER_IP) | tr ' ' ',')"; \
	fi
	talosctl reboot --nodes "$(CONTROL_PLANE_IP)"

# --force: drain has nowhere to go when the whole cluster is going down.
# These G5s need a power button (or WOL) after this.
shutdown-all: check-env
	@echo "Shutting down: $(strip $(WORKER_IP) $(CONTROL_PLANE_IP))"
	@echo "Physical power-on required to bring nodes back."
	@if [ "$(YES)" != 1 ]; then \
	  printf "Continue? [y/N] " && read ans && case $$ans in y|Y) ;; *) echo aborted; exit 1;; esac; \
	fi
	@if [ -n "$(strip $(WORKER_IP))" ]; then \
	  talosctl shutdown --force --nodes "$$(echo $(WORKER_IP) | tr ' ' ',')"; \
	fi
	talosctl shutdown --force --nodes "$(CONTROL_PLANE_IP)"
