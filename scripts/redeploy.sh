#!/bin/bash
# Do a full redeploy of everything
ansible-playbook -i ansible/inventory/networking ansible/configurations/networking.yml --tags vms,kubernetes,metallb,apps,install -K