#!/usr/bin/env bash
# Delete both kind clusters.
source "$(dirname "$0")/lib.sh"
kind delete cluster --name staging || true
kind delete cluster --name prod || true
