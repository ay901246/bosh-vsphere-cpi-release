#!/usr/bin/env bash
set -e
# DO NOT REMOVE!!!
#
# Proxy environment variables refer to squid proxy on Nimbus testbed jumpbox. We
# need these proxy environment variables because the CPI needs to talk to the
# BOSH agent on the VM it has deployed. Communication to the agent will fail in
# the absence of these proxy environment variables.
#
# In prepare director script, we use a proxy ops file to provide same variables.
# In that particular case, those variables are used to configure the environment
# for the BOSH cli, which rejects other environment configurations.
#
# Due to the different design philosophies between the CLI and the CPI, proxy
# environment variables are needed in both places.
source source-ci/ci/shared/tasks/setup-env-proxy.sh

cp director-config/* director-state/

# Extract the BOSH Director IP for debugging
DIRECTOR_IP="$(bosh int director-state/director.yml \
  --path=/instance_groups/name=bosh/networks/name=default/static_ips/0 | tr -d '[:space:]')"

# We want ALL communication to the director IP to route through the secure
# BOSH_ALL_PROXY (SSH SOCKS5 tunnel) to avoid corporate transparent proxies
# or firewalls on the underlay from intercepting/SSL-bumping the connections
# (especially port 6868). We must NOT add DIRECTOR_IP to NO_PROXY, because
# adding it to NO_PROXY would cause Go to ignore BOSH_ALL_PROXY and attempt
# direct connection, which gets intercepted.
export BOSH_LOG_LEVEL=debug

# The deployment manifest references releases and stemcells relative to itself
mkdir -p director-state/{stemcell,bosh-release,cpi-release}
cp stemcell/*.tgz director-state/stemcell/
cp bosh-release/*.tgz director-state/bosh-release/
cp cpi-release/*.tgz director-state/cpi-release/

export BOSH_LOG_PATH="$(mktemp /tmp/bosh-cli-log.XXXXXX)"

finish() {
  echo 'Final state of BOSH director deployment:' 1>&2
  echo '========================================' 1>&2
  if [ -f director-state/director-state.json ]; then
    cat director-state/director-state.json 1>&2
  fi
  echo 1>&2
  echo '========================================' 1>&2

  if [ -f "$BOSH_LOG_PATH" ]; then
    echo "BOSH CLI Debug Log:" 1>&2
    echo "========================================" 1>&2
    cat "$BOSH_LOG_PATH" 1>&2
    echo "========================================" 1>&2
    rm -f "$BOSH_LOG_PATH"
  fi

  if [ -d ~/.bosh ]; then
    cp -r ~/.bosh director-state || true
  fi
}
trap finish EXIT

echo "DEBUG PROXY ENVIRONMENT:" 1>&2
echo "DIRECTOR_IP: '${DIRECTOR_IP}'" 1>&2
env | grep -i proxy 1>&2 || true
echo "========================" 1>&2

echo Deploying BOSH director ... 1>&2
HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= bosh create-env --vars-store director-state/creds.yml director-state/director.yml
status=$?
if [ $status -ne 0 ]; then
  echo "BOSH director deployment failed!" 1>&2
  exit $status
fi

BOSH_ENVIRONMENT="$(bosh int director-state/director.yml \
  --path=/instance_groups/name=bosh/networks/name=default/static_ips/0)"
BOSH_CLIENT=admin
BOSH_CLIENT_SECRET="$(bosh int director-state/creds.yml --path=/admin_password)"
BOSH_CA_CERT="$(bosh int director-state/creds.yml --path=/director_ssl/ca)"

cat > director-state/director.env <<EOF
export BOSH_ENVIRONMENT=$(printf %q "$BOSH_ENVIRONMENT")
export BOSH_CLIENT=$(printf %q "$BOSH_CLIENT")
export BOSH_CLIENT_SECRET=$(printf %q "$BOSH_CLIENT_SECRET")
export BOSH_CA_CERT=$(printf %q "$BOSH_CA_CERT")

private_key_path=\$(mktemp)
echo -e "${JUMPBOX_PRIVATE_KEY}" > \${private_key_path}

export BOSH_ALL_PROXY="ssh+socks5://vcpi@${BOSH_VSPHERE_JUMPER_HOST}:22?private-key=\${private_key_path}"
EOF
