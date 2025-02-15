#!/usr/bin/env bash

if grep -q "\${" "$1"; then
  echo "Templatization failed - check your var.sh"
else
  echo "Successfully templatized $1 !"
fi
