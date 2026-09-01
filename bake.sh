#!/bin/bash

GIT_SHA=$(git rev-parse HEAD) GIT_REF=$(git rev-parse --abbrev-ref HEAD) docker buildx bake -f docker-bake.hcl "$@"
