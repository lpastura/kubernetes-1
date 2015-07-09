#!/bin/bash

# Copyright 2015 The Kubernetes Authors All rights reserved.
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

# Checkout a PR from GitHub. (Yes, this is sitting in a Git tree. How
# meta.) Assumes you care about pulls from remote "upstream" and
# checks thems out to a branch named pull_12345.

set -o errexit
set -o nounset
set -o pipefail

declare -r KUBE_ROOT="$(dirname "${BASH_SOURCE}")/.."
cd "${KUBE_ROOT}"

declare -r STARTINGBRANCH=$(git symbolic-ref --short HEAD)
declare -r REBASEMAGIC="${KUBE_ROOT}/.git/rebase-apply"

if [[ "$#" -ne 2 ]]; then
  echo "${0} <pr-number> <remote branch>: cherry pick <pr> onto <remote branch> and leave instructions for proposing pull request"
  echo ""
  echo "  Checks out <remote branch> and handles the cherry-pick of <pr> for you."
  echo "  Example:"
  echo "    $0 12345 upstream/release-3.14"
  exit 2
fi

if git_status=$(git status --porcelain 2>/dev/null) && [[ -n ${git_status} ]]; then
  echo "!!! Dirty tree. Clean up and try again."
  exit 1
fi

if [[ -e "${REBASEMAGIC}" ]]; then
  echo "!!! 'git rebase' or 'git am' in progress. Clean up and try again."
  exit 1
fi

declare -r PULL="${1}"
declare -r BRANCH="${2}"
echo "+++ Updating remotes..."
git remote update

if ! git log -n1 --format=%H "${BRANCH}" >/dev/null 2>&1; then
  echo "!!! '${BRANCH}' not found. The second argument should be something like upstream/release-0.21."
  echo "    (In particular, it needs to be a valid, existing remote branch that I can 'git checkout'.)"
  exit 1
fi

echo "+++ Downloading patch to /tmp/${PULL}.patch (in case you need to do this again)"

curl -o "/tmp/${PULL}.patch" -sSL "https://github.com/GoogleCloudPlatform/kubernetes/pull/${PULL}.patch"

declare -r NEWBRANCH="$(echo automated-cherry-pick-of-#${PULL}-on-${BRANCH} | sed 's/\//-/g')"
declare -r NEWBRANCHUNIQ="${NEWBRANCH}-$(date +%s)"
echo "+++ Creating local branch ${NEWBRANCHUNIQ}"

cleanbranch=""
gitamcleanup=false
function return_to_kansas {
  echo ""
  echo "+++ Returning you to the ${STARTINGBRANCH} branch and cleaning up."
  if [[ "${gitamcleanup}" == "true" ]]; then
    git am --abort >/dev/null 2>&1 || true
  fi
  git checkout -f "${STARTINGBRANCH}" >/dev/null 2>&1 || true
  if [[ -n "${cleanbranch}" ]]; then
    git branch -D "${cleanbranch}" >/dev/null 2>&1 || true
  fi
}
trap return_to_kansas EXIT

git checkout -b "${NEWBRANCHUNIQ}" "${BRANCH}"
cleanbranch="${NEWBRANCHUNIQ}"

echo
echo "+++ About to attempt cherry pick of PR. To reattempt:"
echo "  $ git am -3 /tmp/${PULL}.patch"
echo
gitamcleanup=true
git am -3 "/tmp/${PULL}.patch" || {
  conflicts=false
  while unmerged=$(git status --porcelain | grep ^U) && [[ -n ${unmerged} ]] \
    || [[ -e "${REBASEMAGIC}" ]]; do
    conflicts=true # <-- We should have detected conflicts once
    echo
    echo "+++ Conflicts detected:"
    echo
    (git status --porcelain | grep ^U) || echo "!!! None. Did you git am --continue?"
    echo
    echo "+++ Please resolve the conflicts in another window (and remember to 'git add / git am --continue')"
    read -p "+++ Proceed (anything but 'y' aborts the cherry-pick)? [y/n] " -r
    echo
    if ! [[ "${REPLY}" =~ ^[yY]$ ]]; then
      echo "Aborting." >&2
      exit 1
    fi
  done

  if [[ "${conflicts}" != "true" ]]; then
    echo "!!! git am failed, likely because of an in-progress 'git am' or 'git rebase'"
    exit 1
  fi
}
gitamcleanup=false

if git remote -v | grep ^origin | grep GoogleCloudPlatform/kubernetes.git; then
  echo "!!! You have 'origin' configured as your GoogleCloudPlatform/kubernetes.git"
  echo "This isn't normal. Leaving you with push instructions:"
  echo
  echo "  git push REMOTE ${NEWBRANCHUNIQ}:${NEWBRANCH}"
  echo
  echo "where REMOTE is your personal fork (maybe 'upstream'? Consider swapping those.)."
  echo "Then propose ${NEWBRANCH} as a pull against ${BRANCH} (NOT MASTER)."
  echo "Use this exact subject: 'Automated cherry pick of #${PULL}' and include a justification."
  cleanbranch=""
  exit 0
fi

echo
echo "+++ I'm about to do the following to push to GitHub (and I'm assuming origin is your personal fork):"
echo
echo "  git push origin ${NEWBRANCHUNIQ}:${NEWBRANCH}"
echo
read -p "+++ Proceed (anything but 'y' aborts the cherry-pick)? [y/n] " -r
if ! [[ "${REPLY}" =~ ^[yY]$ ]]; then
  echo "Aborting." >&2
  exit 1
fi

git push origin -f "${NEWBRANCHUNIQ}:${NEWBRANCH}"

echo
echo "+++ Now you must propose ${NEWBRANCH} as a pull against ${BRANCH} (NOT MASTER)."
echo "    You must use this exact subject: 'Automated cherry pick of #${PULL}' and include a justification."
echo
