# syntax=docker/dockerfile:1
# check=error=true

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.5

FROM docker.io/library/ruby:${RUBY_VERSION}-slim-trixie AS ruby-base

WORKDIR /workspaces/flipper-firebase_remote_config

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html
FROM mcr.microsoft.com/devcontainers/base:trixie AS devcontainer

ARG RUBY_VERSION=4.0.5

# Copy the installed Ruby from the ruby-base image:
COPY --from=ruby-base /usr/local/lib /usr/local/lib
COPY --from=ruby-base /usr/local/include /usr/local/include
COPY --from=ruby-base /usr/local/share/man /usr/local/share/man
COPY --from=ruby-base /usr/local/bin /usr/local/bin

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && apt-get install --no-install-recommends -y libyaml-dev

ENV RUBY_VERSION=${RUBY_VERSION}

ENV GEM_HOME=/usr/local/bundle

ENV BUNDLE_SILENCE_ROOT_WARNING=1 \
    BUNDLE_APP_CONFIG="$GEM_HOME"

ENV PATH=${GEM_HOME}/bin:${PATH}

# adjust permissions of GEM_HOME for running "gem install" as an arbitrary user
RUN set -eux; mkdir "${GEM_HOME}"; chmod 1777 "${GEM_HOME}"

ARG USER=me
RUN usermod --login ${USER} vscode && groupmod --new-name ${USER} vscode \
 && usermod --append --groups root ${USER} \
 && sed -i "s/vscode/${USER}/g" /etc/sudoers.d/vscode \
 && mv /etc/sudoers.d/vscode "/etc/sudoers.d/${USER}"

WORKDIR /workspaces/flipper-firebase_remote_config

COPY --chown=${USER} Gemfile* flipper-firebase_remote_config.gemspec /workspaces/flipper-firebase_remote_config/
COPY --chown=${USER} lib/flipper/adapters/firebase_remote_config/version.rb /workspaces/flipper-firebase_remote_config/lib/flipper/adapters/firebase_remote_config/

ENV PATH=/workspaces/flipper-firebase_remote_configbin:${PATH}
USER ${USER}
# Configure bundler to retry downloads 3 times:
RUN bundle config set --local retry 3
# Configure bundler to use 2 threads to download, build and install:
RUN bundle config set --local jobs 2
RUN bundle config set --local without development
RUN bundle install
RUN bundle config unset --local without