#!/bin/bash

# Create VMs on Proxmox
ansible-playbook -i ansible/inventory/networking ansible/configurations/roles/kubernetes.yml --tags kubernetes,install -K