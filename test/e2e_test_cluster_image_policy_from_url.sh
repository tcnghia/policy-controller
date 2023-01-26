#!/usr/bin/env bash
#
# Copyright 2022 The Sigstore Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


#set -ex
set -e

# This is a timestamp server that has multiarch that we just use for testing
# evaluating CIP level policy validations.
export demoimage="ghcr.io/sigstore/timestamp-server@sha256:dcf2f3a640bfb0a5d17aabafb34b407fe4403363c715718ab305a62b3606540d"

# To simplify testing failures, use this function to execute a kubectl to create
# our job and verify that the failure is expected.
assert_error() {
  local KUBECTL_OUT_FILE="/tmp/kubectl.failure.out"
  match="$@"
  echo looking for ${match}
  kubectl delete job job-that-fails -n ${NS} --ignore-not-found=true
  if kubectl create -n ${NS} job job-that-fails --image=${demoimage} 2> ${KUBECTL_OUT_FILE} ; then
    echo Failed to block expected Job failure!
    exit 1
  else
    echo Successfully blocked Job creation with expected error: "${match}"
    if ! grep -q "${match}" ${KUBECTL_OUT_FILE} ; then
      echo Did not get expected failure message, wanted "${match}", got
      cat ${KUBECTL_OUT_FILE}
      exit 1
    fi
  fi
}

echo '::group:: Create test namespace and label for verification'
kubectl create namespace demo-policy-with-url
kubectl label namespace demo-policy-with-url policy.sigstore.dev/include=true
export NS=demo-policy-with-url
echo '::endgroup::'

# Note that we put this in a for loop to make sure the webhook is actually
# up and running before proceeding with the tests.
echo '::group:: Deploy ClusterImagePolicy with config file that should fail due to cue errors'
for i in {1..10}
do
  if kubectl apply -f ./test/testdata/policy-controller/e2e/cip-policy-from-url.yaml ; then
    echo successfully applied CIP
    break
  fi
  if [ "$i" == 10 ]; then
    echo failed to apply CIP
    exit 1
  fi
  echo failed to apply CIP. Attempt numer "$i", retrying
  sleep 2
done
# allow things to propagate
sleep 5
echo '::endgroup::'

echo '::group:: validate failure'
expected_error='failed evaluating cue policy for ClusterImagePolicy: failed to evaluate the policy with error: config."linux/amd64".config.User: conflicting values'
assert_error ${expected_error}
echo '::endgroup::'

echo '::group:: Update policy url and sha256sum with passing cue values'
kubectl patch cip image-policy-url --type "json" \
-p '[{"op":"replace", "path":"/spec/policy/remote/url", "value":"https://gist.githubusercontent.com/hectorj2f/af0d32d4be4bf2710cff76c397a14751/raw/d4dd87fffdf9624a21e62b8719e3ce8d61334ab9/policy-controller-test-success-cue"},{"op":"replace", "path":"/spec/policy/remote/sha256sum", "value":"45eb2cce1c84418d615f3e56c701451b63d58b95f9559dfa1d5254cb851358d3"}]'
# allow for propagation
sleep 5
echo '::endgroup::'

echo '::group:: test job success'
# This one should pass since the User is what we specified in the CIP policy.
if ! kubectl create -n ${NS} job demo --image=${demoimage} ; then
  echo Failed to create Job in namespace with valid CIP policy!
  exit 1
else
  echo Succcessfully created Job with signed image
fi
echo '::endgroup::'

echo '::group::' Cleanup
kubectl delete cip --all
kubectl delete ns ${NS}
echo '::endgroup::'

