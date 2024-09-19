#!/usr/bin/env bash

source hack/lib/common.sh

# load_image_if_kind <image tag>
#
# load_image_if_kind loads an image into all nodes in a kind cluster.
#
function load_image_if_kind() {
  local cluster=${KIND_CLUSTER:-kind}
  if [[ "$(kubectl config current-context)" == "kind-${cluster}" ]]; then
    kind load docker-image --name "${cluster}" "$1"
  fi
}

set -eu

header_text "Running ansible molecule tests in a python3 virtual environment"

# Set up a python3.8 virtual environment.
ENVDIR="$(mktemp -d)"
trap_add "set +u; deactivate; set -u; rm -rf $ENVDIR" EXIT
python3 -m venv "$ENVDIR"
set +u; source "${ENVDIR}/bin/activate"; set -u

# Install dependencies.
TMPDIR="$(mktemp -d)"
trap_add "rm -rf $TMPDIR" EXIT
pip3 install pyasn1==0.4.7 pyasn1-modules==0.2.6 idna==2.8 ipaddress==1.0.23
pip3 install cryptography molecule==5.1.0
pip3 install ansible-lint yamllint
pip3 install docker kubernetes jmespath
pip3 install requests==2.32.2
ansible-galaxy collection install 'kubernetes.core:==2.4.0'
ansible-galaxy collection install 'operator_sdk.util:==0.4.0'
ansible-galaxy collection install 'community.docker:==3.10.3'

header_text "Copying molecule testdata scenarios"
ROOTDIR="$(pwd)"
cp -r $ROOTDIR/testdata/ansible/memcached-molecule-operator/ $TMPDIR/memcached-molecule-operator
cp -r $ROOTDIR/testdata/ansible/advanced-molecule-operator/ $TMPDIR/advanced-molecule-operator

# Skip Kind test with memcached-molecule-operator if ADVANCED_MOLECULE_OPERATOR_IMAGE has a value.
if [ -z "${ADVANCED_MOLECULE_OPERATOR_IMAGE-}" ] ; then
  pushd $TMPDIR/memcached-molecule-operator

  header_text "Running Kind test with memcached-molecule-operator"
  make kustomize
  if [ -f ./bin/kustomize ] ; then
    KUSTOMIZE="$(realpath ./bin/kustomize)"
  else
    KUSTOMIZE="$(which kustomize)"
  fi
  KUSTOMIZE_PATH=${KUSTOMIZE} TEST_OPERATOR_NAMESPACE=default molecule test -s kind
  popd
fi

header_text "Running Default test with advanced-molecule-operator"

# Skip creation of Kind cluster if ADVANCED_MOLECULE_OPERATOR_IMAGE has a value.
if [ -z "${ADVANCED_MOLECULE_OPERATOR_IMAGE-}" ] ; then
  make test-e2e-setup
fi
pushd $TMPDIR/advanced-molecule-operator

make kustomize
if [ -f ./bin/kustomize ] ; then
  KUSTOMIZE="$(realpath ./bin/kustomize)"
else
  KUSTOMIZE="$(which kustomize)"
fi

# Check if ADVANCED_MOLECULE_OPERATOR_IMAGE has value or not. If it doesn't have a value then proceed with the test
# using a Kind cluster, otherwise proceed with the test without the Kind cluster.
if [ -z "${ADVANCED_MOLECULE_OPERATOR_IMAGE-}" ] ; then
  DEST_IMAGE="quay.io/example/advanced-molecule-operator:v0.0.1"
  docker build -t "$DEST_IMAGE" --no-cache .
  load_image_if_kind "$DEST_IMAGE"
  IMAGE_PULL_POLICY="Never"
else
  DEST_IMAGE=${ADVANCED_MOLECULE_OPERATOR_IMAGE}
  IMAGE_PULL_POLICY="IfNotPresent"
fi
KUSTOMIZE_PATH=$KUSTOMIZE OPERATOR_PULL_POLICY=${IMAGE_PULL_POLICY} OPERATOR_IMAGE=${DEST_IMAGE} TEST_OPERATOR_NAMESPACE=osdk-test molecule test
popd
