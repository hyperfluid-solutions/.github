#!/usr/bin/env bash

# Sets Environment Variables for template files.
# 
# Test templates with this command:
# (source ./vars.sh; envsubst < target.tpl.md > target.appname.md;)

export APP_NAME='replace_me'
export PRIVACY_EMAIL='replace_me'

export TODAY_FORMAL=$(date '+%d %B %Y')
