#!/usr/bin/env bats
# vim: ft=sh:sw=2:et

set -o pipefail

load os_helper
load foreman_helper
load fixtures/content

setup() {
  tSetOSVersion
  HOSTNAME=$(hostname -f)
}

# Ensure we have at least one organization present so that the test organization
# can be deleted at the end
@test "Create an Empty Organization" {
  run hammer organization info --name "Empty Organization"

  if [ $status != 0 ]; then
    hammer organization create --name="Empty Organization" | grep -q "Organization created"
  fi
}

@test "create an Organization" {
  hammer organization create --name="${ORGANIZATION}" | grep -q "Organization created"
}

@test "create a product" {
  hammer product create --organization="${ORGANIZATION}" --name="${PRODUCT}" | grep -q "Product created"
}

@test "create package repository" {
  hammer repository create --organization="${ORGANIZATION}" \
    --product="${PRODUCT}" --content-type="yum" --name "${YUM_REPOSITORY}" \
    --url https://jlsherrill.fedorapeople.org/fake-repos/needed-errata/ | grep -q "Repository created"
}

@test "upload package" {
  (cd /tmp; curl -O https://repos.fedorapeople.org/repos/pulp/pulp/demo_repos/test_errata_install/animaniacs-0.1-1.noarch.rpm)
  hammer repository upload-content --organization="${ORGANIZATION}"\
    --product="${PRODUCT}" --name="${YUM_REPOSITORY}" --path="/tmp/animaniacs-0.1-1.noarch.rpm" | grep -q "Successfully uploaded"
}

@test "sync repository" {
  hammer repository synchronize --organization="${ORGANIZATION}" \
    --product="${PRODUCT}" --name="${YUM_REPOSITORY}"
}

@test "create a file repository" {
  hammer repository create --organization="${ORGANIZATION}" --url=https://repos.fedorapeople.org/repos/pulp/pulp/fixtures/file/ \
    --product="${PRODUCT}" --content-type="file" --name "${FILE_REPOSITORY}" | grep -q "Repository created"
}

@test "sync file repository" {
  hammer repository synchronize --organization="${ORGANIZATION}" \
    --product="${PRODUCT}" --name="${FILE_REPOSITORY}"
}

@test "fetch file from file repository" {
  curl http://$HOSTNAME/pulp/isos/${ORGANIZATION_LABEL}/Library/custom/${PRODUCT_LABEL}/${REPOSITORY_LABEL}/1.iso > /dev/null
}

@test "create a docker repository" {
  hammer repository create --organization="${ORGANIZATION}" --docker-upstream-name="fedora/ssh" --url=https://registry-1.docker.io/ \
    --product="${PRODUCT}" --content-type="docker" --name "${DOCKER_REPOSITORY}" | grep -q "Repository created"
}

@test "sync docker repository" {
  hammer repository synchronize --organization="${ORGANIZATION}" \
    --product="${PRODUCT}" --name="${DOCKER_REPOSITORY}"
}

@test "create puppet repository" {
  hammer repository create --organization="${ORGANIZATION}" \
    --product="${PRODUCT}" --content-type="puppet" --name "${PUPPET_REPOSITORY}" | grep -q "Repository created"
}

@test "upload puppet module" {
  curl -o /tmp/stbenjam-dummy-0.2.0.tar.gz https://forgeapi.puppetlabs.com/v3/files/stbenjam-dummy-0.2.0.tar.gz
  tFileExists /tmp/stbenjam-dummy-0.2.0.tar.gz && hammer repository upload-content \
    --organization="${ORGANIZATION}" --product="${PRODUCT}" --name="${PUPPET_REPOSITORY}" \
    --path="/tmp/stbenjam-dummy-0.2.0.tar.gz" | grep -q "Successfully uploaded"
}

@test "create lifecycle environment" {
  hammer lifecycle-environment create --organization="${ORGANIZATION}" \
    --prior="Library" --name="${LIFECYCLE_ENVIRONMENT}" | grep -q "Environment created"
}

@test "create content view" {
  hammer content-view create --organization="${ORGANIZATION}" \
    --name="${CONTENT_VIEW}" | grep -q "Content view created"
}

@test "add repo to content view" {
  repo_id=$(hammer repository list --organization="${ORGANIZATION}" \
    | grep ${YUM_REPOSITORY} | cut -d\| -f1 | egrep -i '[0-9]+')
  hammer content-view add-repository --organization="${ORGANIZATION}" \
    --name="${CONTENT_VIEW}" --repository-id=$repo_id | grep -q "The repository has been associated"
}

@test "publish content view" {
  hammer content-view publish --organization="${ORGANIZATION}" \
    --name="${CONTENT_VIEW}"
}

@test "promote content view" {
  hammer content-view version promote  --organization="${ORGANIZATION}" \
    --content-view="${CONTENT_VIEW}" --to-lifecycle-environment="${LIFECYCLE_ENVIRONMENT}" --from-lifecycle-environment="Library"
}

@test "create activation key" {
  hammer activation-key create --organization="${ORGANIZATION}" \
    --name="${ACTIVATION_KEY}" --content-view="${CONTENT_VIEW}" --lifecycle-environment="${LIFECYCLE_ENVIRONMENT}" \
    --unlimited-hosts | grep -q "Activation key created"
}

@test "disable auto-attach" {
  hammer activation-key update --organization="${ORGANIZATION}" \
    --name="${ACTIVATION_KEY}" --auto-attach=false
}

@test "add subscription to activation key" {
  sleep 10
  activation_key_id=$(hammer activation-key info --organization="${ORGANIZATION}" \
    --name="${ACTIVATION_KEY}" | grep ID | tr -d ' ' | cut -d':' -f2)
  subscription_id=$(hammer subscription list --organization="${ORGANIZATION}" \
    | grep "${PRODUCT}" | cut -d\| -f1 | tr -d ' ')
  hammer activation-key add-subscription --id=$activation_key_id \
    --subscription-id=$subscription_id | grep -q "Subscription added to activation key"
}

@test "install subscription manager" {
  tPackageExists subscription-manager || tPackageInstall subscription-manager
}

@test "disable puppet agent to prevent checkin from registering host to another org" {
  systemctl is-active puppet || skip "Puppet is not active"
  systemctl stop puppet
}

@test "delete host if present" {
  hammer host delete --name=$HOSTNAME || echo "Could not delete host"
}

@test "register subscription manager with username and password" {
  if [ -e "/etc/rhsm/ca/candlepin-local.pem" ]; then
    rpm -e `rpm -qf /etc/rhsm/ca/candlepin-local.pem`
  fi

  run subscription-manager unregister
  echo "rc=${status}"
  echo "${output}"
  run subscription-manager clean
  echo "rc=${status}"
  echo "${output}"
  run yum erase -y 'katello-ca-consumer-*'
  echo "rc=${status}"
  echo "${output}"
  run rpm -Uvh http://localhost/pub/katello-ca-consumer-latest.noarch.rpm
  echo "rc=${status}"
  echo "${output}"
  subscription-manager register --force --org="${ORGANIZATION_LABEL}" --username=admin --password=changeme --env=Library
}

@test "register subscription manager with activation key" {
  run subscription-manager unregister
  echo "rc=${status}"
  echo "${output}"
  run subscription-manager clean
  echo "rc=${status}"
  echo "${output}"
  run subscription-manager register --force --org="${ORGANIZATION_LABEL}" --activationkey="${ACTIVATION_KEY}"
  echo "rc=${status}"
  echo "${output}"
  subscription-manager list --consumed | grep "${PRODUCT}"
}

@test "start puppet again" {
  systemctl is-enabled puppet || skip "Puppet isn't enabled"
  systemctl start puppet
}

@test "check content host is registered" {
  hammer host info --name $HOSTNAME
}

@test "enable content view repo" {
  subscription-manager repos --enable="${ORGANIZATION_LABEL}_${PRODUCT_LABEL}_${YUM_REPOSITORY_LABEL}" | grep -q "is enabled for this system"
}

@test "install katello-host-tools" {
  tPackageInstall katello-host-tools && tPackageExists katello-host-tools
}

@test "install package locally" {
  run yum -y remove walrus
  tPackageInstall walrus-0.71 && tPackageExists walrus-0.71
}

@test "check available errata" {
  local next_wait_time=0
  until hammer host errata list --host $HOSTNAME | grep 'RHEA-2012:0055'; do
    if [ $next_wait_time -eq 14 ]; then
      # make one last try, also makes the error nice
      hammer host errata list --host $HOSTNAME | grep 'RHEA-2012:0055'
    fi
    sleep $(( next_wait_time++ ))
  done
}

@test "install katello-agent" {
  tPackageInstall katello-agent && tPackageExists katello-agent
}

@test "30 sec of sleep for groggy gofers" {
  sleep 30
}

@test "install package remotely (katello-agent)" {
  # see http://projects.theforeman.org/issues/15089 for bug related to "|| true"
  run yum -y remove gorilla
  timeout 300 hammer host package install --host $HOSTNAME --packages gorilla || true
  tPackageExists gorilla
}

@test "install errata remotely (katello-agent)" {
  # see http://projects.theforeman.org/issues/15089 for bug related to "|| true"
  timeout 300 hammer host errata apply --errata-ids 'RHEA-2012:0055' --host $HOSTNAME || true
  tPackageExists walrus-5.21
}

# it seems walrus lingers around making subsequent runs fail, so lets test package removal!
@test "package remove (katello-agent)" {
  timeout 300 hammer host package remove --host $HOSTNAME --packages walrus
}

@test "add puppet module to content view" {
  repo_id=$(hammer repository list --organization="${ORGANIZATION}" \
    | grep Puppet | cut -d\| -f1 | egrep -i '[0-9]+')
  module_id=$(hammer puppet-module list --repository-id=$repo_id | grep dummy | cut -d\| -f1)
  hammer content-view puppet-module add --organization="${ORGANIZATION}" \
    --content-view="${CONTENT_VIEW}" --id=$module_id | grep -q "Puppet module added to content view"
}

@test "publish content view" {
  hammer content-view publish --organization="${ORGANIZATION}" \
    --name="${CONTENT_VIEW}"
}

@test "promote content view" {
  hammer content-view version promote  --organization="${ORGANIZATION}" \
    --content-view="${CONTENT_VIEW}" --to-lifecycle-environment="${LIFECYCLE_ENVIRONMENT}" --from-lifecycle-environment="Library"
}

@test "add puppetclass to host" {
  # FIXME: If katello host is subscribed to itself, should it's puppet env also be updated? #7364
  # Skipping because of http://projects.theforeman.org/issues/8244
  skip
  target_env=$(hammer environment list | grep KT_${ORGANIZATION_LABEL}_${LIFECYCLE_ENVIRONMENT_LABEL}_${CONTENT_VIEW_LABEL} | cut -d\| -f1)
  hammer host update --name $HOSTNAME --environment-id=$target_env \
    --puppetclass-ids=1 | grep -q "Host updated"
}

@test "puppet run applies dummy module" {
  skip # because of above
  puppet agent --test && grep -q Lorem /tmp/dummy
}

@test "try fetching docker content" {
  FOREMAN_VERSION=$(tForemanVersion)
  if [[ $(printf "${FOREMAN_VERSION}\n1.20" | sort --version-sort | tail -n 1) == "1.20" ]] ; then
    skip "docker v2 API is not supported on this version"
  fi
  tPackageInstall podman
  podman login $HOSTNAME -u admin -p changeme
  DOCKER_PULL_LABEL=`echo "${ORGANIZATION_LABEL}-${PRODUCT_LABEL}-${DOCKER_REPOSITORY_LABEL}"| tr '[:upper:]' '[:lower:]'`
  podman pull "${HOSTNAME}/${DOCKER_PULL_LABEL}"
}

