#!/bin/bash
# Install Networking Apps for Kubernetes
ansible-playbook -i ansible/inventory/networking ansible/configurations/apps.yml --tags apps,install